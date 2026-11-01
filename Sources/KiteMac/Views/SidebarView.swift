import AppKit
import KiteCore
import SwiftUI

struct SidebarActions {
    var goBack: () -> Void
    var goForward: () -> Void
    var reload: () -> Void
    var forceReload: () -> Void
    /// The reload button: on a Developer Mode site it does what `devModeReloadState` says.
    var reloadButton: () -> Void
    /// Developer Mode's reload options: remembers the choice for the button, then does it.
    var developerReload: (DeveloperTabReloadSetting) -> Void
    var clearCookiesAndRefresh: () -> Void
    var toggleSidebar: () -> Void
    var closeTab: (UUID) -> Void
    var addSplitView: () -> Void
    /// A space's context menu in the strip.
    var editTheme: (UUID) -> Void
    var changeSpaceIcon: (UUID) -> Void
    var deleteSpace: (UUID) -> Void
    /// A folder's context menu.
    var renameFolder: (UUID) -> Void
    var deleteFolder: (UUID) -> Void
    /// A pinned tab that left its pinned page: "Back to Pinned URL" and "Separate From Pinned Tab".
    var resetTab: (UUID) -> Void = { _ in }
    var separateFromPinnedTab: (UUID) -> Void = { _ in }
    /// A pinned tab's or favorite's "Edit Pinned Page" submenu: Edit… and Replace Pinned URL with Current.
    var editPinnedURL: (UUID) -> Void = { _ in }
    var replacePinnedURL: (UUID) -> Void = { _ in }
    /// A tab's Rename…: in place in its row, or Arc's dialog where there's no row.
    var renameTab: (UUID) -> Void
    /// Tidy Tabs: the Today divider's Tidy button, and a tab group header's context menu.
    var tidyTabs: (UUID) -> Void = { _ in }
    /// The Today divider's Clear button: Clear Today for that space.
    var clearToday: (UUID) -> Void = { _ in }
    var removeTabGroupHeader: (UUID) -> Void = { _ in }
    /// A tab row's speaker button and Mute / Unmute menu item.
    var toggleMute: (UUID) -> Void = { _ in }
    /// A space's Set Profile (space id, profile folder) and its New Profile….
    var setProfile: (UUID, String) -> Void = { _, _ in }
    var newProfile: (UUID) -> Void = { _ in }
    /// False in incognito windows, which have no profiles.
    var showsProfiles = true
    /// Instant Links' loading row's close button.
    var dismissInstantLinks: (UUID) -> Void = { _ in }
    /// After a drag drops something in the sidebar: Arc's move toasts.
    var didDrop: (SidebarDropOutcome) -> Void = { _ in }
}

/// Arc's sidebar, top to bottom: navigation, address pill, favorites grid,
/// the space's pinned items (with folders), new tab and today's tabs, spaces.
struct SidebarView: View {
    let store: BrowserStore
    let actions: SidebarActions
    /// False on WebKit, which can't force pages dark.
    let supportsDarkPages: Bool
    let claude: ClaudeButtonModel
    let downloads: DownloadsButtonModel
    /// Opens the extensions popover from the address field's hover button; nil where
    /// extensions don't run (incognito, WebKit).
    var showExtensions: ((NSView) -> Void)?
    /// Always shown at the address field's right end (1Password's key); hides itself when
    /// there's nothing to show.
    var fieldAccessory: AnyView?
    /// Opens Site Controls from the address field's hover button.
    var showSiteControls: ((NSView) -> Void)?
    /// Chrome's install icon, shown while the tab's page has an installable manifest; nil in incognito.
    var installApp: ((NSView) -> Void)?
    /// Where a two-finger swipe between spaces has the pages.
    var swipe = SpaceSwipeModel()
    /// The Mini Player's buttons; nil shows no Mini Player.
    var miniPlayer: MiniPlayerActions?
    @State private var drag = SidebarDragModel()

