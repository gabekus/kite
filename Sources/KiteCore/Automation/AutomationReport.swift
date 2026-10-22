import Foundation

/// Formats what the browser reports back to the model. Anything a page
/// controls (titles, URLs, text) is wrapped as untrusted content.
public enum AutomationReport {
    public struct Tab: Hashable, Sendable {
        public var id: UUID
        public var title: String
        public var url: URL?
        public var space: String
        /// "favorite", "pinned" or "tab".
        public var section: String
        public var isFront: Bool

        public init(id: UUID, title: String, url: URL?, space: String, section: String, isFront: Bool) {
            self.id = id
            self.title = title
            self.url = url
            self.space = space
            self.section = section
            self.isFront = isFront
        }
    }

    public static func tabs(_ tabs: [Tab]) -> String {
        guard !tabs.isEmpty else { return "No tabs are open." }
        let lines = tabs.map { tab in
            let flags = [tab.isFront ? "front" : nil, tab.section == "tab" ? nil : tab.section].compactMap { $0 }
            let title = AccessibilityOutline.clean(tab.title, limit: 160)
            return "- tab \(tab.id.uuidString) [\(([tab.space] + flags).joined(separator: ", "))] "
                + AccessibilityOutline.quote(title) + " " + (tab.url?.absoluteString ?? "about:blank")
        }
        return "\(tabs.count) tab\(tabs.count == 1 ? "" : "s"). Pass a tab id as \"tab\" to the other tools.\n"
            + UntrustedContent.wrap(lines.joined(separator: "\n"), source: "Kite tab list")
    }

    public static func page(tab: UUID, url: URL?, title: String, outline: String?, text: String, textLimit: Int) -> String {
        let source = url?.absoluteString ?? "about:blank"
        var body = "URL: \(source)\nTitle: \(AccessibilityOutline.clean(title, limit: 300))\n"
        if let outline {
            body += "\nAccessibility outline (refs work with click and type):\n"
            body += outline.isEmpty ? "(empty)\n" : outline + "\n"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = trimmed.count > textLimit
        body += "\nPage text\(cut ? " (first \(textLimit) of \(trimmed.count) characters)" : ""):\n"
        body += cut ? String(trimmed.prefix(textLimit)) : trimmed
        return "Tab \(tab.uuidString)\n" + UntrustedContent.wrap(body, source: source)
    }

    /// One line after an action: where the tab ended up.
    public static func afterAction(_ action: String, tab: UUID, url: URL?, title: String) -> String {
        "\(action) Tab \(tab.uuidString) is now at:\n"
            + UntrustedContent.wrap(
                AccessibilityOutline.quote(AccessibilityOutline.clean(title, limit: 200)) + " " + (url?.absoluteString ?? "about:blank"),
                source: url?.absoluteString ?? "about:blank")
    }
}

/// The "Allow Claude to control the browser" switch, kept per profile next to
/// the session so a throwaway test profile never turns it on for the real one.
public struct AutomationSettings: Codable, Hashable, Sendable {
    public var allowClaudeControl: Bool

    public init(allowClaudeControl: Bool = false) {
        self.allowClaudeControl = allowClaudeControl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowClaudeControl = try c.decodeIfPresent(Bool.self, forKey: .allowClaudeControl) ?? false
    }

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("automation.json")
    }

    /// Missing or unreadable means off.
    public static func load(from url: URL) -> AutomationSettings {
        guard let data = try? Data(contentsOf: url) else { return AutomationSettings() }
        return (try? JSONDecoder().decode(AutomationSettings.self, from: data)) ?? AutomationSettings()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
