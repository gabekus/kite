import KiteCore
import SwiftUI

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

/// The dot on a live folder's tab that a refresh added and the user hasn't opened yet: Arc's
/// SidebarItemUnreadBadgeView, a 6pt circle centred in a 24pt slot after the title, in the row's tint.
struct LiveUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.primary)
            .frame(width: 6, height: 6)
            .frame(width: 24, height: 24)
            .opacity(ArcMetrics.Sidebar.tabTextOpacity)
            .accessibilityLabel("Unread")
    }
}

/// Arc shows GitHub's mark on a live folder's pull requests instead of the page's favicon (whose
/// status badge changes): black in light mode, white in dark. Kite uses GitHub's own site icons.
enum LiveFolderIcons {
    static func pullRequest(_ tab: BrowserTab, dark: Bool) -> URL? {
        guard (tab.pinnedURL ?? tab.url).flatMap(LivePullRequest.canonicalURL) != nil else { return nil }
        return URL(string: dark
            ? "https://github.githubassets.com/favicons/favicon-dark.png"
            : "https://github.githubassets.com/favicons/favicon.png")
    }
}

/// The popover by a live folder that a pull request just made (Arc's LiveItemIntroPopover): 250×80,
/// a 20pt icon and the title in 14pt semibold, then the description in 13pt medium at 70%. It has no
/// buttons and closes on a click outside it.
struct LiveFolderIntro: View {
    let source: LiveFolder.Source

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text(source.folderTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(source.introText)
                .font(.system(size: 13, weight: .medium))
                .opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 7, trailing: 10))
        .frame(width: 250, height: 80, alignment: .leading)
    }
}
