import Foundation

/// Arc settings that Kite also has, read from Arc's defaults
/// (company.thebrowser.Browser). Delete with ArcImport.swift once Arc has shut down.
public struct ArcSettings: Equatable, Sendable {
    /// `shouldWarnBeforeQuitting`.
    public var warnsBeforeQuitting: Bool?
    /// `openExternalLinksInLittleBrowserEnabled`.
    public var opensExternalLinksInLittleKite: Bool?
    /// The default profile's entry in `autoArchiveTimeThresholdsPerProfile`.
    public var archiveAfter: ArchiveInterval?

    public init(warnsBeforeQuitting: Bool? = nil, opensExternalLinksInLittleKite: Bool? = nil, archiveAfter: ArchiveInterval? = nil) {
        self.warnsBeforeQuitting = warnsBeforeQuitting
        self.opensExternalLinksInLittleKite = opensExternalLinksInLittleKite
        self.archiveAfter = archiveAfter
    }

    public var isEmpty: Bool { self == ArcSettings() }

    /// The settings' names in Arc's words, for the import summary.
    public var names: [String] {
        [
            warnsBeforeQuitting.map { _ in "Warn before quitting" },
            opensExternalLinksInLittleKite.map { _ in "Open links from other apps in Little Arc" },
            archiveAfter.map { "Archive tabs after: \($0.title)" },
        ].compactMap { $0 }
    }

    /// `defaults` is Arc's defaults domain as a dictionary.
    public init(defaults: [String: Any]) {
        self.init(
            warnsBeforeQuitting: Self.bool(defaults["shouldWarnBeforeQuitting"]),
            opensExternalLinksInLittleKite: Self.bool(defaults["openExternalLinksInLittleBrowserEnabled"]),
            archiveAfter: Self.archiveInterval(defaults["autoArchiveTimeThresholdsPerProfile"])
        )
    }

    private static func bool(_ raw: Any?) -> Bool? {
        raw as? Bool
    }

    /// A JSON string, `{"thresholds": [profile, threshold, ...]}`: Swift's encoding of a
    /// dictionary with non-string keys. Profiles are `{"default": {}}` or
    /// `{"custom": {"_0": {...}}}`, the same as in StorableSidebar.json. A threshold is
    /// one of Arc's case names, bare or as `{"twelveHours": {}}`. An empty list means
    /// Arc's default, 12 hours, which Kite also uses, so it imports nothing.
    static func archiveInterval(_ raw: Any?) -> ArchiveInterval? {
        guard let string = raw as? String,
              let root = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              let list = root["thresholds"] as? [Any]
        else { return nil }
        var fallback: ArchiveInterval?
        for i in stride(from: 0, to: list.count - 1, by: 2) {
            let name = (list[i + 1] as? String) ?? (list[i + 1] as? [String: Any])?.keys.first
            guard let interval = name.flatMap(ArchiveInterval.init(rawValue:)) else { continue }
            if (list[i] as? [String: Any])?["default"] != nil { return interval }
            fallback = fallback ?? interval
        }
        // Kite has one profile: with no default-profile entry, take the first there is.
        return fallback
    }
}

extension BrowserState {
    public mutating func apply(_ settings: ArcSettings) {
        if let warns = settings.warnsBeforeQuitting { warnsBeforeQuitting = warns }
        if let interval = settings.archiveAfter { archiveAfter = interval }
    }
}
