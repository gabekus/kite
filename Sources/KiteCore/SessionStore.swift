import Foundation

/// Reads and writes the session file. Writes are atomic so a crash mid-save
/// can't leave a half-written session behind.
public struct SessionStore: Sendable {
    public static let currentVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct File: Codable {
        var version: Int
        var state: BrowserState
    }

    /// Returns nil when there's no session yet. An unreadable file is moved aside
    /// (not overwritten) before the error is thrown, so a bug never eats someone's tabs.
    public func load() throws -> BrowserState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            return try Self.decoder.decode(File.self, from: data).state
        } catch {
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            throw error
        }
    }

    public func save(_ state: BrowserState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(File(version: Self.currentVersion, state: state))
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        // Default date strategy: an exact Double, so timestamps round-trip losslessly.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
