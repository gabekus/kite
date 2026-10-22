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

    public init(hideSelectors: [String] = [], exceptions: [String] = [], injectedScript: String = "", generichide: Bool = false) {
        self.hideSelectors = hideSelectors
        self.exceptions = exceptions
        self.injectedScript = injectedScript
        self.generichide = generichide
    }

    private enum CodingKeys: String, CodingKey {
        case hideSelectors = "hide_selectors", exceptions, injectedScript = "injected_script", generichide
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideSelectors = try c.decodeIfPresent([String].self, forKey: .hideSelectors) ?? []
        exceptions = try c.decodeIfPresent([String].self, forKey: .exceptions) ?? []
        injectedScript = try c.decodeIfPresent(String.self, forKey: .injectedScript) ?? ""
        generichide = try c.decodeIfPresent(Bool.self, forKey: .generichide) ?? false
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
