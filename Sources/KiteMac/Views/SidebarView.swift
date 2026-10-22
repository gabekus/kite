import AppKit
import KiteCore
import SwiftUI

struct SidebarActions {
    var goBack: () -> Void
    var goForward: () -> Void
    var reload: () -> Void
    var closeTab: (UUID) -> Void
}

/// Arc's sidebar, top to bottom: navigation, address pill, favorites grid,
/// the space's pinned items (with folders), new tab and today's tabs, spaces.
struct SidebarView: View {
    let store: BrowserStore
    let actions: SidebarActions
    /// False on WebKit, which can't force pages dark.
    let supportsDarkPages: Bool

    var body: some View {
        let state = store.state
        let space = state.selectedSpace
        let selectedID = space.selectedTabID
        let page = selectedID.flatMap { store.pages[$0] } ?? PageStatus()
        let selectedTab = state.selectedTab

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                Spacer()
                ToolbarButton(symbol: "chevron.left", help: "Back", enabled: page.canGoBack, action: actions.goBack)
                ToolbarButton(symbol: "chevron.right", help: "Forward", enabled: page.canGoForward, action: actions.goForward)
                ToolbarButton(symbol: page.isLoading ? "xmark" : "arrow.clockwise", help: "Reload", enabled: selectedID != nil, action: actions.reload)
            }
            .frame(height: 28)
            .padding(.top, 6)

            AddressPill(
                text: selectedTab?.url?.host() ?? "Search or enter URL",
                isDark: darkPageState(for: selectedTab),
                action: { store.showCommandBar(selectedTab == nil ? .newTab : .editCurrent) },
                toggleDark: { store.mutate { $0.toggleDarkPage(for: selectedTab?.url) } }
            )

            if !state.favorites.isEmpty {
                FavoritesGrid(
                    favorites: state.favorites,
                    selectedID: selectedID,
                    onSelect: { id in store.mutate { $0.select(tab: id) } },
                    onUnload: actions.closeTab,
                    onRemove: { id in store.mutate { $0.toggleFavorite(tab: id) } }
                )
            }

            List {
                Section(space.name) {
                    ForEach(space.pinnedItems) { item in
                        pinnedItem(item, depth: 0, selectedID: selectedID)
                            .sidebarRow()
                    }
                    .onMove { from, to in
                        store.mutate { $0.moveTabs(inSpace: space.id, pinned: true, fromOffsets: from, toOffset: to) }
                    }
                }
                Section {
                    if !space.pinnedItems.isEmpty {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .sidebarRow()
                    }
                    NewTabRow { store.showCommandBar(.newTab) }
                        .sidebarRow()
                    ForEach(space.tabs) { tab in
                        row(tab, pinned: false, selected: tab.id == selectedID)
                    }
                    .onMove { from, to in
                        store.mutate { $0.moveTabs(inSpace: space.id, pinned: false, fromOffsets: from, toOffset: to) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)

            SpaceBar(store: store)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .foregroundStyle(.primary)
    }

    /// Nil hides the moon: nothing to darken, or the engine can't.
    private func darkPageState(for tab: BrowserTab?) -> Bool? {
        guard supportsDarkPages, let url = tab?.url, url.host() != nil else { return nil }
        return store.state.wantsDarkPage(for: url, systemIsDark: store.systemIsDark)
    }

    /// Folders nest, so this recursion has to erase its type.
    private func pinnedItem(_ item: PinnedItem, depth: Int, selectedID: UUID?) -> AnyView {
        switch item {
        case .tab(let tab):
            return AnyView(row(tab, pinned: true, selected: tab.id == selectedID, depth: depth))
        case .folder(let folder):
            // Like Arc, a collapsed folder still shows its selected tab.
            let visible = folder.isExpanded
                ? folder.items
                : folder.items.tabs.filter { $0.id == selectedID }.map(PinnedItem.tab)
            return AnyView(VStack(spacing: 2) {
                FolderRow(folder: folder, depth: depth) {
                    store.mutate { $0.setFolderExpanded(folder.id, !folder.isExpanded) }
                }
                ForEach(visible) { child in
                    pinnedItem(child, depth: depth + 1, selectedID: selectedID)
                }
            })
        }
    }

    private func row(_ tab: BrowserTab, pinned: Bool, selected: Bool, depth: Int = 0) -> some View {
        TabRow(
            tab: tab,
            isPinned: pinned,
            isSelected: selected,
            depth: depth,
            onSelect: { store.mutate { $0.select(tab: tab.id) } },
            onClose: { actions.closeTab(tab.id) },
            onTogglePin: { store.mutate { $0.togglePin(tab: tab.id) } },
            onFavorite: { store.mutate { $0.toggleFavorite(tab: tab.id) } }
        )
        .sidebarRow()
    }
}

private extension View {
    func sidebarRow() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Translucent white reads well on any theme; the amount depends on the backdrop.
private struct ChromeFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let strength: Double
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(strength * (scheme == .dark ? 0.35 : 1)))
        )
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.85 : 0.3)
        .disabled(!enabled)
        .help(help)
    }
}

