import Foundation

/// Arc's Library › Media page (Window › View Media…), without the AppKit parts: the images and
/// videos in the user's Documents, Desktop and Downloads folders and their screenshots, alongside the
/// browser's own Captures, newest first under date headings. Evidence is in docs/arc-visual-spec.md
/// ("Media page").
public enum MediaLibrary {
    /// Arc's "Show media from:" choices, in the order of its `dataSourcePreferences` enum.
    public enum Source: Int, CaseIterable, Codable, Hashable, Sendable {
        case documents, desktop, screenshots, captures, downloads

        /// Arc's titles; its "Arc Captures" is this browser's Captures.
        public var title: String {
            switch self {
            case .documents: "Documents"
            case .desktop: "Desktop"
            case .screenshots: "Screenshots"
            case .captures: "Kite Captures"
            case .downloads: "Downloads"
            }
        }
    }

    /// Arc's item kinds: "Image", "Video", and a generic thing it doesn't list.
    public enum Kind: String, Codable, Hashable, Sendable {
        case image, video
    }

    /// One picture or video on the page.
    public struct Item: Identifiable, Hashable, Sendable {
        public var file: URL
        public var date: Date
        public var source: Source
        public var kind: Kind
        /// A Capture's page.
        public var sourceURL: URL?
        /// A Capture's id in the capture store.
        public var captureID: UUID?

        public var id: String { file.path }
        public var name: String { file.lastPathComponent }

        public init(file: URL, date: Date, source: Source, kind: Kind, sourceURL: URL? = nil, captureID: UUID? = nil) {
            self.file = file
            self.date = date
            self.source = source
            self.kind = kind
            self.sourceURL = sourceURL
            self.captureID = captureID
        }
    }

    // MARK: Files

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif",
    ]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm"]

    /// Whether a file is a picture or a video, by its extension; nil for anything else.
    public static func kind(of file: URL) -> Kind? {
        let ext = file.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// The folder macOS saves screenshots to: `com.apple.screencapture location`, else the Desktop.
    public static func screenshotsFolder(location: String?, home: URL) -> URL {
        if let location, !location.isEmpty {
            let path = (location as NSString).expandingTildeInPath
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: Filtering and sections

    /// The page's search and its "Show media from:" toggles, every source on to begin with.
    public struct Filter: Equatable, Sendable {
        public var query = ""
        public var sources = Set(Source.allCases)

        public init(query: String = "", sources: Set<Source> = Set(Source.allCases)) {
            self.query = query
            self.sources = sources
        }

        public func matches(_ item: Item) -> Bool {
            guard sources.contains(item.source) else { return false }
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let haystack = item.name + " " + (item.sourceURL?.absoluteString ?? "")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    public struct Section: Hashable, Sendable {
        public var bucket: ArchiveSection.Bucket
        public var items: [Item]

        public func title(locale: Locale = .current, calendar: Calendar = .current) -> String {
            ArchiveSection(bucket: bucket, items: []).title(locale: locale, calendar: calendar)
        }
    }

    /// The items newest first, one per file, filtered, under the Library's headings ("Today",
    /// "Yesterday", "Earlier This Week", then months, as the Archive page does). Hidden files are
    /// left out.
    public static func sections(_ items: [Item], filter: Filter = Filter(), hidden: Set<String> = [],
                                now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        var seen = Set<String>()
        let shown = items.sorted { $0.date > $1.date }.filter { item in
            !hidden.contains(item.file.path) && seen.insert(item.id).inserted && filter.matches(item)
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        func bucket(_ date: Date) -> ArchiveSection.Bucket {
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= week { return .earlierThisWeek }
            return .month(calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date))
        }
        var sections: [Section] = []
        for item in shown {
            let b = bucket(item.date)
            if sections.last?.bucket == b {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(Section(bucket: b, items: [item]))
            }
        }
        return sections
    }
}

/// The browser's Captures, kept so the Media page can show them (Arc's `CaptureClient` with
/// `storeCapture`, `deleteCapture` and StorableCaptures.json). The images live beside the index.
public struct StoredCapture: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The PNG's name in the captures folder.
    public var fileName: String
    public var date: Date
    /// The page it was taken from.
    public var sourceURL: URL?
    public var title: String

    public init(id: UUID = UUID(), fileName: String, date: Date, sourceURL: URL?, title: String) {
        self.id = id
        self.fileName = fileName
        self.date = date
        self.sourceURL = sourceURL
        self.title = title
    }
}

public final class CaptureStore: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var captures: [StoredCapture]
    private var indexURL: URL { folder.appendingPathComponent("captures.json") }

    public init(folder: URL) {
        self.folder = folder
        let data = try? Data(contentsOf: folder.appendingPathComponent("captures.json"))
        captures = data.flatMap { try? JSONDecoder().decode([StoredCapture].self, from: $0) } ?? []
    }

    public var all: [StoredCapture] {
        lock.lock(); defer { lock.unlock() }
        return captures
    }

    public func file(for capture: StoredCapture) -> URL { folder.appendingPathComponent(capture.fileName) }

    /// Saves a capture's PNG and remembers it.
    @discardableResult
    public func store(png: Data, sourceURL: URL?, title: String, date: Date = Date()) throws -> StoredCapture {
        let id = UUID()
        let capture = StoredCapture(id: id, fileName: id.uuidString + ".png", date: date, sourceURL: sourceURL, title: title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file(for: capture), options: .atomic)
        lock.lock()
        captures.append(capture)
        let snapshot = captures
        lock.unlock()
        try save(snapshot)
        return capture
    }

    /// Arc's Delete for a Capture: the image and its entry go.
    public func delete(_ id: UUID) {
        lock.lock()
        let removed = captures.filter { $0.id == id }
        captures.removeAll { $0.id == id }
        let snapshot = captures
        lock.unlock()
        for capture in removed { try? FileManager.default.removeItem(at: file(for: capture)) }
        try? save(snapshot)
    }

    private func save(_ snapshot: [StoredCapture]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: indexURL, options: .atomic)
    }
}
