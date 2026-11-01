import KiteCore
import SwiftUI

/// The space menu's Live Folders submenu (Arc's "Menu item to manage which live folders are active
/// in this space"): one item per source, checked while the space has that folder.
struct LiveFoldersSpaceMenu: View {
    let store: BrowserStore
    let space: Space

    var body: some View {
        if let controller = LiveFoldersController.shared, let index = store.state.spaceIndex(space.id) {
            Menu("Live Folders") {
                ForEach(LiveFolder.Source.allCases, id: \.self) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { store.state.liveFolder(source, inSpace: index) != nil },
                        set: { _ in controller.toggle(source, inSpace: space.id) }))
                }
            }
        }
    }
}

/// A live folder's right-click menu, with the items Arc's binary lists (order unverified): Refresh, the
/// last fetch, the filters, Repositories, and Delete Live Folder.
struct LiveFolderMenu: View {
    let folder: TabFolder
    let live: LiveFolder
    let onDelete: () -> Void

    var body: some View {
        let controller = LiveFoldersController.shared
        Button("Refresh") { controller?.refresh(folder.id, force: true) }
            .disabled(controller?.isRefreshing(folder.id) ?? true)
        Text(Self.status(live))
        if let error = live.lastError { Text(error) }
        Divider()
        ForEach(LiveFolder.Filter.all, id: \.filter.rawValue) { item in
            Toggle(item.title, isOn: Binding(
                get: { live.filter.contains(item.filter) },
                set: { _ in controller?.toggleFilter(folder.id, item.filter) }))
        }
        Menu("Repositories") {
            ForEach(Self.repositories(live), id: \.self) { repository in
                Toggle(repository, isOn: Binding(
                    get: { !live.hiddenRepositories.contains(repository) },
                    set: { _ in controller?.toggleRepository(folder.id, repository) }))
            }
            Divider()
            Text("This list is generated based on your currently active pull requests.")
        }
        Divider()
        Button("Delete Live Folder", action: onDelete)
    }

    /// Arc's status line: "Initializing...", "Last fetch: …" or "Failed to update".
    static func status(_ live: LiveFolder) -> String {
        guard let last = live.lastFetch else { return "Initializing..." }
        if live.lastError != nil { return "Failed to update" }
        return "Last fetch: \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The repositories the last refresh found, plus ones turned off that it no longer returns.
    static func repositories(_ live: LiveFolder) -> [String] {
        live.repositories + live.hiddenRepositories.filter { !live.repositories.contains($0) }
    }
}

/// The dot on a live folder's tab that a refresh added and the user hasn't opened yet.
struct LiveUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .accessibilityLabel("Unread")
    }
}
