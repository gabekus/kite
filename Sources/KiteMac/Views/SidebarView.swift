import AppKit
import KiteCore
import SwiftUI

struct SidebarActions {
    var goBack: () -> Void
    var goForward: () -> Void
    var reload: () -> Void
    var toggleSidebar: () -> Void
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

        VStack(alignment: .leading, spacing: 0) {
            // One row with the traffic lights: sidebar toggle after them, navigation at the far end.
            // With View → Show Toolbar, navigation and the URL move to the bar over the page.
            HStack(spacing: M.navButtonSpacing) {
                ToolbarButton(symbol: "sidebar.left", help: "Toggle Sidebar", enabled: true, action: actions.toggleSidebar)
                    .padding(.leading, M.toggleX - M.padding)
                Spacer()
                if !state.showsToolbar {
                    ToolbarButton(symbol: "arrow.left", help: "Back", enabled: page.canGoBack, action: actions.goBack)
                    ToolbarButton(symbol: "arrow.right", help: "Forward", enabled: page.canGoForward, action: actions.goForward)
                    ToolbarButton(symbol: page.isLoading ? "xmark" : "arrow.clockwise", help: "Reload", enabled: selectedID != nil, action: actions.reload)
                }
            }
            .frame(height: M.topRowHeight)
            .padding(.top, M.topRowY)
            .padding(.trailing, M.navTrailing - M.padding)

            if !state.showsToolbar {
                AddressPill(
                    text: selectedTab?.url?.host() ?? "Search or enter URL",
                    isDark: darkPageState(for: selectedTab),
                    action: { store.showCommandBar(selectedTab == nil ? .newTab : .editCurrent) },
                    toggleDark: { store.mutate { $0.toggleDarkPage(for: selectedTab?.url) } }
                )
                .padding(.top, M.urlFieldTopGap)
            }

            if !state.favorites.isEmpty {
                FavoritesGrid(
                    favorites: state.favorites,
                    selectedID: selectedID,
                    onSelect: { id in store.mutate { $0.select(tab: id) } },
                    onUnload: actions.closeTab,
                    onRemove: { id in store.mutate { $0.toggleFavorite(tab: id) } }
                )
                .padding(.top, M.favoritesTopGap)
                .padding(.bottom, M.favoritesBottomGap)
            }

            List {
                Section {
                    // A row rather than a section header: a plain List paints headers with an opaque bar.
                    SpaceHeader(space: space)
                        .sidebarRow(pill: false)
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
                        Rectangle()
                            .fill(.primary.opacity(M.dividerOpacity))
                            .frame(height: M.dividerThickness)
                            .padding(.horizontal, M.dividerInset)
                            .frame(height: M.dividerRowHeight)
                            .sidebarRow(pill: false)
                    }
                    NewTabRow { store.showCommandBar(.newTab) }
                        .sidebarRow()
                    ForEach(space.tabs) { tab in
                        row(tab, pinned: false, selected: tab.id == selectedID)
                            .sidebarRow()
                    }
                    .onMove { from, to in
                        store.mutate { $0.moveTabs(inSpace: space.id, pinned: false, fromOffsets: from, toOffset: to) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)

            SpaceBar(store: store)
                .frame(height: M.bottomBarHeight)
        }
        .padding(.horizontal, M.padding)
        .foregroundStyle(.primary)
        // Arc measures from the window's top edge, under the transparent titlebar.
        .ignoresSafeArea()
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
            return AnyView(VStack(spacing: M.rowPitch - M.pillHeight) {
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
    }
}

private typealias M = ArcMetrics.Sidebar

private extension View {
    /// Pills sit 41pt apart, centred in their row, like Arc's. `pill: false` is for
    /// rows that set their own height (the header, the divider).
    func sidebarRow(pill: Bool = true) -> some View {
        let gap = pill ? (M.rowPitch - M.pillHeight) / 2 : 0
        return modifier(ListEdgeCompensation())
            .listRowInsets(EdgeInsets(top: gap, leading: 0, bottom: gap, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A plain List on macOS keeps 8pt before and 9pt after each row whatever the
/// row insets say; Arc's pills run the sidebar's full padded width.
private struct ListEdgeCompensation: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.leading, -8).padding(.trailing, -9)
    }
}

/// Translucent white reads well on any theme. `strength` is Arc's opacity over
/// a dark tint; light tints need about three times as much to show.
private struct ChromeFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let strength: Double
    var cornerRadius: CGFloat = M.cornerRadius

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(scheme == .dark ? strength : min(strength * 3.5, 0.7)))
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
                .font(.system(size: 15, weight: .regular))
                .frame(width: M.navButtonSize, height: M.navButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.6 : 0.25)
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
                    .font(.system(size: M.urlFieldFontSize))
                    .opacity(M.urlFieldTextOpacity)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, M.urlFieldTextInset)
                    .frame(height: M.urlFieldHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let isDark {
                DarkPageToggle(isDark: isDark, action: toggleDark)
                    .padding(.trailing, 4)
            }
        }
        .modifier(ChromeFill(strength: M.fieldFill))
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
                .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0, cornerRadius: 6))
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: M.favoriteSpacing), count: M.favoriteColumns)

    var body: some View {
        LazyVGrid(columns: columns, spacing: M.favoriteSpacing) {
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
        FaviconView(tab: tab, size: M.favoriteIconSize)
            .frame(maxWidth: .infinity)
            .frame(height: M.favoriteHeight)
            .modifier(ChromeFill(strength: isSelected ? M.fieldFill + M.selectedFill : hovering ? M.fieldFill + M.hoverFill : M.fieldFill))
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
        HStack(spacing: M.iconTextGap) {
            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 14))
                .frame(width: M.iconSize, height: M.iconSize)
                .opacity(0.75)
            Text(folder.name)
                .font(.system(size: M.tabFontSize, weight: .semibold))
                .opacity(M.tabTextOpacity)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .opacity(hovering ? 0.5 : 0)
        }
        .padding(.leading, M.iconInset + indent(depth))
        .padding(.trailing, M.iconInset)
        .frame(height: M.pillHeight)
        .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0))
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

