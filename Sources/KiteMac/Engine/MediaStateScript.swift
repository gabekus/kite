import Foundation

/// Reports what a page is playing (MediaState) and runs the Mini Player's commands.
///
/// `source` runs in Kite's own isolated world in every page's main frame and reports through
/// `report` (a CDP binding on Chromium, a script message handler on WebKit): `null` as the page
/// starts, then the element that played last whenever its state, metadata or picture in
/// picture changes. Commands run in the same world (`MediaCommand.script`).
///
/// `pageHook` runs in the page's own world, only to learn which Media Session actions
/// (previous / next track, toggle microphone / camera) the page handles, and its microphone and
/// camera state (`setMicrophoneActive` / `setCameraActive`), and to call its handler when asked. It talks to the
/// isolated world with string-only window events; it calls nothing but the page's own handlers.
enum MediaStateScript {
    static let worldName = "kite-media"
    /// The Chromium binding and the WebKit message handler.
    static let bindingName = "__kiteMediaReport"

    static let source = #"""
    (() => {
      if (window !== window.top || globalThis.__kiteMedia) return;
      const send = typeof __kiteMediaReport === 'function'
        ? (s) => __kiteMediaReport(s)
        : (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__kiteMediaReport)
          ? (s) => window.webkit.messageHandlers.__kiteMediaReport.postMessage(s) : null;
      if (!send) return;

      let current = null;
      let actions = [];
      let last = 'null';
      let poll = 0;
      // Tab volume (Mini Player "Adjust Tab Volume"): every element plays at the volume the
      // page gave it times `level`. `wanted` keeps the page's own volume per element, `ours`
      // the value Kite last set, so its own volumechange (or a mute toggle) isn't taken for the
      // page's.
      let level = 1;
      const wanted = new WeakMap();
      const ours = new WeakMap();
      const wantedOf = (m) => wanted.has(m) ? wanted.get(m) : m.volume;
      const apply = (m) => {
        if (!wanted.has(m)) { if (level === 1) return; wanted.set(m, m.volume); }
        const target = Math.min(1, Math.max(0, wanted.get(m) * level));
        ours.set(m, target);
        if (m.volume === target) return;
        try { m.volume = target; } catch (e) { ours.delete(m); }
      };

      const pip = (m) => document.pictureInPictureElement === m || m.webkitPresentationMode === 'picture-in-picture';
      const snapshot = () => {
        if (!current || !current.isConnected || !(current.currentSrc || current.srcObject)) return null;
        const meta = navigator.mediaSession && navigator.mediaSession.metadata;
        const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
        return {
          playing: !current.paused && !current.ended,
          video: current instanceof HTMLVideoElement && current.videoWidth > 0,
          muted: current.muted || wantedOf(current) === 0,
          pip: pip(current),
          title: (meta && meta.title) || document.title || '',
          artist: (meta && meta.artist) || null,
          artwork: art,
          actions,
          volume: current.volume,
          level,
        };
      };
      const report = () => {
        const state = snapshot();
        if (!state) current = null;
        const json = JSON.stringify(state);
        if (json !== last) { last = json; send(json); }
        // Titles change without media events (the next song); look again while there's media.
        clearInterval(poll);
        poll = state ? setInterval(report, state.playing ? 2000 : 10000) : 0;
      };

      const events = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata',
        'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'];
      for (const type of events) {
        document.addEventListener(type, (e) => {
          const m = e.target;
          if (!(m instanceof HTMLMediaElement)) return;
          if (type === 'volumechange') {
            // Still the volume Kite set (its own change, or the page toggling mute): keep the
            // page's volume. Anything else is the page choosing a new volume.
            if (!(ours.has(m) && ours.get(m) === m.volume)) { ours.delete(m); wanted.set(m, m.volume); apply(m); }
          } else if (type === 'play' || type === 'loadedmetadata') apply(m);
          // Like Chromium's media sessions: muted autoplay (background videos) doesn't count
          // until it's unmuted.
          if (m !== current && (type === 'play' || type === 'playing' || type === 'volumechange')
              && !m.paused && !m.muted && wantedOf(m) > 0) current = m;
          if (m === current) report();
        }, true);
      }
      // A call's controls go in their own report (CallControls), whether or not anything plays.
      const call = { mic: false, cam: false };
      let lastCall = '';
      const reportCall = () => {
        const json = JSON.stringify({ call: { actions: actions.filter((a) => a.startsWith('toggle')), mic: call.mic, cam: call.cam } });
        if (json !== lastCall) { lastCall = json; send(json); }
      };
      window.addEventListener('__kiteMediaActions', (e) => {
        actions = typeof e.detail === 'string' && e.detail ? e.detail.split(',') : [];
        if (current) report();
        reportCall();
      });
      window.addEventListener('__kiteMediaCapture', (e) => {
        if (typeof e.detail !== 'string') return;
        const key = e.detail.slice(0, 3);
        if (key === 'mic' || key === 'cam') { call[key] = e.detail.endsWith('1'); reportCall(); }
      });

      const playing = () => [...document.querySelectorAll('video,audio')].find((m) => !m.paused && !m.ended);
      globalThis.__kiteMedia = {
        run(command, value) {
          if (command === 'volume') {
            const next = Number(value);
            if (!Number.isFinite(next)) return;
            level = Math.min(1, Math.max(0, next));
            for (const el of document.querySelectorAll('video,audio')) apply(el);
            report();
            return;
          }
          const m = current || playing();
          switch (command) {
            case 'play': if (m) m.play().catch(() => {}); break;
            case 'pause': if (m) m.pause(); break;
            case 'previoustrack': case 'nexttrack': case 'togglemicrophone': case 'togglecamera':
              window.dispatchEvent(new CustomEvent('__kiteMediaAction', { detail: command })); break;
            case 'enterpip':
              if (m instanceof HTMLVideoElement && !pip(m)) {
                if (m.requestPictureInPicture && document.pictureInPictureEnabled !== false) m.requestPictureInPicture().catch(() => {});
                else if (m.webkitSetPresentationMode) m.webkitSetPresentationMode('picture-in-picture');
              }
              break;
            case 'exitpip':
              if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
              else if (m && m.webkitPresentationMode === 'picture-in-picture') m.webkitSetPresentationMode('inline');
              break;
          }
        },
      };
      send('null');
      reportCall();
    })();
    """#

    static let pageHook = #"""
    (() => {
      if (window !== window.top || typeof MediaSession === 'undefined') return;
      const proto = MediaSession.prototype;
      const original = proto.setActionHandler;
      if (typeof original !== 'function') return;
      const handlers = new Map();
      const wanted = ['previoustrack', 'nexttrack', 'togglemicrophone', 'togglecamera'];
      proto.setActionHandler = function (action, handler) {
        const result = original.apply(this, arguments);
        if (wanted.includes(action)) {
          if (typeof handler === 'function') handlers.set(action, handler); else handlers.delete(action);
          window.dispatchEvent(new CustomEvent('__kiteMediaActions', { detail: [...handlers.keys()].join(',') }));
        }
        return result;
      };
      // A call's microphone and camera state (the Mini Player's Toggle Microphone / Toggle Camera).
      for (const [name, key] of [['setMicrophoneActive', 'mic'], ['setCameraActive', 'cam']]) {
        const set = proto[name];
        if (typeof set !== 'function') continue;
        proto[name] = function (active) {
          const result = set.apply(this, arguments);
          window.dispatchEvent(new CustomEvent('__kiteMediaCapture', { detail: key + (active ? '1' : '0') }));
          return result;
        };
      }
      window.addEventListener('__kiteMediaAction', (e) => {
        const handler = handlers.get(e.detail);
        if (handler) handler.call(navigator.mediaSession, { action: e.detail });
      });
    })();
    """#
}
