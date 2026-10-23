import Foundation

/// A filter list the ad blocker downloads. The lists are GPL / CC BY-SA, so Kite
/// fetches them at runtime instead of shipping them.
public struct FilterList: Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: URL
    /// Lets the list use uBlock Origin's `trusted-*` scriptlets. Only uBO's own lists are.
    public var trusted: Bool

    public static let defaults: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, trusted: false),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, trusted: false),
        FilterList(id: "ublock-filters", name: "uBlock filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!, trusted: true),
        FilterList(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")!, trusted: true),
    ]

    /// How often lists and scriptlets are re-downloaded.
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    public static func isRefreshDue(lastUpdated: Date?, now: Date = Date()) -> Bool {
        guard let lastUpdated else { return true }
        // A clock that jumped backwards shouldn't postpone updates for days.
        return now.timeIntervalSince(lastUpdated) >= refreshInterval || lastUpdated > now
    }

    /// A downloaded list is plausible only if it starts like an Adblock Plus list.
    /// Catches captive portals and error pages before they replace a good list.
    public static func looksValid(_ text: String) -> Bool {
        let head = text.prefix(4096)
        return head.hasPrefix("[Adblock") || head.contains("! Title:")
    }
}

/// What adblock-rust says to inject into a page (`url_cosmetic_resources`).
public struct CosmeticResources: Decodable, Equatable, Sendable {
    public var hideSelectors: [String]
    public var exceptions: [String]
    public var injectedScript: String
    public var generichide: Bool
    /// uBO procedural and action filters (`:has-text()`, `:upward()`, `:remove()`…)
    /// that plain CSS can't express; applied by `ProceduralFilter.engineScript`.
    public var procedural: [ProceduralFilter]

    public init(
        hideSelectors: [String] = [],
        exceptions: [String] = [],
        injectedScript: String = "",
        generichide: Bool = false,
        procedural: [ProceduralFilter] = []
    ) {
        self.hideSelectors = hideSelectors
        self.exceptions = exceptions
        self.injectedScript = injectedScript
        self.generichide = generichide
        self.procedural = procedural
    }

    private enum CodingKeys: String, CodingKey {
        case hideSelectors = "hide_selectors", exceptions, injectedScript = "injected_script", generichide
        case proceduralActions = "procedural_actions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideSelectors = try c.decodeIfPresent([String].self, forKey: .hideSelectors) ?? []
        exceptions = try c.decodeIfPresent([String].self, forKey: .exceptions) ?? []
        injectedScript = try c.decodeIfPresent(String.self, forKey: .injectedScript) ?? ""
        generichide = try c.decodeIfPresent(Bool.self, forKey: .generichide) ?? false
        // Each entry is itself JSON; one Kite can't apply is skipped, not fatal.
        let actions = try c.decodeIfPresent([String].self, forKey: .proceduralActions) ?? []
        procedural = actions.compactMap(ProceduralFilter.init(json:))
    }

    /// One rule per selector: a single invalid selector would void a combined rule.
    public static func hidingCSS(_ selectors: [String]) -> String {
        selectors.sorted().map { "\($0){display:none!important}" }.joined(separator: "\n")
    }

    /// The script run at document start in pages on `host`: uBO scriptlets, the
    /// site's hiding CSS, and (unless the site has `$generichide`) an observer that
    /// queues new classes and ids. The browser empties the queue by calling
    /// `window[drain]()` (see `drainScript`) and answers with generic hiding rules.
    ///
    /// `styleID` marks the style element so later generic CSS can be appended to it.
    public func documentStartScript(host: String, styleID: String, drain: String?) -> String {
        func literal(_ string: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        }
        // The browser may run this a second time for a tab's first page; the marker
        // makes that a no-op.
        let marker = literal("__kite_" + styleID)
        var script = "(() => {\nif (location.hostname !== \(literal(host)) || window[\(marker)]) return;\n"
        script += "Object.defineProperty(window, \(marker), { value: true });\n"
        // adblock-rust already wraps each scriptlet call in try/catch. Its helper
        // functions stay at function scope so the calls can find them.
        if !injectedScript.isEmpty {
            script += injectedScript + "\n"
        }
        script += """
            const style = document.createElement('style');
            style.setAttribute('data-kite', \(literal(styleID)));
            style.textContent = \(literal(Self.hidingCSS(hideSelectors)));
            // At document start there's no <html> yet: attach as soon as there is, and
            // again after load in case the page's own scripts replaced <head>.
            const attach = () => {
              const root = document.head || document.documentElement;
              if (root && !style.isConnected) root.appendChild(style);
              return style.isConnected;
            };
            if (!attach()) {
              const early = new MutationObserver(() => { if (attach()) early.disconnect(); });
              early.observe(document, { childList: true, subtree: true });
            }
            document.addEventListener('DOMContentLoaded', attach, { once: true });
            addEventListener('load', attach, { once: true });

            """
        if !procedural.isEmpty, let rules = try? JSONEncoder().encode(procedural) {
            script += "const procedural = \(String(decoding: rules, as: UTF8.self));\n" + ProceduralFilter.engineScript
        }
        if let drain, !generichide {
            script += "const drainName = \(literal(drain));\n" + Self.classIDObserver
        }
        return script + "})();\n"
    }

