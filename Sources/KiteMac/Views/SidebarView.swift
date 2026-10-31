import AppKit
import KiteCore
import SwiftUI

struct SidebarActions {
    var goBack: () -> Void
    var goForward: () -> Void
    var reload: () -> Void
    var toggleSidebar: () -> Void
    var closeTab: (UUID) -> Void
    var addSplitView: () -> Void
}

/// Arc's sidebar, top to bottom: navigation, address pill, favorites grid,
/// the space's pinned items (with folders), new tab and today's tabs, spaces.
struct SidebarView: View {
    let store: BrowserStore
    let actions: SidebarActions
    /// False on WebKit, which can't force pages dark.
    let supportsDarkPages: Bool
    /// Opens the extensions popover from the address field's hover button; nil where
    /// extensions don't run (incognito, WebKit).
    var showExtensions: ((NSView) -> Void)?
    /// Always shown at the address field's right end (1Password's key); hides itself when
    /// there's nothing to show.
    var fieldAccessory: AnyView?

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
                    toggleDark: { store.mutate { $0.toggleDarkPage(for: selectedTab?.url) } },
                    showExtensions: showExtensions,
                    accessory: fieldAccessory
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
                    let pinnedGroups = SidebarGroup.group(space.pinnedItems.map(\.id), splits: space.splits)
                    ForEach(pinnedGroups) { group in
                        pinnedGroup(group, in: space.pinnedItems, depth: 0, selectedID: selectedID)
                            .sidebarRow()
                    }
                    .onMove { from, to in
                        let (items, target) = SidebarGroup.itemMove(pinnedGroups, from: from, to: to, itemCount: space.pinnedItems.count)
                        store.mutate { $0.moveTabs(inSpace: space.id, pinned: true, fromOffsets: items, toOffset: target) }
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
                    let unpinnedGroups = SidebarGroup.group(space.tabs.map(\.id), splits: space.splits)
                    ForEach(unpinnedGroups) { group in
                        unpinnedGroup(group, in: space.tabs, selectedID: selectedID)
                            .sidebarRow()
                    }
                    .onMove { from, to in
                        let (items, target) = SidebarGroup.itemMove(unpinnedGroups, from: from, to: to, itemCount: space.tabs.count)
                        store.mutate { $0.moveTabs(inSpace: space.id, pinned: false, fromOffsets: items, toOffset: target) }
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
                ForEach(SidebarGroup.group(visible.map(\.id), splits: store.state.selectedSpace.splits)) { group in
                    pinnedGroup(group, in: visible, depth: depth + 1, selectedID: selectedID)
                }
            })
        }
    }

    @ViewBuilder
    private func unpinnedGroup(_ group: SidebarGroup, in tabs: [BrowserTab], selectedID: UUID?) -> some View {
        if let split = group.split {
            splitRow(split, tabs: group.indices.map { tabs[$0] }, pinned: false, selectedID: selectedID)
        } else {
            let tab = tabs[group.indices[0]]
            row(tab, pinned: false, selected: tab.id == selectedID)
        }
    }

    private func pinnedGroup(_ group: SidebarGroup, in items: [PinnedItem], depth: Int, selectedID: UUID?) -> AnyView {
        guard let split = group.split else {
            return pinnedItem(items[group.indices[0]], depth: depth, selectedID: selectedID)
        }
        let tabs = group.indices.compactMap { index -> BrowserTab? in
            if case .tab(let tab) = items[index] { return tab }
            return nil
        }
        return AnyView(splitRow(split, tabs: tabs, pinned: true, selectedID: selectedID, depth: depth))
    }

    private func splitRow(_ split: SplitView, tabs: [BrowserTab], pinned: Bool, selectedID: UUID?, depth: Int = 0) -> some View {
        SplitRow(
            tabs: tabs,
            isPinned: pinned,
            focusedID: tabs.contains { $0.id == selectedID } ? selectedID : nil,
            depth: depth,
            onSelect: { id in
                store.mutate { state in
                    if let target = id ?? state.focusTarget(of: split) { state.select(tab: target) }
                }
            },
            onClose: actions.closeTab,
            onSeparate: { id in store.mutate { $0.separateFromSplit(tab: id) } },
            onTogglePin: { store.mutate { $0.togglePin(tab: split.tabIDs[0]) } }
        )
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
    var showExtensions: ((NSView) -> Void)?
    var accessory: AnyView?
    @State private var hovering = false

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
            // Arc 1.169 reveals its Site Control Center button (30×30, with the extensions)
            // at the field's right end while the pointer is over the field.
            // Arc's buttons there are 30pt wide on a 28pt pitch.
            HStack(spacing: -2) {
                if let accessory { accessory }
                if let showExtensions, hovering {
                    ExtensionsFieldButton(action: showExtensions)
                }
            }
            if let isDark {
                DarkPageToggle(isDark: isDark, action: toggleDark)
                    .padding(.trailing, 4)
            }
        }
        .modifier(ChromeFill(strength: M.fieldFill))
        .onHover { hovering = $0 }
    }
}