    var body: some View {
        // The host's width, not the column's: the column must never be wider than the sidebar, or
        // SwiftUI centres it and everything spills off both edges.
        GeometryReader { proxy in
            column(width: proxy.size.width)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func column(width: CGFloat) -> some View {
        let state = store.state
        let space = state.selectedSpace
        let selectedID = space.selectedTabID
        let page = selectedID.flatMap { store.pages[$0] } ?? PageStatus()
        let selectedTab = state.selectedTab

        VStack(alignment: .leading, spacing: 0) {
            // One row with the traffic lights: sidebar toggle after them, navigation at the far end.
            // With View → Show Toolbar, navigation and the URL move to the bar over the page.
            let header = HeaderLayout(sidebarWidth: width)
            HStack(spacing: 0) {
                // Arc's compact header drops the toggle into the More menu.
                if !header.isCompact {
                    ToolbarButton(symbol: "sidebar.left", help: "Toggle Sidebar", enabled: true, action: actions.toggleSidebar)
                        .padding(.leading, M.toggleX - M.padding)
                }
                Spacer(minLength: 0)
                if !state.showsToolbar {
                    NavigationButtons(layout: header, page: page, hasTab: selectedID != nil,
                                  developerReload: state.isInDeveloperMode(selectedTab?.url) ? state.devModeReloadState : nil,
                                  actions: actions)
                } else if header.isCompact {
                    NavigationMoreButton(size: header.buttonSize, page: page, hasTab: selectedID != nil, showsReload: false, actions: actions)
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
                    showSiteControls: SiteControls.applies(to: selectedTab?.url) ? showSiteControls : nil,
                    accessory: fieldAccessory,
                    installAppName: installApp == nil ? nil : WebAppInstallOffers.shared.offer(for: selectedID)?.name,
                    installApp: installApp
                )
                .padding(.top, M.urlFieldTopGap)
            }

            // Arc's tray shows while dragging even when there are no favorites (`AppTrayDisplayMode.onDrag`).
            if !state.favorites.isEmpty || drag.isDragging || !UserDefaults.standard.bool(forKey: "favoritesEmptyStateDismissed") {
                FavoritesGrid(
                    store: store,
                    favorites: state.favorites,
                    selectedID: selectedID,
                    onSelect: { id in store.mutate { $0.select(tab: id) } },
                    onUnload: actions.closeTab,
                    onRemove: { id in store.mutate { $0.toggleFavorite(tab: id) } },
                    onEditPinnedURL: actions.editPinnedURL,
                    onReplacePinnedURL: actions.replacePinnedURL,
                    onDrop: actions.didDrop
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.favoritesArea = $0 }
                .onDisappear { drag.favoritesArea = nil }
                .padding(.top, M.favoritesTopGap)
                .padding(.bottom, M.favoritesBottomGap)
            }

            SpacePages(store: store, swipe: swipe) { space in
                spaceList(space)
            }

            if let miniPlayer, let id = store.miniPlayerTabID, let tab = state.tab(id), let page = store.pages[id],
               page.media != nil || page.capturingSince != nil {
                MiniPlayerView(
                    tab: tab, media: page.media?.state, isRecording: page.capturingSince != nil, call: page.callControls,
                    isMuted: page.isAudioMuted, volume: page.tabVolume, actions: miniPlayer
                )
                    .id(id)
                    .padding(.top, M.padding)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            SpaceBar(store: store, actions: actions, claude: claude, downloads: downloads)
                .frame(height: M.bottomBarHeight)
        }
        .padding(.horizontal, M.padding)
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.primary)
        .overlay { SidebarDragOverlay(drag: drag) }
        .onAppear { drag.store = store }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.bounds = $0 }
        .environment(\.sidebarDrag, drag)
    }

    /// One space's page: its header, pinned items, new tab and today's tabs.
    private func spaceList(_ space: Space) -> some View {
        ScrollViewReader { proxy in
            spaceRows(space)
                // Tabs › Reveal Tab in Sidebar. Next turn, so a sidebar that was just shown has laid out.
                .onChange(of: store.revealRequest) { _, request in
                    guard let request, space.id == store.state.selectedSpaceID else { return }
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(request.rowID) } }
                }
        }
    }

    private func spaceRows(_ space: Space) -> some View {
        List {
            Section {
                // A row rather than a section header: a plain List paints headers with an opaque bar.
                SpaceHeader(store: store, actions: actions, space: space)
                    .modifier(dropOnly(.header, space: space.id))
                    .background {
                        if space.id == store.state.selectedSpaceID { SidebarScrollViewFinder(drag: drag) }
                    }
                    .sidebarRow(pill: false)
                // View → Collapse Pinned Tabs leaves only the selected pinned tab.
                let shownPinned = store.state.shownPinnedItems(in: space)
                let pinnedGroups = SidebarGroup.group(shownPinned.map(\.id), splits: space.splits)
                ForEach(pinnedGroups) { group in
                    pinnedGroup(group, in: shownPinned, parent: nil, depth: 0, space: space, selectedID: space.selectedTabID)
                        .sidebarRow()
                }
            }
            Section {
                // Arc's Tidy and Clear buttons sit on this divider (UnpinnedSectionDividerCellView).
                let canTidy = TidyTabs.isEnabled() && store.state.canTidyTabs(inSpace: space.id)
                let canClear = !space.tabs.isEmpty
                if !space.pinnedItems.isEmpty || canTidy || canClear {
                    TodayDivider(
                        showsLine: !space.pinnedItems.isEmpty,
                        canTidy: canTidy,
                        canClear: canClear,
                        isTidying: store.tidyingSpaceIDs.contains(space.id),
                        onTidy: { actions.tidyTabs(space.id) },
                        onClear: { actions.clearToday(space.id) })
                        .modifier(dropOnly(.divider, space: space.id))
                        .sidebarRow(pill: false)
                }
                NewTabRow { store.showCommandBar(.newTab) }
                    .modifier(dropOnly(.newTab, space: space.id))
                    .sidebarRow()
                // Where Instant Links' results will open (Arc's SidebarInstantLinks item).
                ForEach(store.instantLinksRows.filter { $0.spaceID == space.id }) { row in
                    InstantLinksRow(row: row) { actions.dismissInstantLinks(row.id) }
                        .sidebarRow()
                }
                let unpinnedGroups = SidebarGroup.group(space.tabs.map(\.id), splits: space.splits)
                ForEach(unpinnedGroups) { group in
                    unpinnedGroup(group, in: space.tabs, space: space, selectedID: space.selectedTabID)
                        .sidebarRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // With a mouse connected macOS shows a legacy scroller, which took 15pt from every pill
        // and drew a track in the sidebar. Scrolling still works; only the indicator goes.
        .scrollIndicators(.never)
        .environment(\.defaultMinListRowHeight, 1)
    }

    /// Nil hides the moon: nothing to darken, or the engine can't.
    private func darkPageState(for tab: BrowserTab?) -> Bool? {
        guard supportsDarkPages, let url = tab?.url, url.host() != nil else { return nil }
        return store.state.wantsDarkPage(for: url, systemIsDark: store.systemIsDark)
    }

    /// Folders nest, so this recursion has to erase its type.
    private func pinnedItem(_ item: PinnedItem, parent: UUID?, depth: Int, space: Space, selectedID: UUID?) -> AnyView {
        switch item {
        case .tab(let tab):
            return AnyView(row(tab, pinned: true, selected: tab.id == selectedID, depth: depth, space: space.id, parent: parent))
        case .folder(let folder):
            // Like Arc, a collapsed folder still shows its selected tab.
            let visible = folder.isExpanded
                ? folder.items
                : folder.items.tabs.filter { $0.id == selectedID }.map(PinnedItem.tab)
            return AnyView(VStack(spacing: M.rowPitch - M.pillHeight) {
                FolderRow(
                    folder: folder, depth: depth,
                    onToggle: { store.mutate { $0.setFolderExpanded(folder.id, !folder.isExpanded) } },
                    onRename: { actions.renameFolder(folder.id) },
                    onDelete: { actions.deleteFolder(folder.id) })
                    .modifier(SidebarDragSource(
                        store: store,
                        row: .init(id: folder.id, kind: .folder(expanded: folder.isExpanded), space: space.id, pinned: true,
                                   folder: parent, depth: depth, frame: .zero),
                        onDrop: actions.didDrop) { DragGhost(icon: .symbol("folder.fill"), title: folder.name, depth: depth) })
                ForEach(SidebarGroup.group(visible.map(\.id), splits: space.splits)) { group in
                    pinnedGroup(group, in: visible, parent: folder.id, depth: depth + 1, space: space, selectedID: selectedID)
                }
            })
        }
    }

    @ViewBuilder
    private func unpinnedGroup(_ group: SidebarGroup, in tabs: [BrowserTab], space: Space, selectedID: UUID?) -> some View {
        // Tidy Tabs' header rides on the first tab of its group, so drag offsets stay the tabs'.
        if let header = store.state.tabGroupHeader(above: tabs[group.indices[0]].id, inSpace: store.state.selectedSpace) {
            VStack(spacing: 0) {
                TabGroupHeaderRow(
                    group: header,
                    onClose: { header.tabIDs.forEach(actions.closeTab) },
                    onRemoveHeader: { actions.removeTabGroupHeader(header.id) })
                unpinnedTabs(group, in: tabs, space: space, selectedID: selectedID)
            }
        } else {
            unpinnedTabs(group, in: tabs, space: space, selectedID: selectedID)
        }
    }

    @ViewBuilder
    private func unpinnedTabs(_ group: SidebarGroup, in tabs: [BrowserTab], space: Space, selectedID: UUID?) -> some View {
        if let split = group.split {
            splitRow(split, tabs: group.indices.map { tabs[$0] }, pinned: false, selectedID: selectedID, space: space.id, parent: nil)
        } else {
            let tab = tabs[group.indices[0]]
            row(tab, pinned: false, selected: tab.id == selectedID, space: space.id, parent: nil)
        }
    }

    private func pinnedGroup(_ group: SidebarGroup, in items: [PinnedItem], parent: UUID?, depth: Int, space: Space, selectedID: UUID?) -> AnyView {
        guard let split = group.split else {
            return pinnedItem(items[group.indices[0]], parent: parent, depth: depth, space: space, selectedID: selectedID)
        }
        let tabs = group.indices.compactMap { index -> BrowserTab? in
            if case .tab(let tab) = items[index] { return tab }
            return nil
        }
        return AnyView(splitRow(split, tabs: tabs, pinned: true, selectedID: selectedID, depth: depth, space: space.id, parent: parent))
    }

    private func splitRow(_ split: SplitView, tabs: [BrowserTab], pinned: Bool, selectedID: UUID?, depth: Int = 0,
                          space: UUID, parent: UUID?) -> some View {
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
        .modifier(SidebarDragSource(
            store: store,
            row: .init(id: split.id, kind: .split, space: space, pinned: pinned, folder: parent, depth: depth, frame: .zero,
                       members: split.tabIDs),
            onDrop: actions.didDrop) { DragGhost(icon: .tabs(tabs), title: "", depth: depth) })
    }

    /// The space's header, the Today divider and New Tab take drops but don't drag.
    private func dropOnly(_ kind: SidebarDragModel.Row.Kind, space: UUID) -> SidebarDragSource<EmptyView> {
        SidebarDragSource(store: store, row: .init(id: space, kind: kind, space: space, pinned: kind != .newTab, folder: nil, depth: 0, frame: .zero),
                          draggable: false) { EmptyView() }
    }

    private func row(_ tab: BrowserTab, pinned: Bool, selected: Bool, depth: Int = 0, space: UUID, parent: UUID?) -> some View {
        SplitDropPreview(side: drag.splitSide(for: tab.id)) { tabRow(tab, pinned: pinned, selected: selected, depth: depth) }
        .modifier(SidebarDragSource(
            store: store,
            row: .init(id: tab.id, kind: .tab, space: space, pinned: pinned, folder: parent, depth: depth, frame: .zero),
            onDrop: actions.didDrop) { DragGhost(icon: .tabs([tab]), title: tab.displayTitle, depth: depth) })
    }

    private func tabRow(_ tab: BrowserTab, pinned: Bool, selected: Bool, depth: Int) -> some View {
        TabRow(
            tab: tab,
            isPinned: pinned,
            isSelected: selected,
            depth: depth,
            isRenaming: store.renamingTabID == tab.id,
            onSelect: { store.mutate { $0.select(tab: tab.id) } },
            onClose: { actions.closeTab(tab.id) },
            onTogglePin: { store.mutate { $0.togglePin(tab: tab.id) } },
            onFavorite: { store.mutate { $0.toggleFavorite(tab: tab.id) } },
            canReset: pinned && tab.hasLeftPinnedURL,
            onReset: { actions.resetTab(tab.id) },
            onSeparate: { actions.separateFromPinnedTab(tab.id) },
            onEditPinnedURL: { actions.editPinnedURL(tab.id) },
            onReplacePinnedURL: { actions.replacePinnedURL(tab.id) },
            onRename: { actions.renameTab(tab.id) },
            onCommitRename: { name in
                guard store.renamingTabID == tab.id else { return }
                store.mutate { $0.renameTab(tab.id, to: name) }
                store.endRenamingTab()
            },
            onCancelRename: { store.endRenamingTab() },
            isAudible: store.pages[tab.id]?.isAudible ?? false,
            isMuted: store.pages[tab.id]?.isAudioMuted ?? false,
            onToggleMute: { actions.toggleMute(tab.id) }
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

/// A tab or split row's pill. Arc's colours for these come in light and dark pairs
/// rather than one white scaled up, so on a light theme a hovered tab gets a faint
/// dark wash instead of a white haze.
struct TabPillFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).fill(fill)
        )
    }

    private var fill: Color {
        let dark = scheme == .dark
        if isSelected { return .white.opacity(dark ? M.selectedFill : M.selectedFillLight) }
        if isHovered { return dark ? .white.opacity(M.hoverFill) : Color(red: 0.055, green: 0.059, blue: 0.063).opacity(M.hoverFillLight) }
        return .clear
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    var size: CGFloat = M.navButtonSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.6 : 0.25)
        .disabled(!enabled)
        .help(help)
        // Otherwise VoiceOver and the ui tree read the SF Symbol's own name.
        .accessibilityLabel(help)
    }
}

