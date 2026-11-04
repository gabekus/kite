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

    /// What `loadRecovering` found: the session, and the backup it came from when session.json was unusable.
    public struct Loaded: Sendable {
        public let state: BrowserState
        public let recoveredFrom: SessionBackups.Backup?
    }

    public enum RestoreError: Error, CustomStringConvertible {
        /// session.json can't be read and can't be moved aside, so writing the backup would destroy it.
        case sessionStuck(underlying: any Error)

        public var description: String {
            switch self {
            case .sessionStuck(let error): "session.json can't be read or moved aside (\(error)), so restoring would overwrite it"
            }
        }
    }

    /// Returns nil when there's no session yet. A file that can't be read or decoded is moved aside
    /// (not overwritten), and the newest backup that decodes takes its place; with none, the error is
    /// thrown. If the file couldn't be moved aside it's still there when this throws, and the caller
    /// mustn't save over it.
    public func load() throws -> BrowserState? { try loadRecovering()?.state }

    public func loadRecovering() throws -> Loaded? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return Loaded(state: try Self.decode(Data(contentsOf: fileURL)), recoveredFrom: nil)
        } catch {
            guard (try? Self.moveAside(fileURL)) != nil else { throw error }
            if let (backup, state) = backups.newestValid() { return Loaded(state: state, recoveredFrom: backup) }
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

    /// Puts `backup`'s sidebar back over `current`'s settings (Arc's RestoreSidebarDataFlow restores
    /// the sidebar store only). `current` is kept as a backup first, so a restore can always be
    /// undone by restoring that one, and the restore fails if it couldn't be kept. A session.json
    /// that can't be read is moved aside first, and if it can't be, nothing is written. Throws,
    /// changing nothing, if `backup` doesn't decode.
    public func restore(_ backup: SessionBackups.Backup, current: BrowserState, now: Date = Date()) throws -> BrowserState {
        let restored = current.restoringSidebar(from: try backups.state(of: backup))
        if FileManager.default.fileExists(atPath: fileURL.path), (try? Self.decode(Data(contentsOf: fileURL))) == nil {
            do { try Self.moveAside(fileURL) } catch { throw RestoreError.sessionStuck(underlying: error) }
        }
        try backups.backUp(Self.encode(current), kind: .restore, now: now)
        try save(restored)
        return restored
    }

    /// Renames an unusable file to `name.corrupt-<seconds>.json` beside it, keeping its bytes.
    @discardableResult
    public static func moveAside(_ url: URL) throws -> URL {
        let stamp = "corrupt-\(Int(Date().timeIntervalSince1970))"
        // A second bad file in the same second gets its own name: moving onto the first would fail.
        let aside = (0...).lazy
            .map { url.deletingPathExtension().appendingPathExtension($0 == 0 ? "\(stamp).json" : "\(stamp)-\($0).json") }
            .first { !FileManager.default.fileExists(atPath: $0.path) }!
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
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

extension BrowserState {
    /// `backup`'s sidebar (spaces with their tabs and folders, favorites, archive, recently closed,
    /// selection) over this state's settings: search, site searches, blocking, appearance and
    /// profile settings stay as they are now.
    public func restoringSidebar(from backup: BrowserState) -> BrowserState {
        var result = self
        result.spaces = backup.spaces
        result.favoritesByProfile = backup.favoritesByProfile
        result.favoriteSplitsByProfile = backup.favoriteSplitsByProfile
        result.recentlyClosed = backup.recentlyClosed
        result.archived = backup.archived
        result.selectedSpaceID = backup.selectedSpaceID
        result.spacesWithCollapsedPinnedSections = backup.spacesWithCollapsedPinnedSections
        // A space on a profile deleted since brings the profile back, and its folder is no longer removed.
        let known = Set(result.profiles.map(\.directory))
        let used = Set(backup.spaces.compactMap(\.profile))
        for profile in backup.profiles where used.contains(profile.directory) && !known.contains(profile.directory) {
            result.profiles.append(profile)
            result.retiredProfileDirectories.removeAll { $0 == profile.directory }
        }
        result.dropUnnamedEmptySpaces()
        return result
    }

    /// A Create a Space page left open at quit leaves a nameless, empty space behind.
    public mutating func dropUnnamedEmptySpaces() {
        for space in spaces where space.name.isEmpty && space.allTabs.isEmpty { deleteSpace(space.id) }
    }
}

/// Rolling copies of session.json in the profile's Backups folder, named like Arc's storable
/// backups (`StorableSidebar.2026-11-01-21-05-17-932.json`): `session.yyyy-MM-dd-HH-mm-ss-SSS.json`
/// for the hourly ones, with `.launch` or `.restore` before `.json` for the others. Each is a
/// whole session file, so one can also be put back by hand.
///
/// Each kind has its own budget, so a busy day of hourly copies never pushes out the launch ones:
/// - launch: the session as found at each launch, as Arc backs up every store once per launch. The newest 30.
/// - hourly: at most one an hour while Kite runs. All from the last 48 hours, then the newest of each day for 30 days.
/// - restore: the state Restore Data replaced. The newest 10, and never the one just made.
///
/// Thread-safe; the newest hourly date is kept in memory, so a save inside the interval costs nothing.
public final class SessionBackups: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable { case launch, hourly, restore }

    public static let interval: TimeInterval = 60 * 60
    public static let launchesKept = 30
    public static let hourlyKeptFor: TimeInterval = 48 * 60 * 60
    public static let dailyKeptFor: TimeInterval = 30 * 24 * 60 * 60
    public static let restoresKept = 10
    /// Backups stamped after now (the clock went back, or a copied folder) are ordered as the oldest
    /// of their kind, so they never stay newest; this many of each kind are kept.
    public static let futureKept = 5

    public let directory: URL
    private let lock = NSLock()
    /// The newest hourly backup's date once read: `.some(nil)` means none.
    private var newestHourly: Date??

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Backup: Hashable, Sendable {
        public let url: URL
        public let date: Date
        public let kind: Kind
    }

    /// What Restore Data lists for a backup; nil counts when it doesn't decode ("Backup cannot be restored").
    public struct Summary: Hashable, Sendable {
        public let backup: Backup
        public let spaceCount: Int?
        public let tabCount: Int?
        public var isRestorable: Bool { spaceCount != nil }
    }

    /// By date, newest first.
    public func all() -> [Backup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Backup? in
            guard name.hasPrefix("session."), name.hasSuffix(".json") else { return nil }
            let parts = name.dropFirst("session.".count).dropLast(".json".count).split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let date = Self.date(from: String(parts[0])) else { return nil }
            guard let kind = parts.count == 1 ? .hourly : Kind(rawValue: String(parts[1])), parts.count == 1 || kind != .hourly else { return nil }
            return Backup(url: directory.appendingPathComponent(name), date: date, kind: kind)
        }
        .sorted { $0.date > $1.date }
    }

    /// Newest first, with any stamped after `now` last.
    public func ordered(now: Date = Date()) -> [Backup] {
        let all = all()
        return all.filter { $0.date <= now } + all.filter { $0.date > now }
    }

    /// Keeps `data` as a new backup of `kind` unless it holds the same bytes as the newest backup,
    /// or, for an hourly one, the newest hourly backup is under `interval` old. Then prunes.
    @discardableResult
    public func backUp(_ data: Data, kind: Kind = .hourly, now: Date = Date()) throws -> Backup? {
        lock.lock()
        defer { lock.unlock() }
        if kind == .hourly {
            if newestHourly == nil { newestHourly = .some(all().first { $0.kind == .hourly && $0.date <= now }?.date) }
            if let last = newestHourly ?? nil, last <= now, now.timeIntervalSince(last) < Self.interval { return nil }
        }
        if let newest = ordered(now: now).first, (try? Data(contentsOf: newest.url)) == data { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = kind == .hourly ? "" : ".\(kind.rawValue)"
        let url = directory.appendingPathComponent("session.\(Self.stamp(now))\(suffix).json")
        try data.write(to: url, options: .atomic)
        if kind == .hourly { newestHourly = .some(now) }
        let backup = Backup(url: url, date: now, kind: kind)
        prune(now: now, protecting: backup)
        return backup
    }

    /// Drops what each kind's budget doesn't keep. `protecting` is never dropped.
    public func prune(now: Date = Date(), protecting: Backup? = nil) {
        let all = all()
        var keep = Set<URL>()
        if let protecting { keep.insert(protecting.url) }
        for kind in Kind.allCases {
            let ofKind = all.filter { $0.kind == kind }
            keep.formUnion(ofKind.filter { $0.date > now }.prefix(Self.futureKept).map(\.url))
            let past = ofKind.filter { $0.date <= now }
            switch kind {
            case .launch: keep.formUnion(past.prefix(Self.launchesKept).map(\.url))
            case .restore: keep.formUnion(past.prefix(Self.restoresKept).map(\.url))
            case .hourly:
                var days = Set<String>()
                for backup in past {
                    let age = now.timeIntervalSince(backup.date)
                    if age <= Self.hourlyKeptFor {
                        keep.insert(backup.url)
                    } else if age <= Self.dailyKeptFor, days.insert(String(Self.stamp(backup.date).prefix(10))).inserted {
                        // Newest first, so the first of each day is its newest.
                        keep.insert(backup.url)
                    }
                }
            }
        }
        for backup in all where !keep.contains(backup.url) { try? FileManager.default.removeItem(at: backup.url) }
    }

    public func state(of backup: Backup) throws -> BrowserState {
        try SessionStore.decode(Data(contentsOf: backup.url))
    }

    public func newestValid(now: Date = Date()) -> (Backup, BrowserState)? {
        for backup in ordered(now: now) {
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

    /// Arc's backup stamp, in UTC so names sort the same across time zones and DST. DateFormatter
    /// is thread-safe; it's only shared, never changed.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        return formatter
    }()

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }
    static func date(from stamp: String) -> Date? { formatter.date(from: stamp) }
}
