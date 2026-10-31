import Foundation
import KiteCore

/// Runs in extensions so they see Kite's tabs: in each extension's service worker
/// (ExtensionTabsBridge injects it) and at document start in its pages, such as its
/// toolbar popup (ChromiumPage adds it).
///
/// Kite's tabs are Alloy-style browsers, which aren't in Chromium's tab strips: by id
/// they work (tabs.get, tabs.sendMessage, scripting.executeScript, tabs.update), but
/// nothing belongs to a window, so tabs.query finds nothing, windows.getCurrent and
/// tabs.create fail with "No current window", and nothing is ever active. 1Password asks
/// for the active tab to fill it, so this answers those calls from Kite's tab list.
///
/// In the worker, Kite sends the list with `__kite.update(state)` whenever it changes;
/// calls that need Kite (open a tab, switch to one, capture it) go out through the
/// `__kiteTabsBridge` binding and come back with `__kite.resolve(id, value, error)`.
/// Pages have no binding: they ask their worker over a BroadcastChannel.
enum ExtensionTabsScript {
    static let bindingName = "__kiteTabsBridge"

    /// For a page at `url`: extension pages only, and never Kite's own helper's.
    static func script(for url: URL) -> String? {
        guard url.scheme == "chrome-extension", let host = url.host, host != KiteHelperExtension.id else { return nil }
        return source
    }

