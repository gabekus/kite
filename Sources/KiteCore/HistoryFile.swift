import Foundation

/// Reads and writes history.json (and each other profile's Kite History.json). A plain value, so
/// HistoryStore can encode and write a snapshot off the main thread.
public struct HistoryFile: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct File: Codable {
        var version: Int
        var history: History
    }

    /// nil when there's no file yet. An unreadable file is moved aside for a bug report rather
    /// than overwritten, and the error is thrown.
    public func load() throws -> History? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(File.self, from: data).history
        } catch {
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            throw error
        }
    }

    public func save(_ history: History) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(File(version: History.currentVersion, history: history))
        try data.write(to: fileURL, options: .atomic)
    }
}