    /// Queues classes and ids not seen before. Polling from the browser (rather
    /// than a Runtime binding) keeps the DevTools Runtime domain off, which bot
    /// checks can detect.
    static let classIDObserver = """
        const seen = new Set();
        let classes = [], ids = [];
        const add = (el) => {
          if (el.id && !seen.has('#' + el.id)) { seen.add('#' + el.id); ids.push(el.id); }
          const list = el.classList;
          if (list) for (const c of list) if (!seen.has('.' + c)) { seen.add('.' + c); classes.push(c); }
        };
        const scan = (root) => {
          if (root.nodeType !== 1) return;
          add(root);
          for (const el of root.querySelectorAll('[id],[class]')) add(el);
        };
        const start = () => {
          scan(document.documentElement);
          new MutationObserver((records) => {
            for (const r of records) {
              if (r.type === 'attributes') add(r.target);
              else for (const n of r.addedNodes) scan(n);
            }
          }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id'] });
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
        else start();
        Object.defineProperty(window, drainName, { configurable: true, value: () => {
          if (!classes.length && !ids.length) return null;
          const batch = JSON.stringify({ classes, ids });
          classes = []; ids = [];
          return batch;
        } });

        """

    /// Empties the page's class/id queue; evaluates to a JSON string or null.
    public static func drainScript(_ drain: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [drain])
        return "(([name]) => typeof window[name] === 'function' ? window[name]() : null)(\(String(decoding: data, as: UTF8.self)))"
    }

    /// Script that appends generic hiding CSS to the page's style element.
    public static func appendCSSScript(_ selectors: [String], styleID: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [styleID, hidingCSS(selectors)])
        return "(([id, css]) => { const s = document.querySelector('style[data-kite=\"' + id + '\"]'); if (s) s.textContent += '\\n' + css; })(\(String(decoding: data, as: UTF8.self)))"
    }
}

/// The classes and ids a page reported, decoded from the observer's JSON.
public struct SeenClassesAndIDs: Decodable, Sendable {
    public var classes: [String]
    public var ids: [String]
}