/// Arc's header layouts by sidebar width (see `ArcMetrics.Sidebar.headerCompactBelow`).
struct HeaderLayout: Equatable {
    let isCompact: Bool
    let buttonSize: CGFloat
    let spacing: CGFloat

    init(sidebarWidth: CGFloat) {
        isCompact = sidebarWidth < M.headerCompactBelow
        buttonSize = isCompact ? M.compactNavButtonSize : M.navButtonSize
        spacing = isCompact ? M.compactNavButtonSpacing : M.navButtonSpacing
    }
}

/// Back, forward and reload at the header's right end. Arc 1.169's compact layout (from its
/// binary, `BrowserNavigationButtons`) shrinks them to 28pt with no gap and swaps the sidebar
/// toggle and reload for a More menu, which fits down to Arc's 164pt minimum.
private struct NavigationButtons: View {
    let layout: HeaderLayout
    let page: PageStatus
    let hasTab: Bool
    /// The reload setting when the page's site is in Developer Mode, nil otherwise.
    let developerReload: DeveloperTabReloadSetting?
    let actions: SidebarActions

    var body: some View {
        HStack(spacing: layout.spacing) {
            ToolbarButton(symbol: "arrow.left", help: "Back", enabled: page.canGoBack, size: layout.buttonSize, action: actions.goBack)
            ToolbarButton(symbol: "arrow.right", help: "Forward", enabled: page.canGoForward, size: layout.buttonSize, action: actions.goForward)
            if layout.isCompact {
                NavigationMoreButton(size: layout.buttonSize, page: page, hasTab: hasTab, showsReload: true, actions: actions)
            } else {
                ToolbarButton(symbol: page.isLoading ? "xmark" : developerReload == .forceReload ? "arrow.clockwise.circle" : "arrow.clockwise",
                              help: developerReload == .forceReload ? "Refresh (Ignore Cache)" : "Reload",
                              enabled: hasTab, size: layout.buttonSize, action: actions.reloadButton)
                if let developerReload {
                    DeveloperReloadOptionsButton(setting: developerReload, size: layout.buttonSize, hasTab: hasTab, actions: actions)
                }
            }
        }
    }
}