/// The address field's extensions button: opens the extensions popover under it.
private struct ExtensionsFieldButton: View {
    let action: (NSView) -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    static let size: CGFloat = 30

    var body: some View {
        Button { if let anchor { action(anchor) } } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
                .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0, cornerRadius: 6))
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 0.9 : 0.6)
        .onHover { hovering = $0 }
        .help("Extensions")
        .accessibilityLabel("Extensions")
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

/// A split view's sidebar row: its panes side by side, 4pt apart and equally wide, each a
/// favicon and title (only the favicon when it gets 60pt or narrower), like Arc's.
private struct SplitRow: View {
    private typealias S = ArcMetrics.Split

    let tabs: [BrowserTab]
    let isPinned: Bool
    /// The focused pane, when this split is the one on screen.
    let focusedID: UUID?
    var depth = 0
    /// A pane's tab, or nil for the row as a whole.
    let onSelect: (UUID?) -> Void
    let onClose: (UUID) -> Void
    let onSeparate: (UUID) -> Void
    let onTogglePin: () -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(tabs.count, 1))
            let width = (geometry.size.width - S.rowItemSpacing * (count - 1)) / count
            HStack(spacing: S.rowItemSpacing) {
                ForEach(tabs) { tab in
                    item(tab, width: width)
                }
            }
        }
        .padding(.leading, indent(depth))
        .frame(height: M.pillHeight)
        .modifier(ChromeFill(strength: focusedID != nil ? M.selectedFill : hovering ? M.hoverFill : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
    }

    private func item(_ tab: BrowserTab, width: CGFloat) -> some View {
        let compact = width <= S.rowCompactWidth
        return HStack(spacing: M.iconTextGap) {
            FaviconView(tab: tab, size: M.iconSize)
            if !compact {
                Text(tab.displayTitle)
                    .font(.system(size: M.tabFontSize))
                    .opacity(M.tabTextOpacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compact ? 0 : M.iconInset)
        .frame(width: width, height: M.pillHeight)
        .background(
            // Unverified: Arc's focused pane gets the item's fill; the row carries the selection.
            RoundedRectangle(cornerRadius: min(width / 2, S.rowItemMaxCornerRadius), style: .continuous)
                .fill(Color.white.opacity(tab.id == focusedID ? M.hoverFill : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tab.id) }
        .help(tab.displayTitle)
        .contextMenu {
            Button("Separate Page from Split View") { onSeparate(tab.id) }
            Button(isPinned ? "Unpin Split View" : "Pin Split View", action: onTogglePin)
            Button("Copy Link") { copyLink(tab.url) }
            Divider()
            Button("Close this Split Pane") { onClose(tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.id == focusedID ? [.isButton, .isSelected] : .isButton)
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
