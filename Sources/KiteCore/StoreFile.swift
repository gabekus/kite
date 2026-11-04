import Foundation

/// Loading Kite's small JSON stores without losing them. A store that can't read its file starts empty,
/// and its next save would write over what was there; so a file that exists but won't decode is moved
/// aside first, as `SessionStore` does with a corrupt session, and stays on disk for a later build (or
/// a person) to recover.
public enum StoreFile {
    /// Decodes the file at `url`. Nil when there's none yet, or when it couldn't be read or decoded, in
    /// which case it has been moved aside (`setAside`).
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            setAside(url)
            return nil
        }
    }

    /// Moves `url` to `<name>.corrupt-<seconds>.json` beside it, or copies it there when `keepingOriginal`
    /// (a file that decoded with some items dropped). Returns where it went.
    @discardableResult
    public static func setAside(_ url: URL, keepingOriginal: Bool = false, now: Date = Date()) -> URL? {
        let base = url.deletingPathExtension()
        var backup = base.appendingPathExtension("corrupt-\(Int(now.timeIntervalSince1970)).json")
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = base.appendingPathExtension("corrupt-\(Int(now.timeIntervalSince1970))-\(n).json")
        }
        do {
            if keepingOriginal {
                try FileManager.default.copyItem(at: url, to: backup)
            } else {
                try FileManager.default.moveItem(at: url, to: backup)
            }
            NSLog("Kite: \(url.lastPathComponent) couldn't be read in full; kept it as \(backup.lastPathComponent)")
            return backup
        } catch {
            return nil
        }
    }
}

/// One element of a saved list that's dropped, not fatal, when it doesn't decode: an item from a newer
/// build (an enum case this one doesn't know) loses only itself, not the whole file.
public struct Lossy<Value: Decodable>: Decodable {
    public let value: Value?

    public init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