/// Arc's `reloadOptionsButton`, shown beside reload on a Developer Mode site ("A button that
/// shows a list of reload options"). Items from the strings beside it in Arc's binary; the
/// layout and the checkmark are Kite's guess.
private struct DeveloperReloadOptionsButton: View {
    let setting: DeveloperTabReloadSetting
    let size: CGFloat
    let hasTab: Bool
    let actions: SidebarActions

    var body: some View {
        Menu {
            Toggle("Reload this page", isOn: .init(get: { setting == .reload }, set: { _ in actions.developerReload(.reload) }))
            Toggle("Refresh (Ignore Cache)", isOn: .init(get: { setting == .forceReload }, set: { _ in actions.developerReload(.forceReload) }))
            Divider()
            Button("Clear Cookies and Refresh", action: actions.clearCookiesAndRefresh)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: size / 2, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: size / 2, height: size)
        .opacity(0.6)
        .disabled(!hasTab)
        .help("Refresh options")
        .accessibilityLabel("Refresh options")
    }
}

/// Arc's `navigationButtonsMore`: reload, the sidebar toggle and force reload, from the strings
/// beside it in Arc's binary. Item order and wording are unverified.
private struct NavigationMoreButton: View {
    let size: CGFloat
    let page: PageStatus
    let hasTab: Bool
    /// False while View → Show Toolbar has reload over the page.
    let showsReload: Bool
    let actions: SidebarActions

