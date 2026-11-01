import Foundation

/// Arc's Zap (part of Boosts): elements the user picked on a site stay hidden there. Arc keeps
/// them in the site's Boost and turns each selector into `<selector> { display: none !important; }`
/// (BoostsClient). Kite keeps them per site here until Boosts can hold them.
public struct ZapLibrary: Codable, Equatable, Sendable {
    public var version = 1
    /// Selectors by site (`domain(of:)`), oldest first.
    public private(set) var sites: [String: [String]] = [:]

    public init(sites: [String: [String]] = [:]) {
        self.sites = sites.filter { !$0.value.isEmpty }
    }

    /// The site a page's zaps belong to: its host in lower case without a leading `www.`
    /// (the same rule as Boosts). nil for pages that aren't on the web.
    public static func domain(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return domain(ofHost: url.host())
    }

    public static func domain(ofHost host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    public func selectors(for domain: String) -> [String] {
        sites[domain] ?? []
    }

    /// Adds a zap; false when it's empty or the site already has it.
    @discardableResult
    public mutating func add(_ selector: String, for domain: String) -> Bool {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, !domain.isEmpty, !selectors(for: domain).contains(selector) else { return false }
        sites[domain, default: []].append(selector)
        return true
    }

    /// Arc's removeZap: the element shows again.
    @discardableResult
    public mutating func remove(_ selector: String, for domain: String) -> Bool {
        guard var list = sites[domain], let index = list.firstIndex(of: selector) else { return false }
        list.remove(at: index)
        sites[domain] = list.isEmpty ? nil : list
        return true
    }

    /// The site's hiding CSS. One rule per selector, so one the browser can't parse doesn't void the rest.
    public func css(for domain: String) -> String {
        Self.css(selectors(for: domain))
    }

    public static func css(_ selectors: [String]) -> String {
        selectors.map { "\($0) { display: none !important; }" }.joined(separator: "\n")
    }
}

/// The scripts that apply zaps to pages.
public enum ZapScript {
    /// Marks Kite's zap `<style>` element.
    public static let styleAttribute = "data-kite-zap"
    /// The isolated world (Chromium) / content world (WebKit) the document-start script runs in,
    /// so pages can't read other sites' zaps from it.
    public static let worldName = "kite-zap"

    /// Run at the start of every document in Kite's own world: hides the zaps for the page's site.
    /// It carries every site's zaps, so it must never run in the page's world. A later copy (the
    /// library changed) reuses the first one's style element, so stale zaps don't stay hidden.
    public static func documentStart(_ library: ZapLibrary) -> String {
        let sites = library.sites.mapValues { ZapLibrary.css($0) }.filter { !$0.value.isEmpty }
        let data = (try? JSONSerialization.data(withJSONObject: sites, options: [.sortedKeys])) ?? Data("{}".utf8)
        let table = escaped(String(decoding: data, as: UTF8.self))
        return """
            (() => {
              if (window !== window.top) return;
              let host = location.hostname.toLowerCase().replace(/\\.$/, '');
              if (host.startsWith('www.') && host.length > 4) host = host.slice(4);
              const css = (\(table))[host] || '';
              if (window.__kiteZapStyle) { window.__kiteZapStyle.textContent = css; return; }
              if (!css) return;
            \(attachStyle)
              window.__kiteZapStyle = style;
            })();
            """
    }

    /// Replaces the page's zap CSS now (after a zap or an undo), in the page's world. Only that
    /// site's CSS goes in.
    public static func apply(css: String) -> String {
        """
        (() => {
          const css = \(literal(css));
          const old = document.querySelector('style[\(styleAttribute)]');
          if (old) { old.textContent = css; return; }
          if (!css) return;
        \(attachStyle)
        })();
        """
    }

    /// The page's site as the scripts work it out, for asking which zaps to apply live.
    public static let hostScript = "location.hostname"

