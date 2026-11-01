import Foundation

/// One Boost: Arc's per-site customisation. Kite keeps Arc's code Boost (CSS and JavaScript)
/// and its zaps for one domain; Arc's colour, font and text size/case options come later.
public struct Boost: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The site it runs on, as `BoostLibrary.domain(of:)` gives it (lower case, no `www.`).
    public var domain: String
    public var css: String
    public var js: String
    /// Arc's Zap: selectors of elements hidden on the site, oldest first. Part of the Boost's
    /// data in Arc (`BoostData`), so turning the Boost off shows them again.
    public var zaps: [String]
    /// Arc lets you switch a Boost off without deleting it.
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, domain: String, css: String = "", js: String = "",
        zaps: [String] = [], isEnabled: Bool = true, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.css = css
        self.js = js
        self.zaps = zaps
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Whether running it would change anything.
    public var isEmpty: Bool {
        css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && zaps.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, name, domain, css, js, zaps, isEnabled, createdAt, updatedAt
    }

    /// boosts.json written before Boosts held zaps has no `zaps`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        domain = try container.decode(String.self, forKey: .domain)
        css = try container.decode(String.self, forKey: .css)
        js = try container.decode(String.self, forKey: .js)
        zaps = try container.decodeIfPresent([String].self, forKey: .zaps) ?? []
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// Every Boost in the profile (boosts.json), newest first.
public struct BoostLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public private(set) var boosts: [Boost] = []

    public init(boosts: [Boost] = []) {
        self.boosts = boosts
    }

    /// The domain a Boost for `url` runs on: its host in lower case without a leading `www.`.
    /// nil for pages that aren't on the web (kite://, file:, about:blank).
    public static func domain(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    public func boost(_ id: UUID) -> Boost? {
        boosts.first { $0.id == id }
    }

    /// Every Boost for the page's site, on or off.
    public func boosts(for url: URL?) -> [Boost] {
        guard let domain = Self.domain(of: url) else { return [] }
        return boosts(forDomain: domain)
    }

    public func boosts(forDomain domain: String) -> [Boost] {
        boosts.filter { $0.domain == domain }
    }

    /// The Boosts that run when `url` loads, oldest first so a newer one's CSS wins.
    public func activeBoosts(for url: URL?) -> [Boost] {
        guard let domain = Self.domain(of: url) else { return [] }
        return activeBoosts(forDomain: domain)
    }

    public func activeBoosts(forDomain domain: String) -> [Boost] {
        boosts(forDomain: domain).filter { $0.isEnabled && !$0.isEmpty }.reversed()
    }

    /// The zaps hidden on a site: those of its Boosts that are on, oldest first, each once.
    public func activeZaps(forDomain domain: String) -> [String] {
        var seen = Set<String>()
        return activeBoosts(forDomain: domain).flatMap(\.zaps).filter { seen.insert($0).inserted }
    }

    /// The hiding CSS for a site's active zaps (ZapLibrary's rule per selector).
    public func zapCSS(forDomain domain: String) -> String {
        ZapLibrary.css(activeZaps(forDomain: domain))
    }

    /// The Boost a zap picked on `domain` goes to: `preferred` (the Boost being edited) when it's
    /// for that site, else the site's newest Boost.
    public func zapBoost(forDomain domain: String, preferring preferred: UUID? = nil) -> Boost? {
        if let preferred, let boost = boost(preferred), boost.domain == domain { return boost }
        return boosts(forDomain: domain).first
    }

    /// Adds a zap to the site's Boost (see `zapBoost`), making a new Boost for the site when it
    /// has none, as Arc's New Boost does. Returns the Boost's id; nil for an empty selector or domain.
    @discardableResult
    public mutating func addZap(
        _ selector: String, domain: String, preferring preferred: UUID? = nil, now: Date = Date()
    ) -> UUID? {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, !domain.isEmpty else { return nil }
        guard let boost = zapBoost(forDomain: domain, preferring: preferred) else {
            let boost = Boost(name: domain, domain: domain, zaps: [selector], createdAt: now)
            boosts.insert(boost, at: 0)
            return boost.id
        }
        update(boost.id, now: now) { if !$0.zaps.contains(selector) { $0.zaps.append(selector) } }
        return boost.id
    }

    /// Arc's removeZap: the element shows again.
    public mutating func removeZap(_ selector: String, from id: UUID, now: Date = Date()) {
        update(id, now: now) { $0.zaps.removeAll { $0 == selector } }
    }

    /// Moves zaps kept on their own (zaps.json, before Boosts held them) into each site's Boost.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func migrate(_ zaps: ZapLibrary, now: Date = Date()) -> Bool {
        let before = self
        for domain in zaps.sites.keys.sorted() {
            for selector in zaps.selectors(for: domain) {
                addZap(selector, domain: domain, now: now)
            }
        }
        return self != before
    }

    /// A new, empty Boost for the page's site; nil when the page isn't on the web.
    @discardableResult
    public mutating func create(for url: URL?, now: Date = Date()) -> Boost? {
        guard let domain = Self.domain(of: url) else { return nil }
        let boost = Boost(name: domain, domain: domain, createdAt: now)
        boosts.insert(boost, at: 0)
        return boost
    }

    /// Applies `change` to the Boost; returns false when there's no such Boost.
    @discardableResult
    public mutating func update(_ id: UUID, now: Date = Date(), _ change: (inout Boost) -> Void) -> Bool {
        guard let index = boosts.firstIndex(where: { $0.id == id }) else { return false }
        var boost = boosts[index]
        change(&boost)
        boost.id = id
        guard boost != boosts[index] else { return true }
        boost.updatedAt = now
        boosts[index] = boost
        return true
    }

    public mutating func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update(id, now: now) { $0.name = name }
    }

    public mutating func setEnabled(_ id: UUID, _ enabled: Bool, now: Date = Date()) {
        update(id, now: now) { $0.isEnabled = enabled }
    }

    @discardableResult
    public mutating func delete(_ id: UUID) -> Boost? {
        guard let index = boosts.firstIndex(where: { $0.id == id }) else { return nil }
        return boosts.remove(at: index)
    }
}