    var body: some View {
        Menu {
            if showsReload {
                Button(page.isLoading ? "Stop" : "Reload", action: actions.reload).disabled(!hasTab)
            }
            Button("Toggle Sidebar", action: actions.toggleSidebar)
            if showsReload {
                Button("Force Reload", action: actions.forceReload).disabled(!hasTab)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: size, height: size)
        .opacity(0.6)
        .help("More")
        .accessibilityLabel("More")
    }
}

private struct AddressPill: View {
    let text: String
    /// Whether the page is shown dark; nil hides the toggle.
    let isDark: Bool?
    let action: () -> Void
    let toggleDark: () -> Void
    var showExtensions: ((NSView) -> Void)?
    var showSiteControls: ((NSView) -> Void)?
    var accessory: AnyView?
    /// The installable app's name; nil hides the install icon.
    var installAppName: String?
    var installApp: ((NSView) -> Void)?
    @State private var hovering = false
    // Settings → Advanced → Toolbar can hide each button; their commands still work from the menu bar.
    @AppStorage(ChromeButton.passwordManager.hiddenKey) private var hidesPasswordManager = false
    @AppStorage(ChromeButton.darkPage.hiddenKey) private var hidesDarkPage = false
    @AppStorage(ChromeButton.siteControls.hiddenKey) private var hidesSiteControls = false
    @AppStorage(ChromeButton.extensions.hiddenKey) private var hidesExtensions = false

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
            // Arc's buttons at the field's right end are 30pt wide on a 28pt pitch. Arc 1.169
            // shows its Site Control Center button (with the extensions) only on hover; Kite
            // always shows the extensions button, rightmost (Gabe's call, 2026-11-01).
            let isDark = hidesDarkPage ? nil : isDark
            let showSiteControls = hidesSiteControls ? nil : showSiteControls
            let showExtensions = hidesExtensions ? nil : showExtensions
            HStack(spacing: -2) {
                if let accessory, !hidesPasswordManager { accessory }
                if let isDark {
                    DarkPageToggle(isDark: isDark, action: toggleDark)
                }
                // Arc reveals Site Control Center at the field's right end on hover.
                if let showSiteControls {
                    SiteControlsFieldButton(action: showSiteControls)
                        .opacity(hovering || SiteControlsPopover.isShown ? 1 : 0)
                }
                // Chrome's install icon sits at the field's right end; the extensions button stays rightmost.
                if let installAppName, let installApp {
                    InstallAppFieldButton(appName: installAppName, size: ExtensionsFieldButton.size, action: installApp)
                }
                if let showExtensions {
                    ExtensionsFieldButton(action: showExtensions)
                }
            }
            .padding(.trailing, isDark != nil || showExtensions != nil || showSiteControls != nil || installAppName != nil ? 4 : 0)
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

/// Chrome's install icon (a monitor with a down arrow, kInstallDesktopIcon), tooltip "Install <app>"
/// (IDS_OMNIBOX_PWA_INSTALL_ICON_TOOLTIP). The address field's other buttons' size and hover.
struct InstallAppFieldButton: View {
    let appName: String
    var size: CGFloat = 30
    var opacity: (normal: Double, hovered: Double) = (0.6, 0.9)
    let action: (NSView) -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { if let anchor { action(anchor) } } label: {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: size, height: size)
                .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0, cornerRadius: 6))
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? opacity.hovered : opacity.normal)
        .onHover { hovering = $0 }
        .help("Install \(appName)")
        .accessibilityLabel("Install \(appName)")
    }
}

/// Site Control Center's sliders button in the address field.
private struct SiteControlsFieldButton: View {
    let action: (NSView) -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { if let anchor { action(anchor) } } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: ExtensionsFieldButton.size, height: ExtensionsFieldButton.size)
                .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0, cornerRadius: 6))
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 0.9 : 0.6)
        .onHover { hovering = $0 }
        .help("Site Control Center")
        .accessibilityLabel("Site Control Center")
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
    let store: BrowserStore
    let favorites: [BrowserTab]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onUnload: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onEditPinnedURL: (UUID) -> Void
    let onReplacePinnedURL: (UUID) -> Void
    let onDrop: (SidebarDropOutcome) -> Void
    @Environment(\.sidebarDrag) private var drag
    @AppStorage("favoritesEmptyStateDismissed") private var emptyStateDismissed = false

    /// The tray's slots: each favorite, and the drop gap while a drag aims between them.
    private enum Slot: Identifiable, Hashable {
        case tile(BrowserTab)
        case gap

        var id: String {
            switch self {
            case .tile(let tab): tab.id.uuidString
            case .gap: "gap"
            }
        }
    }

    private var slots: [Slot] {
        var slots = favorites.map(Slot.tile)
        // Arc's tray counts one more item while a drag aims at it and leaves `dropGapFrame` empty.
        if !favorites.isEmpty, case .favorites(let before)? = drag?.session?.target {
            let at = before.flatMap { id in favorites.firstIndex { $0.id == id } } ?? favorites.count
            slots.insert(.gap, at: at)
        }
        return slots
    }

    var body: some View {
        let slots = slots
        if slots.isEmpty {
            if !emptyStateDismissed || drag?.isDragging == true {
                FavoritesEmptyState(onDismiss: drag?.isDragging == true ? nil : { emptyStateDismissed = true })
            }
        } else {
            FavoritesTrayLayout {
                ForEach(slots) { slot in
                    switch slot {
                    case .gap:
                        Color.clear
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag?.dropGap = $0 }
                            .onDisappear { drag?.dropGap = nil }
                    case .tile(let tab):
                        tile(tab)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.12), value: slots)
        }
    }

    private func tile(_ tab: BrowserTab) -> some View {
        FavoriteTile(
            tab: tab,
            isSelected: tab.id == selectedID,
            onSelect: { onSelect(tab.id) },
            onUnload: { onUnload(tab.id) },
            onRemove: { onRemove(tab.id) },
            onEditPinnedURL: { onEditPinnedURL(tab.id) },
            onReplacePinnedURL: { onReplacePinnedURL(tab.id) }
        )
        // Tiles being dragged out of the tray keep their place, invisible (Arc: alpha 0).
        .opacity(drag?.session?.ids.contains(tab.id) == true ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag?.reportTile(tab.id, frame: $0) }
        .onDisappear { drag?.reportTile(tab.id, frame: nil) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard let drag else { return }
                if !drag.isDragging {
                    let frame = drag.tileFrame(tab.id) ?? .zero
                    let row = SidebarDragModel.Row(id: tab.id, kind: .tab, space: store.state.selectedSpaceID, pinned: false,
                                                   folder: nil, depth: 0, frame: frame)
                    drag.begin([tab.id], row: row, at: value.startLocation, ghost: AnyView(FavoriteGhost(tab: tab)))
                }
                drag.move(to: value.location, in: store.state)
            }
            .onEnded { value in
                guard let drag, let drop = drag.end(at: value.location, in: store.state) else { return }
                var outcome: SidebarDropOutcome?
                withAnimation(.easeInOut(duration: 0.12)) {
                    store.mutate { outcome = $0.dropSidebarItems(drop.ids, on: drop.target) }
                }
                if let outcome { onDrop(outcome) }
            })
    }
}