    static let source = #"""
    (() => {
      if (globalThis.__kite || !globalThis.chrome?.tabs) return;
      const tabs = chrome.tabs;
      const windows = chrome.windows;
      const native = { get: tabs.get.bind(tabs), update: tabs.update.bind(tabs), query: tabs.query.bind(tabs) };
      const channel = new BroadcastChannel('__kite_tabs');
      const isWorker = typeof globalThis.__kiteTabsBridge === 'function';
      const listeners = new Map();
      let state = { windows: [], tabs: [] };
      let received;
      const ready = new Promise((resolve) => (received = resolve));
      const pending = new Map();
      let nextCall = 1;

      // Chrome's APIs take a callback or return a promise.
      const callable = (run) =>
        function (...args) {
          const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
          const promise = Promise.resolve().then(() => run(...args));
          if (!callback) return promise;
          promise.then(callback, (error) => {
            console.warn('[Kite]', error.message);
            callback();
          });
        };

      const call = (send, message, timeout) =>
        new Promise((resolve, reject) => {
          const id = nextCall++;
          pending.set(id, { resolve, reject });
          send({ id, ...message });
          if (timeout) setTimeout(() => pending.has(id) && (pending.delete(id), reject(new Error('Kite took too long'))), timeout);
        });
      const settle = (id, value, error) => {
        const p = pending.get(id);
        if (!p) return;
        pending.delete(id);
        error ? p.reject(new Error(error)) : p.resolve(value);
      };

      const fire = (name, args) => {
        for (const f of listeners.get(name) || []) {
          try {
            f(...args);
          } catch (error) {
            console.error(error);
          }
        }
      };

      // MARK: The worker answers from Kite's list.

      const ask = (op, args) => call((m) => globalThis.__kiteTabsBridge(JSON.stringify(m)), { op, args });
      const focusedWindow = () => state.windows.find((w) => w.focused) || state.windows[0];
      const resolveWindow = (id) => (id === undefined || id === windows.WINDOW_ID_CURRENT ? focusedWindow()?.id : id);
      const entryFor = (id) => state.tabs.find((t) => t.id === id);
      const activeEntry = () => state.tabs.find((t) => t.windowId === focusedWindow()?.id && t.active);

      // A tab Chromium describes, with what only Kite knows: its window, place and state.
      const describe = async (entry) => {
        let tab;
        try {
          tab = await native.get(entry.id);
        } catch {
          return null;
        }
        return Object.assign(tab, {
          windowId: entry.windowId,
          index: entry.index,
          active: entry.active,
          highlighted: entry.active,
          selected: entry.active,
          pinned: entry.pinned,
          discarded: false,
          groupId: -1,
        });
      };

      const describeWindow = async (w, populate) => {
        const result = {
          id: w.id,
          focused: w.focused,
          top: w.top,
          left: w.left,
          width: w.width,
          height: w.height,
          incognito: false,
          type: 'normal',
          state: w.state,
          alwaysOnTop: false,
        };
        if (populate) result.tabs = (await Promise.all(state.tabs.filter((t) => t.windowId === w.id).map(describe))).filter(Boolean);
        return result;
      };

      const glob = (pattern) => new RegExp('^' + pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
      // Match patterns: <all_urls>, or scheme://host/path with * wildcards.
      const matchPattern = (pattern) => {
        if (pattern === '<all_urls>') return (url) => /^(https?|wss?|ftp|file|data|urn):/.test(url);
        const parts = /^(\*|[a-z-]+):\/\/([^/]*)(\/.*)?$/.exec(pattern);
        if (!parts) return () => false;
        const [, scheme, host, path = '/*'] = parts;
        const schemeOK = scheme === '*' ? (s) => s === 'http' || s === 'https' : (s) => s === scheme;
        const hostOK =
          host === '*' ? () => true
          : host.startsWith('*.') ? (h) => h === host.slice(2) || h.endsWith(host.slice(1))
          : (h) => h === host;
        const pathOK = glob(path);
        return (url) => {
          try {
            const u = new URL(url);
            return schemeOK(u.protocol.slice(0, -1)) && hostOK(u.hostname) && pathOK.test(u.pathname + u.search);
          } catch {
            return false;
          }
        };
      };

      // Until Kite's first list arrives (just after the worker starts), wait briefly for it.
      const withState = (f) => async (...args) => {
        await Promise.race([ready, new Promise((r) => setTimeout(r, 1000))]);
        return f(...args);
      };

      const worker = {
        query: withState(async (info = {}) => {
          let entries = state.tabs;
          const current = focusedWindow()?.id;
          if (info.windowId !== undefined) entries = entries.filter((t) => t.windowId === resolveWindow(info.windowId));
          if (info.currentWindow !== undefined || info.lastFocusedWindow !== undefined) {
            const wanted = info.currentWindow ?? info.lastFocusedWindow;
            entries = entries.filter((t) => (t.windowId === current) === wanted);
          }
          for (const key of ['active', 'highlighted']) if (info[key] !== undefined) entries = entries.filter((t) => t.active === info[key]);
          if (info.pinned !== undefined) entries = entries.filter((t) => t.pinned === info.pinned);
          if (info.index !== undefined) entries = entries.filter((t) => t.index === info.index);
          if (info.windowType !== undefined && info.windowType !== 'normal') entries = [];
          if (info.discarded === true || (info.groupId !== undefined && info.groupId !== -1)) entries = [];
          let result = (await Promise.all(entries.map(describe))).filter(Boolean);
          if (info.url !== undefined) {
            const matchers = [].concat(info.url).map(matchPattern);
            result = result.filter((t) => matchers.some((m) => m(t.url || t.pendingUrl || '')));
          }
          if (info.title !== undefined) result = result.filter((t) => glob(info.title).test(t.title || ''));
          if (info.status !== undefined) result = result.filter((t) => t.status === info.status);
          if (info.audible !== undefined) result = result.filter((t) => !!t.audible === info.audible);
          if (info.muted !== undefined) result = result.filter((t) => !!t.mutedInfo?.muted === info.muted);
          return result;
        }),
        get: withState(async (id) => {
          const entry = entryFor(id);
          return (entry && (await describe(entry))) || native.get(id);
        }),
        create: withState(async (props = {}) => {
          const active = props.active !== false && props.selected !== false;
          const { id } = await ask('create', { url: props.url, active });
          const entry = entryFor(id) ?? { id, windowId: focusedWindow()?.id, index: 0, active, pinned: false };
          return (await describe(entry)) || native.get(id);
        }),
        update: withState(async (...args) => {
          const id = typeof args[0] === 'number' ? args.shift() : activeEntry()?.id;
          if (id === undefined) throw new Error('No current window');
          const props = { ...(args[0] || {}) };
          const activate = props.active === true || props.highlighted === true || props.selected === true;
          delete props.active;
          delete props.highlighted;
          delete props.selected;
          if (activate) await ask('activate', { id });
          if (Object.keys(props).length) await native.update(id, props);
          const entry = entryFor(id);
          return (entry && (await describe(entry))) || native.get(id);
        }),
        highlight: withState(async (info) => {
          const index = [].concat(info.tabs)[0];
          const entry = state.tabs.find((t) => t.windowId === resolveWindow(info.windowId) && t.index === index);
          if (entry) await ask('activate', { id: entry.id });
          return describeWindow(focusedWindow(), true);
        }),
        captureVisibleTab: async (...args) => {
          const options = args.find((a) => a && typeof a === 'object') || {};
          return ask('capture', { format: options.format || 'jpeg', quality: options.quality ?? 92 });
        },
        windowsGetAll: withState(async (info = {}) => Promise.all(state.windows.map((w) => describeWindow(w, info.populate)))),
        windowsGet: withState(async (id, info = {}) => {
          const w = state.windows.find((w) => w.id === resolveWindow(id));
          if (!w) throw new Error(`No window with id: ${id}.`);
          return describeWindow(w, info.populate);
        }),
        windowsGetCurrent: withState(async (info = {}) => {
          const w = focusedWindow();
          if (!w) throw new Error('No current window');
          return describeWindow(w, info.populate);
        }),
      };

      // Chromium never fires tab events for Kite's tabs, so the worker fires them from
      // Kite's list, here and in the extension's pages.
      const announce = async (previous, next) => {
        const events = [];
        const before = new Map(previous.tabs.map((t) => [t.id, t]));
        const after = new Map(next.tabs.map((t) => [t.id, t]));
        for (const [id, t] of after) {
          if (before.has(id)) continue;
          const tab = await describe(t);
          if (tab) events.push(['created', [tab]]);
        }
        for (const [id, t] of before) {
          if (!after.has(id)) events.push(['removed', [id, { windowId: t.windowId, isWindowClosing: false }]]);
        }
        for (const [id, t] of after) {
          if (t.active && !before.get(id)?.active) events.push(['activated', [{ tabId: id, windowId: t.windowId }]]);
        }
        const was = previous.windows.find((w) => w.focused)?.id ?? windows.WINDOW_ID_NONE;
        const is = next.windows.find((w) => w.focused)?.id ?? windows.WINDOW_ID_NONE;
        if (was !== is) events.push(['focusChanged', [is]]);
        for (const [name, args] of events) {
          fire(name, args);
          channel.postMessage({ event: name, args });
        }
      };

      // MARK: Pages ask the worker.

      const fromPage = (method) => async (...args) => {
        try {
          return await call((m) => channel.postMessage(m), { method, args }, 3000);
        } catch (error) {
          if (method === 'query') return native.query(...args);
          throw error;
        }
      };

      const impl = isWorker ? worker : Object.fromEntries(Object.keys(worker).map((m) => [m, fromPage(m)]));

      channel.onmessage = async ({ data }) => {
        if (!data) return;
        if (data.event) return isWorker || fire(data.event, data.args);
        if ('result' in data || 'error' in data) return isWorker || settle(data.id, data.result, data.error);
        if (!isWorker || !data.method || !worker[data.method]) return;
        try {
          channel.postMessage({ id: data.id, result: await worker[data.method](...data.args) });
        } catch (error) {
          channel.postMessage({ id: data.id, error: error.message });
        }
      };

      globalThis.__kite = {
        update(next) {
          const previous = state;
          state = next;
          received();
          announce(previous, next);
        },
        resolve: settle,
      };

      tabs.query = callable(impl.query);
      tabs.get = callable(impl.get);
      tabs.create = callable(impl.create);
      tabs.update = callable(impl.update);
      tabs.highlight = callable(impl.highlight);
      tabs.captureVisibleTab = callable(impl.captureVisibleTab);
      windows.getAll = callable(impl.windowsGetAll);
      windows.get = callable(impl.windowsGet);
      windows.getCurrent = callable(impl.windowsGetCurrent);
      windows.getLastFocused = windows.getCurrent;

      // Only listeners added after this script runs can be reached.
      const watch = (event, name) => {
        if (!event) return;
        const set = new Set();
        listeners.set(name, set);
        const add = event.addListener.bind(event);
        const remove = event.removeListener.bind(event);
        const has = event.hasListener.bind(event);
        event.addListener = (f) => (set.add(f), add(f));
        event.removeListener = (f) => (set.delete(f), remove(f));
        event.hasListener = (f) => set.has(f) || has(f);
      };
      watch(tabs.onActivated, 'activated');
      watch(tabs.onCreated, 'created');
      watch(tabs.onRemoved, 'removed');
      watch(windows.onFocusChanged, 'focusChanged');
    })();
    """#
}
