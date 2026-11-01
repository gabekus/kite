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

    public struct SpaceSummary: Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var icon: String
        public var pinned: Int
        public var tabs: Int
        public var folders: [String]
        public var isFront: Bool

        public init(id: UUID, name: String, icon: String, pinned: Int, tabs: Int, folders: [String], isFront: Bool) {
            self.id = id
            self.name = name
            self.icon = icon
            self.pinned = pinned
            self.tabs = tabs
            self.folders = folders
            self.isFront = isFront
        }
    }

    /// Space names are the user's own, not a page's, so they aren't wrapped.
    public static func spaces(_ spaces: [SpaceSummary]) -> String {
        spaces.map { space in
            var line = "- space \(space.id.uuidString) \(space.icon) \(AccessibilityOutline.quote(space.name))"
            line += space.isFront ? " [front]" : ""
            line += ": \(space.pinned) pinned, \(space.tabs) tab\(space.tabs == 1 ? "" : "s")"
            if !space.folders.isEmpty { line += "; folders: " + space.folders.map(AccessibilityOutline.quote).joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
    }

    public static func find(_ matches: [ElementFinder.Match], query: String, url: URL?) -> String {
        guard !matches.isEmpty else {
            return "Nothing matches \"\(query)\". Try other words, or read_page for the whole outline."
        }
        return "\(matches.count) match\(matches.count == 1 ? "" : "es"), best first:\n"
            + UntrustedContent.wrap(matches.map { "- \($0.line) [ref=\($0.ref)]" }.joined(separator: "\n"),
                                    source: url?.absoluteString ?? "page")
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
    /// Open Claude's new tabs in a "Claude" space instead of the current one.
    public var useClaudeSpace: Bool
    /// Log every tab's requests (redacted) for Claude, and keep a week of them on disk, not just the tabs Claude drives.
    public var recordNetwork: Bool
    /// Ask the user before Claude submits, sends, posts, pays, buys or deletes anything, opens a file
    /// or closes a tab it didn't open. Off by default: Claude just does what it was asked.
    public var askBeforeActing: Bool

    public init(allowClaudeControl: Bool = false, useClaudeSpace: Bool = false, recordNetwork: Bool = false,
                askBeforeActing: Bool = false) {
        self.allowClaudeControl = allowClaudeControl
        self.useClaudeSpace = useClaudeSpace
        self.recordNetwork = recordNetwork
        self.askBeforeActing = askBeforeActing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowClaudeControl = try c.decodeIfPresent(Bool.self, forKey: .allowClaudeControl) ?? false
        useClaudeSpace = try c.decodeIfPresent(Bool.self, forKey: .useClaudeSpace) ?? false
        recordNetwork = try c.decodeIfPresent(Bool.self, forKey: .recordNetwork) ?? false
        askBeforeActing = try c.decodeIfPresent(Bool.self, forKey: .askBeforeActing) ?? false
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