/// Arc's `AppTrayCollectionViewLayout` for favorites (Arc 1.169's binary): tiles 47pt high, 8pt
/// apart, at most 4 a row. It fits as many columns as square tiles would allow, then balances
/// the rows: 5 favorites are 3 + 2, 7 are 4 + 3, 9 are 3 × 3.
struct FavoritesTrayLayout: Layout {
    static func columns(count n: Int, width: CGFloat) -> Int {
        guard n > 0 else { return 1 }
        let h = M.favoriteHeight, gap = M.favoriteSpacing
        let fit = max(Int(((width + gap) / (h + gap)).rounded(.down)), 1)
        let c = min(n, M.favoriteColumns, fit)
        let rows = (n + c - 1) / c
        return (n + rows - 1) / rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(M.favoriteColumns) * (M.favoriteHeight + M.favoriteSpacing)
        let cols = Self.columns(count: subviews.count, width: width)
        let rows = (subviews.count + cols - 1) / cols
        return CGSize(width: width, height: CGFloat(rows) * M.favoriteHeight + CGFloat(max(rows - 1, 0)) * M.favoriteSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = Self.columns(count: subviews.count, width: bounds.width)
        let width = (bounds.width - M.favoriteSpacing * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % cols) * (width + M.favoriteSpacing)
            let y = bounds.minY + CGFloat(i / cols) * (M.favoriteHeight + M.favoriteSpacing)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: M.favoriteHeight))
        }
    }
}

/// Arc's empty favorites tray (`AppTrayEmptyStateView`): its title and subtitle from Arc's strings,
/// with a close button that hides it until a drag needs somewhere to drop. Its size and look are
/// unmeasured.
private struct FavoritesEmptyState: View {
    var onDismiss: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            Text("Drag to add Favorites")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.7)
            Text("Favorites keep your most used sites and apps close")
                .font(.system(size: 11))
                .opacity(0.45)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: M.favoriteHeight)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .overlay(alignment: .topTrailing) {
            if let onDismiss, hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.5)
                .padding(4)
                .help("Dismiss")
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A favorite's tile as it follows the pointer.
private struct FavoriteGhost: View {
    let tab: BrowserTab

    var body: some View {
        FaviconView(tab: tab, size: M.favoriteIconSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ChromeFill(strength: M.fieldFill + M.selectedFill))
    }
}

/// A sidebar row as it follows the pointer: the pill with its icon and title.
struct DragGhost: View {
    enum Icon {
        case tabs([BrowserTab])
        case symbol(String)
    }

    let icon: Icon
    let title: String
    var depth = 0

    var body: some View {
        HStack(spacing: M.iconTextGap) {
            switch icon {
            case .tabs(let tabs):
                ForEach(tabs) { FaviconView(tab: $0, size: M.iconSize) }
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 14)).frame(width: M.iconSize, height: M.iconSize)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: M.tabFontSize))
                    .opacity(M.tabTextOpacity)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, M.iconInset + indent(depth))
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(TabPillFill(isSelected: true, isHovered: false))
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onUnload: () -> Void
    let onRemove: () -> Void
    let onEditPinnedURL: () -> Void
    let onReplacePinnedURL: () -> Void
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
                if tab.pinnedURL != nil {
                    EditPinnedPageMenu(onEdit: onEditPinnedURL, onReplace: onReplacePinnedURL)
                }
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

/// The line between pinned and Today tabs, with Arc's Tidy and Clear buttons at its right end
/// (UnpinnedSectionDividerCellView: line, Tidy, Clear). Both fade in while the pointer is on the
/// row (Arc: ease-out 0.1 s alpha). Tidy ("Tidy", tooltip "Organize Today Tabs") turns while
/// Claude works; Clear ("↓ Clear", tooltip "Clear Today tabs") runs Clear Today for this space.
private struct TodayDivider: View {
    let showsLine: Bool
    let canTidy: Bool
    let canClear: Bool
    let isTidying: Bool
    let onTidy: () -> Void
    let onClear: () -> Void
    @State private var hovering = false
    @State private var turning = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(.primary.opacity(showsLine ? M.dividerOpacity : 0))
                .frame(height: M.dividerThickness)
                .padding(.horizontal, M.dividerInset)
            HStack(spacing: 6) {
                if canTidy, hovering || isTidying {
                    tidyButton.transition(.opacity)
                }
                if canClear, hovering {
                    Button(action: onClear) { EmptyView() }
                        .buttonStyle(ClearButtonStyle())
                        .help("Clear Today tabs")
                        .accessibilityLabel("Clear")
                        .transition(.opacity)
                }
            }
            .padding(.trailing, M.dividerInset)
        }
        .frame(height: M.dividerRowHeight)
        .contentShape(Rectangle())
        // Keeps a lone button's accessibility frame its own instead of the whole row's.
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
        .onChange(of: isTidying, initial: true) { _, tidying in
            if tidying {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
            } else {
                withAnimation(.linear(duration: 0)) { turning = false }
            }
        }
    }

    private var tidyButton: some View {
        Button(action: onTidy) {
            HStack(spacing: 3) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(turning ? 360 : 0))
                Text("Tidy")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .modifier(ChromeFill(strength: M.hoverFill))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .opacity(isTidying ? 0.6 : 0.75)
        .disabled(isTidying)
        .help("Organize Today Tabs")
        .accessibilityLabel("Tidy")
    }
}

