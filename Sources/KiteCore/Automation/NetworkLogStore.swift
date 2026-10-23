import Foundation

/// Writes finished network log entries to disk as one JSON object per line, a
/// file per day (`NetworkLog/2026-10-23.ndjson`), readable only by the user.
/// Days older than `retentionDays` are deleted, and a day stops growing at
/// `dailyLimit` bytes, so recording can be left on.
///
/// Writes happen on a background queue; nothing here blocks the main thread.
public final class NetworkLogStore: @unchecked Sendable {
    public static let retentionDays = 7
    public static let dailyLimit = 100_000_000

    public let directory: URL
    private let retentionDays: Int
    private let dailyLimit: Int
    private let queue = DispatchQueue(label: "kite.network-log", qos: .utility)
    private let calendar: Calendar
    // Only touched on `queue`.
    private var handle: FileHandle?
    private var day: String?
    private var size = 0
    private var full = false

    public init(directory: URL, retentionDays: Int = NetworkLogStore.retentionDays, dailyLimit: Int = NetworkLogStore.dailyLimit,
                calendar: Calendar = .current) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.dailyLimit = dailyLimit
        self.calendar = calendar
    }

    /// Owner-only, where the platform has POSIX permissions.
    #if os(Windows)
    static var privateFolder: [FileAttributeKey: Any] { [:] }
    static var privateFile: [FileAttributeKey: Any] { [:] }
    #else
    static var privateFolder: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }
    static var privateFile: [FileAttributeKey: Any] { [.posixPermissions: 0o600] }
    #endif

    public static func directory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("NetworkLog", isDirectory: true)
    }

    deinit { try? handle?.close() }

    public func append(_ entries: [NetworkLog.Entry], now: Date = Date()) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in write(entries, now: now) }
    }

    /// Deletes days past the retention period.
    public func prune(now: Date = Date()) {
        queue.async { [self] in removeOldFiles(now: now) }
    }

    /// Waits for queued writes (for tests and quitting).
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// The files kept, oldest first.
    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".ndjson") }.sorted().map { directory.appendingPathComponent($0) }
    }

    // MARK: Private (on queue)

    private func write(_ entries: [NetworkLog.Entry], now: Date) {
        let today = Self.dayName(now, calendar: calendar)
        if today != day { open(today, now: now) }
        guard let handle, !full else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            guard var line = try? encoder.encode(entry) else { continue }
            line.append(0x0A)
            data.append(line)
        }
        if size + data.count > dailyLimit {
            full = true
            data = Data(#"{"note":"Kite stopped logging for today: the day's log reached its size limit."}"#.utf8 + [0x0A])
        }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            NSLog("Kite: couldn't write the network log: \(error)")
        }
    }

    private func open(_ name: String, now: Date) {
        try? handle?.close()
        handle = nil
        day = name
        full = false
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.privateFolder)
            try? fm.setAttributes(Self.privateFolder, ofItemAtPath: directory.path)
            let url = directory.appendingPathComponent(name + ".ndjson")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: Self.privateFile)
            }
            let handle = try FileHandle(forWritingTo: url)
            size = Int(try handle.seekToEnd())
            full = size >= dailyLimit
            self.handle = handle
        } catch {
            NSLog("Kite: couldn't open the network log: \(error)")
        }
        removeOldFiles(now: now)
    }

    private func removeOldFiles(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else { return }
        let oldest = Self.dayName(cutoff, calendar: calendar)
        for url in files() where url.deletingPathExtension().lastPathComponent < oldest {
            try? FileManager.default.removeItem(at: url)
        }
        // HAR exports go too.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".har") {
            let url = directory.appendingPathComponent(name)
            if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Writes a HAR export next to the logs (pruned with them) and returns its path.
    public func export(_ har: JSONValue, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.privateFolder)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        var url = directory.appendingPathComponent("kite-\(formatter.string(from: now)).har")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("kite-\(formatter.string(from: now))-\(n).har")
            n += 1
        }
        guard fm.createFile(atPath: url.path, contents: try har.encoded(), attributes: Self.privateFile) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static func dayName(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