    /// Adds `css` as Kite's style element, from document start (no `<html>` yet) on, and again
    /// after load in case the page replaced `<head>`.
    private static let attachStyle = """
          const style = document.createElement('style');
          style.setAttribute('\(styleAttribute)', '');
          style.textContent = css;
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

    /// A JavaScript string literal for `text`.
    public static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]) else { return "''" }
        return escaped(String(decoding: data.dropFirst().dropLast(), as: UTF8.self))
    }

    /// JSON is JavaScript except for U+2028/2029 in strings on older parsers.
    private static func escaped(_ json: String) -> String {
        json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// What the picker learned about the element under the pointer.
public struct ZapTarget: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The element's box in CSS pixels from the viewport's top-left corner.
    public var rect: Rect
    /// The page's host (the page can navigate while the picker is open).
    public var host: String?
    /// A selector matching only this element.
    public var selector: String?
    /// A selector for it and the elements like it (Arc's "Zap all related elements"), when
    /// there are some (2 to 100, Arc's cap on candidates).
    public var related: String?
    public var relatedCount: Int?
    /// Boxes of the related elements, for showing what a related zap would hide.
    public var relatedRects: [Rect]?

    public init(rect: Rect, host: String? = nil, selector: String? = nil, related: String? = nil, relatedCount: Int? = nil, relatedRects: [Rect]? = nil) {
        self.rect = rect
        self.host = host
        self.selector = selector
        self.related = related
        self.relatedCount = relatedCount
        self.relatedRects = relatedRects
    }

    public static func decode(_ json: Any?) -> ZapTarget? {
        guard let json = json as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZapTarget.self, from: data)
    }
}

/// The element picker's page side (Arc: getHoveredElement, getSelectorCandidates and
/// rectsForSelector, called by the native overlay). Each call returns JSON for `ZapTarget`.
public enum ZapPickerScript {
    /// The element at a viewport point, box only (hover).
    public static func hovered(x: Double, y: Double) -> String {
        call("hovered", x: x, y: y)
    }

    /// The element at a viewport point with the selectors that would zap it (click).
    public static func target(x: Double, y: Double) -> String {
        call("target", x: x, y: y)
    }

    private static func call(_ mode: String, x: Double, y: Double) -> String {
        "(\(functions))('\(mode)', \(number(x)), \(number(y)))"
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "0"
    }

    /// Kite's own selector builder: ids and class names that look hand-written, else
    /// `:nth-of-type` steps, scoped to the nearest ancestor with a usable id.
    static let functions = """
        function (mode, x, y) {
          const box = (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, width: r.width, height: r.height }; };
          let el = document.elementFromPoint(x, y);
          if (!el || el === document.documentElement || el === document.body) return null;
          if (mode === 'hovered') return JSON.stringify({ rect: box(el), host: location.hostname });
          const esc = (s) => window.CSS && CSS.escape ? CSS.escape(s) : s;
          const count = (sel) => { try { return document.querySelectorAll(sel).length; } catch (e) { return 0; } };
          // Generated names (hashes, long digit runs) change between visits.
          const usable = (name) => name.length > 0 && name.length <= 40 && !/\\d{3,}/.test(name)
            && !/^(css|sc|jsx|emotion|svelte)-/.test(name) && !/^(?=.*\\d)(?=.*[a-zA-Z])[a-zA-Z0-9_]{5,}$/.test(name);
          const tag = (n) => n.tagName.toLowerCase();
          const idOf = (n) => n.id && usable(n.id) && count('#' + esc(n.id)) === 1 ? '#' + esc(n.id) : null;
          const classes = (n) => Array.from(n.classList || []).filter(usable).slice(0, 3).map((c) => '.' + esc(c)).join('');
          const nth = (n) => {
            let i = 1;
            for (let s = n.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === n.tagName) i++;
            return tag(n) + ':nth-of-type(' + i + ')';
          };
          // Nearest ancestor (below <body>) with an id, as the scope of both selectors.
          let scope = null;
          for (let a = el.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
            const id = idOf(a);
            if (id) { scope = { node: a, selector: id }; break; }
          }
          const within = (sel) => scope ? scope.selector + ' ' + sel : sel;

          let selector = idOf(el);
          if (!selector) {
            const own = tag(el) + classes(el);
            if (count(within(own)) === 1) selector = within(own);
          }
          if (!selector) {
            const steps = [];
            for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
              if (scope && n === scope.node) break;
              if (n === document.body) { steps.unshift('body'); break; }
              steps.unshift(nth(n));
              const candidate = (scope ? scope.selector + ' > ' : '') + steps.join(' > ');
              if (steps.length > 1 && count(candidate) === 1) { selector = candidate; break; }
            }
            if (!selector) selector = (scope ? scope.selector + ' > ' : '') + steps.join(' > ');
            if (count(selector) !== 1) selector = null;
          }

          let related = null, relatedCount = null, relatedRects = null;
          const own = classes(el);
          let candidate = own ? within(tag(el) + own) : null;
          if (!candidate && el.parentElement && el.parentElement !== document.body) {
            const parent = classes(el.parentElement);
            if (parent) candidate = within(tag(el.parentElement) + parent + ' > ' + tag(el));
          }
          if (candidate) {
            const n = count(candidate);
            if (n >= 2 && n <= 100) {
              related = candidate;
              relatedCount = n;
              relatedRects = Array.from(document.querySelectorAll(candidate)).map(box);
            }
          }
          return JSON.stringify({ rect: box(el), host: location.hostname, selector, related, relatedCount, relatedRects });
        }
        """
}
