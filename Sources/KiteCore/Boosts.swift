import Foundation

/// One Boost: Arc's per-site customisation. This first slice keeps Arc's code Boost, CSS and
/// JavaScript for one domain; Arc's colour, font, text size/case and Zap options come later.
public struct Boost: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The site it runs on, as `BoostLibrary.domain(of:)` gives it (lower case, no `www.`).
    public var domain: String
    public var css: String
    public var js: String
    /// Arc lets you switch a Boost off without deleting it.
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, domain: String, css: String = "", js: String = "",
        isEnabled: Bool = true, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.css = css
        self.js = js
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Whether running it would change anything.
    public var isEmpty: Bool {
        css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        return boosts.filter { $0.domain == domain }
    }

    /// The Boosts that run when `url` loads, oldest first so a newer one's CSS wins.
    public func activeBoosts(for url: URL?) -> [Boost] {
        boosts(for: url).filter { $0.isEnabled && !$0.isEmpty }.reversed()
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

/// The script that applies a page's Boosts: CSS as `<style>` elements from the start of the
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
        guard !styles.isEmpty || !scripts.isEmpty else { return nil }

        let styleList = styles.map { "[\(literal("kite-boost-" + $0.id.uuidString.lowercased())), \(literal($0.css))]" }
        let functions = scripts.map { "    () => \(wrapped($0.js))," }
        return """
        (() => {
          if (window !== window.top || window.__kiteBoosts) return;
          window.__kiteBoosts = true;
          const styles = [\(styleList.joined(separator: ", "))];
          const addStyles = () => {
            for (const [id, css] of styles) {
              if (document.getElementById(id)) continue;
              const style = document.createElement('style');
              style.id = id;
              style.textContent = css;
              (document.head || document.documentElement).append(style);
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
