import Foundation

/// Each tab's back/forward list (the engine's navigation state, with each page's scroll and form
/// contents) in a file of its own, so a tab gets it back after Kite relaunches, as Chrome's session
/// restore does. A file only counts for the URL and profile it was saved with: a tab that moved on
/// without a save (Kite crashed) loads its URL, as it did before there were files.
public final class TabHistoryStore: @unchecked Sendable {
    public let directory: URL
    /// Every read and write goes through it, so a load never sees a half-done save.
    private let queue = DispatchQueue(label: "dev.gabek.Kite.tab-history", qos: .utility)

    private struct Entry: Codable {
        var url: String
        var profile: String?
        var state: Data
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes in the background; `flush` waits for it.
    public func save(_ state: Data, tab: UUID, url: URL, profile: String?) {
        guard let data = try? Self.encoder.encode(Entry(url: url.absoluteString, profile: profile, state: state)) else { return }
        let directory = directory, file = fileURL(tab)
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The state saved for `tab`, if it was saved at `url` in `profile`.
    public func load(tab: UUID, url: URL, profile: String?) -> Data? {
        let file = fileURL(tab)
        return queue.sync {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? Self.decoder.decode(Entry.self, from: data),
                  entry.url == url.absoluteString, entry.profile == profile else { return nil }
            return entry.state
        }
    }

    public func remove(tab: UUID) {
        let file = fileURL(tab)
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Deletes every file but those of `tabs` (all of them for an empty set).
    public func removeAll(except tabs: Set<UUID> = []) {
        let directory = directory
        queue.async {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                if let id = UUID(uuidString: name), tabs.contains(id) { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Waits for saves and removals already asked for (quitting).
    public func flush() {
        queue.sync {}
    }

    private func fileURL(_ tab: UUID) -> URL {
        directory.appendingPathComponent(tab.uuidString)
    }

    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    private static let decoder = PropertyListDecoder()
}
