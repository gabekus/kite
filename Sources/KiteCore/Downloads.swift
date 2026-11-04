import Foundation

/// One download in the downloads list, kept across launches (downloads.json in the profile).
public struct DownloadItem: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case inProgress, complete, canceled, interrupted
    }

    /// Unique for the life of the list: the engine's own id restarts at 1 every launch.
    public var id: UUID
    /// The engine's id while this launch's download is live; nil once restored from disk.
    public var engineID: Int?
    /// Which engine profile (browser context) `engineID` belongs to: Chromium numbers each
    /// profile's and incognito window's downloads from 1. Nil once restored from disk.
    public var engineContext: String?
    /// Started in an incognito window: listed for this launch only, never written to disk or tidied.
    public var isIncognito: Bool
    public var url: String
    /// Where the file is (or will be) on disk. Empty until the engine picks a path.
    public var path: String
    public var state: State
    public var receivedBytes: Int64
    /// -1 while the size isn't known.
    public var totalBytes: Int64
    /// Bytes per second, live downloads only.
    public var speed: Int64
    public var startedAt: Date

    public init(id: UUID = UUID(), engineID: Int?, engineContext: String? = nil, isIncognito: Bool = false,
                url: String, path: String, state: State,
                receivedBytes: Int64, totalBytes: Int64, speed: Int64 = 0, startedAt: Date = Date()) {
        self.id = id
        self.engineID = engineID
        self.engineContext = engineContext
        self.isIncognito = isIncognito
        self.url = url
        self.path = path
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, engineID, engineContext, isIncognito, url, path, state, receivedBytes, totalBytes, speed, startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        engineID = try container.decodeIfPresent(Int.self, forKey: .engineID)
        engineContext = try container.decodeIfPresent(String.self, forKey: .engineContext)
        isIncognito = try container.decodeIfPresent(Bool.self, forKey: .isIncognito) ?? false
        url = try container.decode(String.self, forKey: .url)
        path = try container.decode(String.self, forKey: .path)
        state = try container.decode(State.self, forKey: .state)
        receivedBytes = try container.decode(Int64.self, forKey: .receivedBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        speed = try container.decodeIfPresent(Int64.self, forKey: .speed) ?? 0
        startedAt = try container.decode(Date.self, forKey: .startedAt)
    }

    public var fileName: String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return URL(string: url)?.lastPathComponent ?? url
    }

    /// 0...1, or nil while the size isn't known.
    public var fraction: Double? {
        guard totalBytes > 0 else { return state == .complete ? 1 : nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    /// The site it came from, for Arc's "from example.com".
    public var sourceHost: String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What an engine reports as a download moves along.
public struct DownloadUpdate: Equatable, Sendable {
    public var engineID: Int
    /// The browser context the id is unique within (KCDownloadDidUpdateNotification's "context").
    public var engineContext: String
    public var isIncognito: Bool
    /// The profile folder, for a non-default profile's download.
    public var profileDirectory: String?
    public var url: String
    public var path: String
    public var state: DownloadItem.State
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var speed: Int64

    public init(engineID: Int, engineContext: String = "", isIncognito: Bool = false, profileDirectory: String? = nil,
                url: String, path: String, state: DownloadItem.State, receivedBytes: Int64, totalBytes: Int64,
                speed: Int64 = 0) {
        self.engineID = engineID
        self.engineContext = engineContext
        self.isIncognito = isIncognito
        self.profileDirectory = profileDirectory
        self.url = url
        self.path = path
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.speed = speed
    }

    /// KCDownloadDidUpdateNotification's userInfo; nil without an id.
    public init?(notificationInfo info: [AnyHashable: Any]) {
        guard let id = (info["id"] as? NSNumber)?.intValue else { return nil }
        self.init(engineID: id,
                  engineContext: info["context"] as? String ?? "",
                  isIncognito: (info["incognito"] as? NSNumber)?.boolValue ?? false,
                  profileDirectory: info["profileDirectory"] as? String,
                  url: info["url"] as? String ?? "",
                  path: info["path"] as? String ?? "",
                  state: Self.state(named: info["state"] as? String ?? ""),
                  receivedBytes: (info["receivedBytes"] as? NSNumber)?.int64Value ?? 0,
                  totalBytes: (info["totalBytes"] as? NSNumber)?.int64Value ?? -1,
                  speed: (info["speed"] as? NSNumber)?.int64Value ?? 0)
    }

    /// Chromium's names (KCDownloadDidUpdateNotification's "state").
    public static func state(named name: String) -> DownloadItem.State {
        switch name {
        case "complete": .complete
        case "canceled": .canceled
        case "interrupted": .interrupted
        default: .inProgress
        }
    }

    public static func name(of state: DownloadItem.State) -> String {
        switch state {
        case .complete: "complete"
        case .canceled: "canceled"
        case .interrupted: "interrupted"
        case .inProgress: "in-progress"
        }
    }
}

/// Recent downloads, newest first.
public struct DownloadList: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Older finished downloads fall off the end.
    public static let limit = 100

    public private(set) var items: [DownloadItem] = []

    public init(items: [DownloadItem] = []) {
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case items }

    /// One item Kite can't read is dropped, not the whole list.
    private struct LossyItem: Decodable {
        let item: DownloadItem?
        init(from decoder: Decoder) throws { item = try? DownloadItem(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([LossyItem].self, forKey: .items) ?? []).compactMap(\.item)
    }

    /// Ends an incognito session (its window closed): its downloads leave the list, as Chrome
    /// drops them with the incognito profile.
    public mutating func removeIncognito(context: String) {
        items.removeAll { $0.isIncognito && $0.engineContext == context }
    }

    /// Incognito downloads stay in memory, as Chrome keeps them: the file never lists them.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items.filter { !$0.isIncognito }, forKey: .items)
    }

    /// The live download an engine reports under `engineID` in `context`.
    public func item(engineID: Int, context: String) -> DownloadItem? {
        items.first { $0.engineID == engineID && $0.engineContext == context }
    }

    /// Restored from disk: nothing is live any more, so a download cut off by quitting reads as interrupted.
    public mutating func markRestored() {
        for index in items.indices {
            items[index].engineID = nil
            items[index].engineContext = nil
            items[index].speed = 0
            if items[index].state == .inProgress { items[index].state = .interrupted }
        }
    }

    /// Returns the item, and whether it's new to the list.
    @discardableResult
    public mutating func apply(_ update: DownloadUpdate, now: Date = Date()) -> (item: DownloadItem, isNew: Bool) {
        if let index = items.firstIndex(where: { $0.engineID == update.engineID && $0.engineContext == update.engineContext }) {
            var item = items[index]
            item.url = update.url.isEmpty ? item.url : update.url
            item.path = update.path.isEmpty ? item.path : update.path
            item.state = update.state
            item.receivedBytes = update.receivedBytes
            item.totalBytes = update.totalBytes
            item.speed = update.state == .inProgress ? update.speed : 0
            items[index] = item
            return (item, false)
        }
        let item = DownloadItem(engineID: update.engineID, engineContext: update.engineContext,
                                isIncognito: update.isIncognito, url: update.url, path: update.path, state: update.state,
                                receivedBytes: update.receivedBytes, totalBytes: update.totalBytes,
                                speed: update.state == .inProgress ? update.speed : 0, startedAt: now)
        items.insert(item, at: 0)
        trim()
        return (item, true)
    }

    /// The file was renamed or moved on disk. False when the item isn't listed.
    @discardableResult
    public mutating func setPath(_ path: String, for id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].path = path
        return true
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Drops every finished download; live ones stay.
    public mutating func clearFinished() {
        items.removeAll { $0.state != .inProgress }
    }

    public var active: [DownloadItem] { items.filter { $0.state == .inProgress } }

    /// Progress across every live download (bytes over bytes), nil when none has a known size.
    public var activeFraction: Double? {
        let sized = active.filter { $0.totalBytes > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = sized.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
        return Double(received) / Double(total)
    }

    private mutating func trim() {
        while items.count > Self.limit, let last = items.lastIndex(where: { $0.state != .inProgress }) {
            items.remove(at: last)
        }
    }
}

/// downloads.json: the list with its version.
public struct DownloadsFile: Codable, Sendable {
    public var version: Int
    public var downloads: DownloadList

    public init(downloads: DownloadList) {
        version = DownloadList.currentVersion
        self.downloads = downloads
    }

    public struct Loaded: Sendable {
        public var list: DownloadList
        /// Where an unreadable file was moved.
        public var movedAside: URL?
        /// Where the original was copied when some of its items couldn't be read (a newer
        /// Kite's, say): the next save leaves them out.
        public var copiedAside: URL?
        /// How many items couldn't be read.
        public var dropped = 0
        /// False when unreadable items couldn't be copied aside: saving would lose them.
        public var canSave = true
    }

    /// The list in `fileURL`, restored (nothing live). A file that's there but can't be read is
    /// moved aside first, so the next save doesn't replace the user's history with an empty list;
    /// one with items that can't be read is copied aside and the rest load. Nil when an unreadable
    /// file couldn't be moved aside: then nothing should be saved over it.
    public static func load(_ fileURL: URL, fileManager: FileManager = .default) -> Loaded? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return Loaded(list: DownloadList()) }
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(Self.self, from: data) {
            var loaded = Loaded(list: file.downloads)
            loaded.list.markRestored()
            loaded.dropped = max(0, storedItemCount(data) - file.downloads.items.count)
            if loaded.dropped > 0 {
                let aside = asideURL(for: fileURL)
                if (try? fileManager.copyItem(at: fileURL, to: aside)) != nil { loaded.copiedAside = aside } else { loaded.canSave = false }
            }
            return loaded
        }
        let aside = asideURL(for: fileURL)
        guard (try? fileManager.moveItem(at: fileURL, to: aside)) != nil else { return nil }
        return Loaded(list: DownloadList(), movedAside: aside)
    }

    /// Next to the file, named as SessionStore and HistoryStore name theirs ("corrupt-<stamp>"),
    /// with milliseconds and a few random characters so two in one second can't collide.
    static func asideURL(for fileURL: URL) -> URL {
        let stamp = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        return fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
    }

    /// The items the file holds, readable or not.
    private static func storedItemCount(_ data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloads = object["downloads"] as? [String: Any],
              let items = downloads["items"] as? [Any] else { return 0 }
        return items.count
    }
}