/// A favicon plus its gap per level, like Arc's folder nesting.
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * (M.iconSize + M.iconTextGap)
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
            HStack(spacing: M.iconTextGap) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: M.iconSize, height: M.iconSize)
                Text("New Tab")
                    .font(.system(size: M.tabFontSize))
            }
            .opacity(M.tabTextOpacity * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, M.iconInset)
            .frame(height: M.pillHeight)
            .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0))
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
        HStack(spacing: M.iconTextGap) {
            FaviconView(tab: tab, size: M.iconSize)
            Text(tab.displayTitle)
                .font(.system(size: M.tabFontSize))
                .opacity(M.tabTextOpacity)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help(isPinned ? "Unload" : "Close Tab")
            }
        }
        .padding(.leading, M.iconInset + indent(depth))
        .padding(.trailing, 6)
        .frame(height: M.pillHeight)
        .modifier(ChromeFill(strength: isSelected ? M.selectedFill : hovering ? M.hoverFill : 0))
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
                        .frame(width: M.bottomButtonSize, height: M.bottomButtonSize)
                        .modifier(ChromeFill(strength: space.id == state.selectedSpaceID ? M.selectedFill : 0, cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu { ThemeMenu(store: store, space: space) }
            }
            Spacer()
            Button {
                store.addSpace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: M.bottomButtonSize, height: M.bottomButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.7)
            .help("New Space")
        }
    }
}

/// The space's icon and name above its pinned tabs, Arc's small semibold caption.
private struct SpaceHeader: View {
    let space: Space

    var body: some View {
        HStack(spacing: M.headerTextX - M.headerIconX - M.headerIconSize) {
            Text(space.icon)
                .font(.system(size: 15))
                .frame(width: M.headerIconSize, height: M.headerIconSize)
            Text(space.name)
                .font(.system(size: M.headerFontSize, weight: .semibold))
                .opacity(M.headerTextOpacity)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, M.headerIconX - M.padding)
        .padding(.top, M.headerIconTop)
        .frame(height: M.headerHeight + M.listTopSpacer, alignment: .top)
    }
}

/// Arc's per-space theme picker, reduced to a menu: a palette, and how strongly it tints the sidebar.
private struct ThemeMenu: View {
    let store: BrowserStore
    let space: Space

    var body: some View {
        Menu("Theme Color") {
            ForEach(Array(Theme.presets.enumerated()), id: \.offset) { index, preset in
                Button("Color \(index + 1)") {
                    var theme = preset
                    theme.tint = space.theme.tint
                    store.mutate { $0.setTheme(theme, forSpace: space.id) }
                }
            }
        }
        Menu("Theme Intensity") {
            ForEach([("Subtle", Float(0.35)), ("Arc", Theme.defaultTint), ("Strong", Float(0.8)), ("Solid", Float(1))], id: \.0) { name, tint in
                Button(name) {
                    var theme = space.theme
                    theme.tint = tint
                    store.mutate { $0.setTheme(theme, forSpace: space.id) }
                }
            }
        }
    }
}
