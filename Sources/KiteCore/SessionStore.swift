import Foundation

/// Reads and writes the session file. Writes are atomic so a crash mid-save
/// can't leave a half-written session behind, and `backups` keeps rolling copies (Help › Restore Data).
public struct SessionStore: Sendable {
    public static let currentVersion = 1

    public let fileURL: URL
    public let backups: SessionBackups

    /// Backups go in a Backups folder beside the file unless `backups` says otherwise.
    public init(fileURL: URL, backups: SessionBackups? = nil) {
        self.fileURL = fileURL
        self.backups = backups ?? SessionBackups(directory: fileURL.deletingLastPathComponent().appendingPathComponent("Backups"))
    }

    struct File: Codable {
        var version: Int
        var state: BrowserState
    }

    /// Returns nil when there's no session yet. A file that can't be read or decoded is moved aside
    /// (not overwritten), and the newest backup that decodes takes its place; with none, the error is
    /// thrown. If the file couldn't be moved aside it's still there when this throws, and the caller
    /// mustn't save over it.
    public func load() throws -> BrowserState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Self.decode(Data(contentsOf: fileURL))
        } catch {
            let stamp = "corrupt-\(Int(Date().timeIntervalSince1970))"
            // A second bad file in the same second gets its own name: moving onto the first would fail.
            let aside = (0...).lazy
                .map { fileURL.deletingPathExtension().appendingPathExtension($0 == 0 ? "\(stamp).json" : "\(stamp)-\($0).json") }
                .first { !FileManager.default.fileExists(atPath: $0.path) }!
            guard (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil else { throw error }
            if let (_, state) = backups.newestValid() { return state }
            throw error
        }
    }

    /// Writes `state` and returns what was written, for `backups.backUp`.
    @discardableResult
    public func save(_ state: BrowserState) throws -> Data {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encode(state)
        try data.write(to: fileURL, options: .atomic)
        return data
    }

    /// Swaps `backup` in for the session. `current` is kept as a backup first, so a restore can
    /// always be undone by restoring that one. Throws, changing nothing, if `backup` doesn't decode.
    public func restore(_ backup: SessionBackups.Backup, current: BrowserState, now: Date = Date()) throws -> BrowserState {
        let restored = try backups.state(of: backup)
        try backups.backUp(Self.encode(current), now: now, minimumInterval: 0)
        try save(restored)
        return restored
    }

    public static func encode(_ state: BrowserState) throws -> Data {
        try encoder.encode(File(version: currentVersion, state: state))
    }

    static func decode(_ data: Data) throws -> BrowserState {
        try decoder.decode(File.self, from: data).state
    }

    private static let encoder: JSONEncoder = {
        // Default date strategy: an exact Double, so timestamps round-trip losslessly.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// Rolling copies of session.json in the profile's Backups folder, named like Arc's storable
/// backups (`StorableSidebar.2026-11-01-21-05-17-932.json`): `session.yyyy-MM-dd-HH-mm-ss-SSS.json`.
/// Each is a whole session file, so one can also be put back by hand.
public struct SessionBackups: Sendable {
    /// While Kite runs, a save is kept at most this often (Arc backs up once per launch; Kite also
    /// does that, and adds this for sessions left open for days).
    public static let interval: TimeInterval = 60 * 60
    /// Arc keeps every launch's backup (27 of its sidebar on the dev Mac, back to 2024); Kite keeps the newest 30.
    public static let keep = 30

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Backup: Hashable, Sendable {
        public let url: URL
        public let date: Date
    }

    /// What Restore Data lists for a backup; nil counts when it doesn't decode ("Backup cannot be restored").
    public struct Summary: Hashable, Sendable {
        public let backup: Backup
        public let spaceCount: Int?
        public let tabCount: Int?
        public var isRestorable: Bool { spaceCount != nil }
    }

    /// Newest first.
    public func all() -> [Backup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let formatter = Self.formatter()
        return names.compactMap { name -> Backup? in
            guard name.hasPrefix("session."), name.hasSuffix(".json") else { return nil }
            let stamp = name.dropFirst("session.".count).dropLast(".json".count)
            guard let date = formatter.date(from: String(stamp)) else { return nil }
            return Backup(url: directory.appendingPathComponent(name), date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps `data` as a new backup unless the newest is under `minimumInterval` old or already holds
    /// the same bytes, then drops all but the newest `keep`.
    @discardableResult
    public func backUp(_ data: Data, now: Date = Date(), minimumInterval: TimeInterval = interval) throws -> Backup? {
        if let newest = all().first {
            if now.timeIntervalSince(newest.date) < minimumInterval { return nil }
            if (try? Data(contentsOf: newest.url)) == data { return nil }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.\(Self.formatter().string(from: now)).json")
        try data.write(to: url, options: .atomic)
        prune()
        return Backup(url: url, date: now)
    }

    public func prune(keeping count: Int = keep) {
        for backup in all().dropFirst(count) { try? FileManager.default.removeItem(at: backup.url) }
    }

    public func state(of backup: Backup) throws -> BrowserState {
        try SessionStore.decode(Data(contentsOf: backup.url))
    }

    public func newestValid() -> (Backup, BrowserState)? {
        for backup in all() {
            if let state = try? state(of: backup) { return (backup, state) }
        }
        return nil
    }

    /// Spaces, and tabs counting favorites, pinned and today tabs in every space.
    public func summary(of backup: Backup) -> Summary {
        guard let state = try? state(of: backup) else { return Summary(backup: backup, spaceCount: nil, tabCount: nil) }
        let tabs = state.favoritesByProfile.values.reduce(0) { $0 + $1.count } + state.spaces.reduce(0) { $0 + $1.allTabs.count }
        return Summary(backup: backup, spaceCount: state.spaces.count, tabCount: tabs)
    }

    /// Arc's backup stamp, in UTC so names sort the same across time zones and DST.
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        return formatter
    }
}