/// The text under a download's name. Arc's copy ("Subtitle copy for a … download", "Format string for
/// download speed in seconds (e.g. 3 MB/s)", "Download from [source domain]") names these cases;
/// the exact wording is Kite's.
public enum DownloadText {
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    public static func subtitle(_ item: DownloadItem) -> String {
        switch item.state {
        case .inProgress:
            var parts: [String] = []
            parts.append(item.totalBytes > 0
                ? "\(size(item.receivedBytes)) of \(size(item.totalBytes))"
                : size(item.receivedBytes))
            if item.speed > 0 { parts.append("\(size(item.speed))/s") }
            return parts.joined(separator: " · ")
        case .complete:
            var text = kind(of: item.fileName)
            if item.totalBytes > 0 || item.receivedBytes > 0 {
                text += " · " + size(item.totalBytes > 0 ? item.totalBytes : item.receivedBytes)
            }
            if let host = item.sourceHost { text += " from \(host)" }
            return text
        case .canceled:
            return "Canceled"
        case .interrupted:
            return "Failed to Download"
        }
    }

    /// Arc's sidebar download cell names a file's type ("Sidebar download cell file type copy for
    /// a PDF / disk image / movie / video / image / audio / archive / zip").
    public static func kind(of fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": "PDF"
        case "dmg", "iso", "img": "Disk Image"
        case "mov": "Movie"
        case "mp4", "m4v", "webm", "mkv", "avi": "Video"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp": "Image"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff": "Audio"
        case "zip": "ZIP Archive"
        case "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": "Archive"
        default: "File"
        }
    }
}