/// One uBO procedural or action filter, as adblock-rust's `procedural_actions`
/// gives it: a chain of steps that picks elements, and what to do with them.
///
/// `example.com##h2:has-text(/Promoted/) + div:remove()` becomes
/// steps `[css "h2", has-text "/Promoted/", css " + div"]` and action `remove`.
public struct ProceduralFilter: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var type: String
        public var arg: String
    }

    public struct Action: Codable, Equatable, Sendable {
        public var type: String
        public var arg: String?
    }

    public var selector: [Step]
    /// Nil hides the elements.
    public var action: Action?

    /// Steps the page script implements. adblock-rust doesn't emit `:watch-attr`
    /// (it rejects those filters), so there's nothing to do for it here.
    public static let supportedSteps: Set<String> = [
        "css-selector", "has-text", "matches-attr", "matches-css", "matches-css-before",
        "matches-css-after", "matches-path", "min-text-length", "upward", "xpath",
    ]
    public static let supportedActions: Set<String> = ["remove", "style", "remove-attr", "remove-class"]

    /// Nil for filters with a step or action Kite doesn't know, so a newer
    /// adblock-rust can't make pages run half a rule.
    public init?(json: String) {
        guard let filter = try? JSONDecoder().decode(ProceduralFilter.self, from: Data(json.utf8)),
              filter.selector.first?.type == "css-selector",
              filter.selector.allSatisfy({ Self.supportedSteps.contains($0.type) }),
              filter.action.map({ Self.supportedActions.contains($0.type) }) ?? true
        else { return nil }
        self = filter
    }

    public init(selector: [Step], action: Action? = nil) {
        self.selector = selector
        self.action = action
    }

    /// Applies `procedural` (an array of these, as JSON) once the page has content
    /// and again as it changes. Mutations are batched into one pass per idle
    /// period (at most every 100 ms), and an element is acted on only once.
    static let engineScript = """
        {
          // Per rule: an element hidden by one rule can still need another's style.
          const done = procedural.map(() => new WeakSet());
          const pattern = (arg) => {
            const m = /^\\/(.+)\\/([imsu]*)$/.exec(arg);
            if (m) { try { return new RegExp(m[1], m[2]); } catch (e) { return null; } }
            return { test: (s) => s.includes(arg) };
          };
          const nameValue = (arg) => {
            const i = arg.indexOf('=');
            const unquote = (s) => s.replace(/^"(.*)"$/, '$1');
            return i < 0 ? [pattern(unquote(arg)), null] : [pattern(unquote(arg.slice(0, i))), pattern(unquote(arg.slice(i + 1)))];
          };
          const relative = (nodes, arg) => {
            const out = [];
            const sel = arg.trim();
            for (const n of nodes) {
              try {
                if (/^[+~]/.test(sel)) {
                  if (!n.parentElement) continue;
                  const i = [...n.parentElement.children].indexOf(n) + 1;
                  out.push(...n.parentElement.querySelectorAll(':scope > :nth-child(' + i + ') ' + sel));
                } else {
                  out.push(...n.querySelectorAll(':scope ' + sel));
                }
              } catch (e) {}
            }
            return out;
          };
          const steps = {
            'has-text': (nodes, arg) => { const p = pattern(arg); return p ? nodes.filter((n) => p.test(n.textContent)) : []; },
            'min-text-length': (nodes, arg) => nodes.filter((n) => n.textContent.length >= +arg),
            'matches-path': (nodes, arg) => { const p = pattern(arg); return p && p.test(location.pathname + location.search) ? nodes : []; },
            'matches-attr': (nodes, arg) => {
              const [name, value] = nameValue(arg);
              if (!name) return [];
              return nodes.filter((n) => [...n.attributes].some((a) => name.test(a.name) && (!value || value.test(a.value))));
            },
            'upward': (nodes, arg) => {
              const out = [];
              const count = /^\\d+$/.test(arg) ? +arg : 0;
              for (const n of nodes) {
                let e = n;
                if (count) { for (let i = 0; e && i < count; i++) e = e.parentElement; }
                else { try { e = n.parentElement && n.parentElement.closest(arg); } catch (x) { e = null; } }
                if (e && e !== document.documentElement && e !== document.body) out.push(e);
              }
              return out;
            },
            'xpath': (nodes, arg) => {
              const out = [];
              for (const n of nodes) {
                try {
                  const r = document.evaluate(arg, n, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                  for (let i = 0; i < r.snapshotLength; i++) if (r.snapshotItem(i).nodeType === 1) out.push(r.snapshotItem(i));
                } catch (e) {}
              }
              return out;
            },
          };
          const css = (pseudo) => (nodes, arg) => {
            const i = arg.indexOf(':');
            if (i < 0) return [];
            const prop = arg.slice(0, i).trim(), value = pattern(arg.slice(i + 1).trim());
            return value ? nodes.filter((n) => value.test(getComputedStyle(n, pseudo).getPropertyValue(prop))) : [];
          };
          steps['matches-css'] = css(null);
          steps['matches-css-before'] = css('::before');
          steps['matches-css-after'] = css('::after');
          const select = (rule) => {
            let nodes = null;
            for (const step of rule.selector) {
              if (step.type === 'css-selector') {
                if (nodes === null) { try { nodes = [...document.querySelectorAll(step.arg)]; } catch (e) { return []; } }
                else nodes = relative(nodes, step.arg);
              } else {
                nodes = steps[step.type] ? steps[step.type](nodes || [], step.arg) : [];
              }
              if (!nodes.length) return [];
            }
            return nodes || [];
          };
          const styles = (text) => text.split(';').map((d) => d.trim()).filter(Boolean).map((d) => {
            const i = d.indexOf(':');
            const value = d.slice(i + 1).trim();
            return [d.slice(0, i).trim(), value.replace(/\\s*!important$/, ''), /!important$/.test(value) ? 'important' : ''];
          });
          const apply = (rule, el) => {
            const a = rule.action;
            if (!a) el.style.setProperty('display', 'none', 'important');
            else if (a.type === 'remove') el.remove();
            else if (a.type === 'remove-attr') el.removeAttribute(a.arg);
            else if (a.type === 'remove-class') el.classList.remove(a.arg);
            else if (a.type === 'style') for (const [p, v, imp] of styles(a.arg || '')) el.style.setProperty(p, v, imp);
          };
          const run = () => {
            procedural.forEach((rule, i) => {
              for (const el of select(rule)) {
                // Class and attribute removals can be undone by the page; redo those.
                if (done[i].has(el) && (!rule.action || rule.action.type === 'remove' || rule.action.type === 'style')) continue;
                done[i].add(el);
                try { apply(rule, el); } catch (e) {}
              }
            });
          };
          let pending = false, last = 0;
          const later = (fn) => (typeof requestIdleCallback === 'function' ? requestIdleCallback(fn, { timeout: 300 }) : setTimeout(fn, 50));
          const schedule = () => {
            if (pending) return;
            pending = true;
            setTimeout(() => later(() => { pending = false; last = performance.now(); run(); }), Math.max(0, 100 - (performance.now() - last)));
          };
          const startProcedural = () => {
            run();
            new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id'] });
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startProcedural, { once: true });
          else startProcedural();
        }

        """
}
