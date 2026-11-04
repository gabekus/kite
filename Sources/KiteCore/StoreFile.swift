import Foundation

/// Loading Kite's JSON stores without losing them. A store that can't read its file starts empty, and
/// its next save would write over what was there. So:
/// - a file that exists but won't decode is moved aside to `<name>.corrupt-<stamp>[-n].json` first, as
///   `SessionStore` does with a corrupt session;
/// - when it can't be moved, writes to it are refused for the rest of the run (`checkWritable`), so the
///   only copy stays;
/// - a file that decoded leniently (an enum value from a newer build read as a default, an item that
///   didn't decode dropped: `Decoder.noteLenient`) is copied aside, since the next save writes back the
///   lenient reading. An identical copy already there is reused, so a relaunch doesn't add another.
public enum StoreFile {
    public enum Load<Value> {
        /// No file yet.
        case missing
        /// Decoded; `lenient` items were coerced or dropped, and a copy of the file was kept when above zero.
        case loaded(Value, lenient: Int)
        /// Didn't decode, and now sits at this URL.
        case setAside(URL)
        /// Didn't decode and couldn't be moved: the store must not save over it.
        case unmovable

        public var value: Value? {
            if case let .loaded(value, _) = self { value } else { nil }
        }

        public var maySave: Bool {
            if case .unmovable = self { false } else { true }
        }
    }

    /// `makeDecoder` makes a fresh decoder for this load (its date strategy and so on): the lenient count
    /// goes in its `userInfo`, so a decoder shared with other code is never touched.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, makeDecoder: () -> JSONDecoder = { JSONDecoder() },
                                          now: Date = Date()) -> Load<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let count = LenientCount()
        let decoder = makeDecoder()
        decoder.userInfo[.kiteLenient] = count
        do {
            let value = try decoder.decode(T.self, from: Data(contentsOf: url))
            // Saving writes the lenient reading back: without a copy of the full file, don't save over it.
            if count.value > 0, setAside(url, keepingOriginal: true, now: now) == nil { protect(url) }
            return .loaded(value, lenient: count.value)
        } catch {
            if let backup = setAside(url, now: now) { return .setAside(backup) }
            protect(url)
            return .unmovable
        }
    }

    /// Moves `url` to `<name>.corrupt-<seconds>[-n].json` beside it, or copies it there when
    /// `keepingOriginal` (reusing an identical copy already there). Returns where it went; nil when it
    /// couldn't be moved or copied.
    @discardableResult
    public static func setAside(_ url: URL, keepingOriginal: Bool = false, now: Date = Date()) -> URL? {
        let files = FileManager.default
        let base = url.deletingPathExtension()
        if keepingOriginal, let current = try? Data(contentsOf: url),
           let existing = backups(of: url).first(where: { (try? Data(contentsOf: $0)) == current }) {
            return existing
        }
        let stamp = Int(now.timeIntervalSince1970)
        var backup = base.appendingPathExtension("corrupt-\(stamp).json")
        var n = 1
        while files.fileExists(atPath: backup.path) {
            n += 1
            backup = base.appendingPathExtension("corrupt-\(stamp)-\(n).json")
        }
        do {
            if keepingOriginal {
                try files.copyItem(at: url, to: backup)
            } else {
                try files.moveItem(at: url, to: backup)
            }
            NSLog("Kite: \(url.lastPathComponent) couldn't be read in full; kept it as \(backup.lastPathComponent)")
            return backup
        } catch {
            NSLog("Kite: \(url.lastPathComponent) couldn't be read, or kept aside: \(error)")
            return nil
        }
    }

    /// The copies `setAside` made of `url`.
    public static func backups(of url: URL) -> [URL] {
        let name = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let folder = url.deletingLastPathComponent()
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(name) && $0.pathExtension == "json" }
    }

    /// Throws for a file `load` couldn't move aside: saving would overwrite the only copy. Stores call
    /// it before every write.
    public static func checkWritable(_ url: URL) throws {
        if isProtected(url) { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    public static func isProtected(_ url: URL) -> Bool {
        protectedLock.lock()
        defer { protectedLock.unlock() }
        return protected.contains(url.standardizedFileURL.path)
    }

    private static func protect(_ url: URL) {
        protectedLock.lock()
        protected.insert(url.standardizedFileURL.path)
        protectedLock.unlock()
    }

    private static let protectedLock = NSLock()
    nonisolated(unsafe) private static var protected: Set<String> = []
}

/// One element of a saved list that's dropped, not fatal, when it doesn't decode: an item from a newer
/// build (an enum case this one doesn't know) loses only itself, not the whole file.
public struct Lossy<Value: Decodable>: Decodable {
    public let value: Value?

    public init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            value = nil
            decoder.noteLenient()
        }
    }
}

extension Decoder {
    /// Counts a value this build read leniently (coerced to a default, or dropped), so `StoreFile.load`
    /// keeps a copy of the file before a save writes the lenient reading back.
    public func noteLenient() {
        (userInfo[.kiteLenient] as? LenientCount)?.add()
    }
}

extension CodingUserInfoKey {
    static let kiteLenient = CodingUserInfoKey(rawValue: "kite.lenientCount")!
}

final class LenientCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
