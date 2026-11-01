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

    public init(id: UUID = UUID(), engineID: Int?, url: String, path: String, state: State,
                receivedBytes: Int64, totalBytes: Int64, speed: Int64 = 0, startedAt: Date = Date()) {
        self.id = id
        self.engineID = engineID
        self.url = url
        self.path = path
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.startedAt = startedAt
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
    public var url: String
    public var path: String
    public var state: DownloadItem.State
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var speed: Int64

    public init(engineID: Int, url: String, path: String, state: DownloadItem.State,
                receivedBytes: Int64, totalBytes: Int64, speed: Int64 = 0) {
        self.engineID = engineID
        self.url = url
        self.path = path
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.speed = speed
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

    /// Restored from disk: nothing is live any more, so a download cut off by quitting reads as interrupted.
    public mutating func markRestored() {
        for index in items.indices {
            items[index].engineID = nil
            items[index].speed = 0
            if items[index].state == .inProgress { items[index].state = .interrupted }
        }
    }

    /// Returns the item, and whether it's new to the list.
    @discardableResult
    public mutating func apply(_ update: DownloadUpdate, now: Date = Date()) -> (item: DownloadItem, isNew: Bool) {
        if let index = items.firstIndex(where: { $0.engineID == update.engineID }) {
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
        let item = DownloadItem(engineID: update.engineID, url: update.url, path: update.path, state: update.state,
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