/// Arc's SidebarClearButton: a bold `arrow.down` 2 pt left of the "Clear" label, no background.
/// Pressing it dims it and drops the arrow 3 pt (0.175 s); releasing puts the arrow back, and
/// the click counts only if the pointer is still on the button (an ordinary button release).
private struct ClearButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .offset(y: configuration.isPressed ? 3 : 0)
                .animation(.easeInOut(duration: 0.175), value: configuration.isPressed)
            Text("Clear")
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.5 : 0.75)
    }
}

/// Arc's tab group header (TabGroupHeaderCellView) above a Tidy Tabs group: its name, a close
/// button on hover ("Close tab group", archives the group's tabs) and Remove Header in its menu.
private struct TabGroupHeaderRow: View {
    let group: TodayTabGroup
    let onClose: () -> Void
    let onRemoveHeader: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.55)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 0.55 : 0)
            .help("Close tab group")
            .accessibilityLabel("Close tab group")
        }
        .padding(.horizontal, M.iconInset)
        .frame(height: M.dividerRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove header", action: onRemoveHeader)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

private struct FolderRow: View {
    let folder: TabFolder
    let depth: Int
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
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
        // Arc's folder menu (SidebarMenu+ListContextMenu), in its order, with the items Kite has.
        .contextMenu {
            Button("Delete", action: onDelete)
            Divider()
            Button("Copy All Links") { copyLinks(folder.items.tabs.compactMap(\.url)) }
                .disabled(folder.items.tabs.allSatisfy { $0.url == nil })
            Divider()
            Button("Rename…", action: onRename)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAction { onToggle() }
    }
}

/// Arc's folder nesting per level (see `ArcMetrics.Sidebar.nestingIndent`).
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * M.nestingIndent
}

