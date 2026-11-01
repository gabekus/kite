import Foundation

/// Arc's archived tabs (StorableArchiveItems.json), as Kite archive entries.
/// Delete with ArcImport.swift once Arc has shut down.
public enum ArcArchiveImport {
    /// Archived tabs from Little Arc, or with no space, have no space to go back to;
    /// restoring one puts it in the current space.
    public static let noSpace = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Oldest archived first, like Kite's own archive. Entries Kite can't read are skipped.
    public static func parse(_ data: Data) -> [ClosedTab] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [Any]
        else { return [] }
        var seen: Set<UUID> = []
        var entries: [(archivedAt: Double, tab: ClosedTab)] = []
        // A flat [id, object, id, object, ...] list, like the rest of Arc's files.
        for case let item as [String: Any] in items {
            guard let sidebarItem = item["sidebarItem"] as? [String: Any],
                  let tab = (sidebarItem["data"] as? [String: Any])?["tab"] as? [String: Any],
                  let url = (tab["savedURL"] as? String).flatMap(URL.init(string:)), url.scheme != nil
            else { continue }
            let id = (sidebarItem["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            guard seen.insert(id).inserted else { continue }
            let archivedAt = item["archivedAt"] as? Double ?? 0
            // Arc's dates are seconds since 2001 (Swift's reference date).
            let lastActive = tab["timeLastActiveAt"] as? Double ?? archivedAt
            let customTitle = (sidebarItem["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let space = ((item["source"] as? [String: Any])?["space"] as? [String: Any])?["_0"] as? String
            entries.append((archivedAt, ClosedTab(
                tab: BrowserTab(
                    id: id,
                    url: url,
                    title: customTitle ?? tab["savedTitle"] as? String ?? "",
                    lastActiveAt: Date(timeIntervalSinceReferenceDate: lastActive)
                ),
                spaceID: space.flatMap(UUID.init(uuidString:)) ?? noSpace,
                index: 0
            )))
        }
        return entries.sorted { $0.archivedAt < $1.archivedAt }.map(\.tab)
    }
}

extension BrowserState {
    /// Puts Arc's archived tabs before Kite's own (they're older), skipping ones
    /// imported before. Past `archiveLimit` the oldest go, as with Kite's own archive.
    /// Returns how many are in the archive now.
    @discardableResult
    public mutating func mergeArchive(imported: [ClosedTab]) -> Int {
        let existing = Set(archived.map(\.tab.id))
        let new = imported.filter { !existing.contains($0.tab.id) }
        archived = new + archived
        if archived.count > Self.archiveLimit {
            archived.removeFirst(archived.count - Self.archiveLimit)
        }
        let added = Set(new.map(\.tab.id))
        return archived.filter { added.contains($0.tab.id) }.count
    }
}
