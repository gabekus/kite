import Foundation

/// The action trace on disk: one JSON object per line, a file per day (`Traces/2026-11-05.jsonl`, named by the
/// local day each record started), owner-only, kept `retentionDays` days.
///
/// `append` only takes a lock and adds the record to a buffer: encoding and writing happen on a background queue,
/// in batches (every `flushInterval`, or sooner once `batchLimit` records wait), so tracing never blocks a tool call
/// or the main thread. A day stops growing at `dailyLimit` bytes, so tracing can stay on.
public final class TraceStore: @unchecked Sendable {
    public static let retentionDays = 90
    public static let dailyLimit = 200_000_000
    public static let flushInterval: TimeInterval = 0.5
    public static let batchLimit = 256

    public let directory: URL
    private let retentionDays: Int
    private let dailyLimit: Int
    private let flushInterval: TimeInterval
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "dev.gabek.Kite.trace", qos: .utility)

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var buffer: [TraceRecord] = []
    private var drainScheduled = false

    // Only touched on `queue`.
    private var handle: FileHandle?
    private var day: String?
    private var size = 0
    private var full = false
    private var lastPrune: String?

    public init(directory: URL, retentionDays: Int = TraceStore.retentionDays, dailyLimit: Int = TraceStore.dailyLimit,
                flushInterval: TimeInterval = TraceStore.flushInterval, calendar: Calendar = .current) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.dailyLimit = dailyLimit
        self.flushInterval = flushInterval
        self.calendar = calendar
    }

    public static func directory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Traces", isDirectory: true)
    }

    deinit { try? handle?.close() }

    /// Queues a record. Never blocks on disk.
    public func append(_ record: TraceRecord) {
        lock.lock()
        buffer.append(record)
        let now = buffer.count >= Self.batchLimit
        let schedule = !drainScheduled
        if schedule || now { drainScheduled = true }
        lock.unlock()
        if now {
            queue.async { [self] in drain() }
        } else if schedule {
            queue.asyncAfter(deadline: .now() + flushInterval) { [self] in drain() }
        }
    }

    /// Writes everything queued and waits for it (tests, quitting, and before reading the trace back).
    public func flush() {
        queue.sync { drain() }
        queue.sync { try? handle?.synchronize() }
    }

    /// Deletes days past the retention period.
    public func prune(now: Date = Date()) {
        queue.async { [self] in removeOldFiles(now: now) }
    }

    /// The day files kept, oldest first.
    public func files() -> [URL] { Self.files(in: directory) }

    public static func files(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Every record that started from `start` on (nil: all kept), oldest first by monotonic time within a launch and
    /// wall time across them. Malformed lines are skipped.
    public static func read(directory: URL, since start: Date? = nil, calendar: Calendar = .current) -> [TraceRecord] {
        let first = start.map { dayName($0, calendar: calendar) }
        var records: [TraceRecord] = []
        for url in files(in: directory) {
            if let first, url.deletingPathExtension().lastPathComponent < first { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let record = TraceRecord.decode(Data(line)) else { continue }
                if let start, record.date < start { continue }
                records.append(record)
            }
        }
        return records.sorted { $0.t == $1.t ? $0.m < $1.m : $0.t < $1.t }
    }

    // MARK: Private (on queue)

    private func drain() {
        lock.lock()
        let records = buffer
        buffer = []
        drainScheduled = false
        lock.unlock()
        guard !records.isEmpty else { return }
        // Grouped by day, so a batch that spans midnight lands in both files.
        var byDay: [(String, Data)] = []
        for record in records {
            guard var line = try? record.encoded() else { continue }
            line.append(0x0A)
            let name = Self.dayName(record.date, calendar: calendar)
            if let last = byDay.indices.last, byDay[last].0 == name { byDay[last].1.append(line) } else { byDay.append((name, line)) }
        }
        for (name, data) in byDay { write(data, day: name) }
    }

    private func write(_ data: Data, day name: String) {
        if name != day { open(name) }
        guard let handle, !full else { return }
        var data = data
        if size + data.count > dailyLimit {
            full = true
            data = Data(#"{"note":"Kite stopped tracing for today: the day's trace reached its size limit."}"#.utf8 + [0x0A])
        }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            NSLog("Kite: couldn't write the action trace: \(error)")
        }
    }

    private func open(_ name: String) {
        try? handle?.close()
        handle = nil
        day = name
        full = false
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: NetworkLogStore.privateFolder)
            try? fm.setAttributes(NetworkLogStore.privateFolder, ofItemAtPath: directory.path)
            let url = directory.appendingPathComponent(name + ".jsonl")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: NetworkLogStore.privateFile)
            }
            let handle = try FileHandle(forWritingTo: url)
            size = Int(try handle.seekToEnd())
            full = size >= dailyLimit
            self.handle = handle
        } catch {
            NSLog("Kite: couldn't open the action trace: \(error)")
        }
        // A new day: drop the ones past retention (once per day this process sees).
        if lastPrune != name {
            lastPrune = name
            removeOldFiles(now: Self.date(ofDay: name, calendar: calendar) ?? Date())
        }
    }

    private func removeOldFiles(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else { return }
        let oldest = Self.dayName(cutoff, calendar: calendar)
        for url in files() where url.deletingPathExtension().lastPathComponent < oldest {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func dayName(_ date: Date, calendar: Calendar) -> String {
        NetworkLogStore.dayName(date, calendar: calendar)
    }

    static func date(ofDay name: String, calendar: Calendar) -> Date? {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