/// The script that applies a page's Boosts: CSS and zaps as `<style>` elements from the start of the
/// document, JavaScript once the document has been parsed. It runs in the page's own world,
/// top frame only, and only once per document (Chromium may run it again at load start).
public enum BoostScript {
    /// `isValidJS` checks a Boost's JavaScript (wrapped as a function body) parses. A Boost whose
    /// JavaScript doesn't is left out, so one typo can't break the other document-start
    /// scripts it's joined with. Its CSS still applies.
    public static func source(for boosts: [Boost], isValidJS: (String) -> Bool = { _ in true }) -> String? {
        let styles = boosts.filter { !$0.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let scripts = boosts.filter {
            !$0.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isValidJS(wrapped($0.js))
        }
        var seen = Set<String>()
        let zapCSS = ZapLibrary.css(boosts.flatMap(\.zaps).filter { seen.insert($0).inserted })
        guard !styles.isEmpty || !scripts.isEmpty || !zapCSS.isEmpty else { return nil }

        let styleList = styles.map { "[\(literal("kite-boost-" + $0.id.uuidString.lowercased())), \(literal($0.css))]" }
        let functions = scripts.map { "    () => \(wrapped($0.js))," }
        return """
        (() => {
          if (window !== window.top || window.__kiteBoosts) return;
          window.__kiteBoosts = true;
          const styles = [\(styleList.joined(separator: ", "))];
          const zaps = \(literal(zapCSS));
          const addStyles = () => {
            const root = document.head || document.documentElement;
            for (const [id, css] of styles) {
              if (document.getElementById(id)) continue;
              const style = document.createElement('style');
              style.id = id;
              style.textContent = css;
              root.append(style);
            }
            // Zaps go in one element of their own, which a zap or undo replaces live (ZapScript.apply).
            if (zaps && !document.querySelector('style[\(ZapScript.styleAttribute)]')) {
              const style = document.createElement('style');
              style.setAttribute('\(ZapScript.styleAttribute)', '');
              style.textContent = zaps;
              root.append(style);
            }
          };
          if (document.documentElement) addStyles();
          else document.addEventListener('readystatechange', addStyles, { once: true });
          const scripts = [
        \(functions.joined(separator: "\n"))
          ];
          const run = () => {
            for (const script of scripts) {
              try { script(); } catch (error) { console.error('Kite Boost:', error); }
            }
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true });
          else run();
        })();
        """
    }

    /// A Boost's JavaScript as a function expression, so `return` works and its names stay local.
    public static func wrapped(_ js: String) -> String {
        "(function () {\n\(js)\n})()"
    }

    /// A JavaScript string literal for `text`.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]),
              var json = String(data: data, encoding: .utf8) else { return "''" }
        json.removeFirst()
        json.removeLast()
        // JSON allows U+2028/2029 in strings; older JavaScript parsers don't, and "</" in a literal is harmless here.
        return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