private func copyLinks(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
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
    var isRenaming = false
    let onSelect: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onFavorite: () -> Void
    /// A pinned tab away from its pinned page (Arc's TabCellState.canResetTab).
    var canReset = false
    var onReset: () -> Void = {}
    var onSeparate: () -> Void = {}
    var onEditPinnedURL: () -> Void = {}
    var onReplacePinnedURL: () -> Void = {}
    let onRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    /// Arc's TabCellState.isAudible / isMuted: the speaker button between favicon and title.
    var isAudible = false
    var isMuted = false
    var onToggleMute: () -> Void = {}
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var showsAudio: Bool { TabAudioButton.isShown(isAudible: isAudible, isMuted: isMuted) }

    var body: some View {
        HStack(spacing: M.iconTextGap) {
            FaviconView(tab: tab, size: M.iconSize)
            if showsAudio {
                TabAudioButtonView(isMuted: isMuted, action: onToggleMute)
                    // Arc: 2pt after the button, not the row's favicon-to-title gap.
                    .padding(.trailing, TabAudioButton.spacingAfter - M.iconTextGap)
                    .transition(.opacity)
            }
            if isRenaming {
                // In place, like the space name (Arc: "Double-click to rename").
                TextField("Keep it short and sweet!", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: M.tabFontSize))
                    .focused($fieldFocused)
                    .onSubmit { onCommitRename(draft) }
                    .onExitCommand(perform: onCancelRename)
                    .onAppear {
                        draft = tab.displayTitle
                        fieldFocused = true
                    }
                    .onChange(of: fieldFocused) { _, focused in if !focused { onCommitRename(draft) } }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: M.tabFontSize))
                    .opacity(M.tabTextOpacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hovering && canReset && !isRenaming {
                // Arc's tooltip; its icon and placement are unverified (see arc-visual-spec.md).
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Back to Pinned URL")
                .accessibilityLabel("Back to Pinned URL")
            }
            if hovering && !isRenaming {
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
        .animation(.easeInOut(duration: TabAudioButton.showHideDuration), value: showsAudio)
        .padding(.leading, M.iconInset + indent(depth))
        .padding(.trailing, 6)
        .frame(height: M.pillHeight)
        .modifier(TabPillFill(isSelected: isSelected, isHovered: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        // Alongside the single tap so selecting isn't held back waiting for a second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onRename))
        .contextMenu {
            Button("Add to Favorites", action: onFavorite)
            Button(isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            if canReset {
                Button("Back to Pinned URL", action: onReset)
                Button("Separate From Pinned Tab", action: onSeparate)
            }
            if isPinned && tab.pinnedURL != nil {
                EditPinnedPageMenu(onEdit: onEditPinnedURL, onReplace: onReplacePinnedURL)
            }
            Button("Copy Link") { copyLink(tab.url) }
            Button("Rename…", action: onRename)
            if showsAudio {
                Button(TabAudioButton.menuTitle(isMuted: isMuted), action: onToggleMute)
            }
            Divider()
            Button(isPinned ? "Unload Tab" : "Close Tab", action: onClose)
        }
    }
}

/// Arc's "Edit Pinned Page" submenu on a pinned tab or favorite (SidebarMenu+TabContextMenu,
/// SidebarMenu+MoveMenu): "Edit…" opens the Edit Pinned URL dialog, and "Replace Pinned URL
/// with Current" pins the page the tab is on. Arc builds both items unconditionally.
private struct EditPinnedPageMenu: View {
    let onEdit: () -> Void
    let onReplace: () -> Void

    var body: some View {
        Menu("Edit Pinned Page") {
            Button("Edit…", action: onEdit)
            Button("Replace Pinned URL with Current", action: onReplace)
        }
    }
}

/// Arc's audibility button (TabCellView.audibilityButton): a 24pt speaker that mutes or
/// unmutes the tab. Arc draws its own animated speaker (SF `speaker` plus three sound waves
/// and a slash); Kite uses the matching SF Symbols.
private struct TabAudioButtonView: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.3")
                .font(.system(size: 14, weight: .medium))
                .frame(width: TabAudioButton.side, height: TabAudioButton.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.6)
        .help(TabAudioButton.tooltip(isMuted: isMuted))
        .accessibilityLabel(TabAudioButton.tooltip(isMuted: isMuted))
        .accessibilityIdentifier("sidebarTabCellMuteButton")
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
        .modifier(TabPillFill(isSelected: focusedID != nil, isHovered: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
    }

    private func item(_ tab: BrowserTab, width: CGFloat) -> some View {
        let compact = width <= S.rowCompactWidth
        // Like Arc's SplitViewCellChildItemView: a title with 20pt or less to show is hidden
        // rather than cut to a letter and an ellipsis.
        // The HStack's gap comes twice: favicon to title, and title to the spacer after it.
        let titleWidth = width - 2 * M.iconInset - M.iconSize - 2 * M.iconTextGap
        let showsTitle = !compact && titleWidth > S.rowTitleMinWidth
        return HStack(spacing: M.iconTextGap) {
            FaviconView(tab: tab, size: M.iconSize)
            if !showsTitle && !compact { Spacer(minLength: 0) }
            if showsTitle {
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
        // Icon-only items would otherwise read as the favicon's symbol name.
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(tab.id == focusedID ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SpaceBar: View {
    @Environment(\.sidebarDrag) private var drag
    let store: BrowserStore
    let actions: SidebarActions
    let claude: ClaudeButtonModel
    let downloads: DownloadsButtonModel

    var body: some View {
        let state = store.state
        HStack(spacing: 4) {
            // Arc's Library button sits at the bar's leading end and carries download progress.
            DownloadsSidebarButton(model: downloads, size: M.bottomButtonSize)
            // Too many spaces to fit scroll rather than widen the bar: an over-wide bar pushes the whole
            // sidebar off its left edge. While they fit they stay a plain row, so the bar's empty part
            // still drags the window (a scroll view never does).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    spaceIcons(state)
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    spaceIcons(state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClaudeSidebarButton(model: claude, size: M.bottomButtonSize)
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

    private func spaceIcons(_ state: BrowserState) -> some View {
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
                .contextMenu { SpaceContextMenu(store: store, actions: actions, space: space) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag?.reportSpaceIcon(space.id, frame: $0) }
                .onDisappear { drag?.reportSpaceIcon(space.id, frame: nil) }
            }
        }
    }
}

/// The space's icon and name above its pinned tabs, Arc's small semibold caption.
/// Arc's space context menu, shared by the space's icon in the strip and its header. Arc's
/// `SidebarSpaceState+SpaceContextMenu` also has Share, Manage Spaces, Show/Hide Space Header, live folders,
/// profile and Turn into Folder, which Kite doesn't have yet.
private struct SpaceContextMenu: View {
    let store: BrowserStore
    let actions: SidebarActions
    let space: Space

    var body: some View {
        Button("Rename Space") { store.beginRenaming(space: space.id) }
        Button("New Folder") {
            guard let index = store.state.spaceIndex(space.id) else { return }
            store.mutate { _ = $0.createFolder(name: "New Folder", inSpace: index) }
        }
        Divider()
        // Arc's binary lists "Set Profile" just before Edit Theme Color.
        if actions.showsProfiles { SetProfileMenu(store: store, actions: actions, space: space) }
        Button("Edit Theme Color") { actions.editTheme(space.id) }
        Button("Change Space Icon") { actions.changeSpaceIcon(space.id) }
        Divider()
        Button("Delete Space") { actions.deleteSpace(space.id) }
            .disabled(store.state.spaces.count < 2)
    }
}

/// The space's icon and name above its pinned tabs, Arc's small semibold caption. As in Arc, the name
/// is renamed in place (`didBeginEditingSpaceName`, `didRenameSpace`, `didCancelRenameSpace`), the icon
/// is a button that changes it (`didClickEditableIcon`), and a right-click gives the space's menu.
private struct SpaceHeader: View {
    let store: BrowserStore
    let actions: SidebarActions
    let space: Space
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let renaming = store.renamingSpaceID == space.id
        HStack(spacing: M.headerTextX - M.headerIconX - M.headerIconSize) {
            Button { actions.changeSpaceIcon(space.id) } label: {
                Text(space.icon)
                    .font(.system(size: 15))
                    .frame(width: M.headerIconSize, height: M.headerIconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change Space Icon")
            if renaming {
                TextField("Space Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: M.headerFontSize, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { store.endRenaming() }
                    .onAppear {
                        draft = space.name
                        fieldFocused = true
                    }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                Text(space.name)
                    .font(.system(size: M.headerFontSize, weight: .semibold))
                    .opacity(M.headerTextOpacity)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Arc's pinned-tabs expansion toggler (a chevron in the space header): shown on hover,
            // and always while the pinned tabs are collapsed.
            if !space.pinnedItems.isEmpty && !renaming {
                let collapsed = store.state.isPinnedSectionCollapsed(space.id)
                Button { store.mutate { $0.togglePinnedSection(space.id) } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: M.headerIconSize, height: M.headerIconSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(collapsed ? 0.5 : (hovering ? 0.5 : 0))
                .help(collapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs")
                .accessibilityLabel(collapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs")
                .padding(.trailing, M.iconInset - M.padding)
            }
        }
        .padding(.leading, M.headerIconX - M.padding)
        .padding(.top, M.headerIconTop)
        .frame(height: M.headerHeight + M.listTopSpacer, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { SpaceContextMenu(store: store, actions: actions, space: space) }
    }

    private func commit() {
        guard store.renamingSpaceID == space.id else { return }
        store.mutate { $0.renameSpace(space.id, to: draft) }
        store.endRenaming()
    }
}