private struct AddressPill: View {
    let text: String
    /// Whether the page is shown dark; nil hides the toggle.
    let isDark: Bool?
    let action: () -> Void
    let toggleDark: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let isDark {
                DarkPageToggle(isDark: isDark, action: toggleDark)
                    .padding(.trailing, 4)
            }
        }
        .modifier(ChromeFill(strength: 0.3))
    }
}

/// Flips dark pages for the current site. Filled when the page is dark.
private struct DarkPageToggle: View {
    let isDark: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isDark ? "moon.fill" : "moon")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .modifier(ChromeFill(strength: hovering ? 0.25 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDark || hovering ? 0.9 : 0.5)
        .onHover { hovering = $0 }
        .help(isDark ? "Show This Site Light" : "Show This Site Dark")
        .accessibilityLabel("Dark page")
        .accessibilityValue(isDark ? "On" : "Off")
    }
}

/// Arc's favorites: square tiles of favicons, shared by every space.
private struct FavoritesGrid: View {
    let favorites: [BrowserTab]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onUnload: (UUID) -> Void
    let onRemove: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 46), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(favorites) { tab in
                FavoriteTile(
                    tab: tab,
                    isSelected: tab.id == selectedID,
                    onSelect: { onSelect(tab.id) },
                    onUnload: { onUnload(tab.id) },
                    onRemove: { onRemove(tab.id) }
                )
            }
        }
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onUnload: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        FaviconView(tab: tab, size: 20)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .modifier(ChromeFill(strength: isSelected ? 0.6 : hovering ? 0.32 : 0.2, cornerRadius: 10))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onSelect)
            .help(tab.displayTitle)
            .contextMenu {
                Button("Remove from Favorites", action: onRemove)
                Button("Copy Link") { copyLink(tab.url) }
                Divider()
                Button("Unload Tab", action: onUnload)
            }
            .accessibilityElement()
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
    }
}

private struct FolderRow: View {
    let folder: TabFolder
    let depth: Int
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
                .opacity(0.75)
            Text(folder.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .opacity(hovering ? 0.5 : 0)
        }
        .padding(.leading, 8 + indent(depth))
        .padding(.trailing, 8)
        .frame(height: 30)
        .modifier(ChromeFill(strength: hovering ? 0.18 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button(folder.isExpanded ? "Collapse Folder" : "Expand Folder", action: onToggle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAction { onToggle() }
    }
}

/// Matches the width of a favicon plus its gap, like Arc's folder nesting.
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * 14
}

private func copyLink(_ url: URL?) {
    guard let url else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

private struct NewTabRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 13))
                .opacity(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .modifier(ChromeFill(strength: hovering ? 0.18 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isPinned: Bool
    let isSelected: Bool
    var depth = 0
    let onSelect: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onFavorite: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help(isPinned ? "Unload" : "Close Tab")
            }
        }
        .padding(.leading, 8 + indent(depth))
        .padding(.trailing, 8)
        .frame(height: 30)
        .modifier(ChromeFill(strength: isSelected ? 0.5 : hovering ? 0.18 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Add to Favorites", action: onFavorite)
            Button(isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            Button("Copy Link") { copyLink(tab.url) }
            Divider()
            Button(isPinned ? "Unload Tab" : "Close Tab", action: onClose)
        }
    }
}

private struct SpaceBar: View {
    let store: BrowserStore

    var body: some View {
        let state = store.state
        HStack(spacing: 4) {
            ForEach(state.spaces) { space in
                Button {
                    store.mutate { $0.selectSpace(space.id) }
                } label: {
                    Text(space.icon)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .modifier(ChromeFill(strength: space.id == state.selectedSpaceID ? 0.45 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.name)
            }
            Spacer()
            Button {
                store.addSpace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.7)
            .help("New Space")
        }
    }
}
