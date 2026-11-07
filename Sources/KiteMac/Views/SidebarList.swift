import AppKit
import KiteCore
import SwiftUI

/// One space's page of the sidebar: its header, pinned items (folders nest), the Today divider, New Tab,
/// Instant Links' stand-in rows and today's tabs. Arc's tab list is an `NSOutlineView`; this is an
/// `NSTableView` with one row per item, in place of the SwiftUI `List` it replaces.
///
/// It reads the store under observation tracking and turns what it read into a flat list of row
/// models. A change rebuilds that list on the next turn, diffs it by row ID, animates rows in and out
/// the way Arc does, and hands changed models to the rows on screen. Nothing runs while nothing changes.
@MainActor
final class SidebarSpaceList: NSView {
    private typealias M = ArcMetrics.Sidebar

    let store: BrowserStore
    let spaceID: UUID
    var actions: SidebarActions
    let claude: ClaudeButtonModel
    let drag: SidebarDragModel
    var supportsDarkPages: Bool

    let scrollView = SidebarListScrollView()
    let table = SidebarTableView()
    private(set) var rows: [SidebarRowModel] = []
    private var updateScheduled = false
    private var revealHandled: RevealRequest?

    init(store: BrowserStore, spaceID: UUID, actions: SidebarActions, claude: ClaudeButtonModel, drag: SidebarDragModel,
         supportsDarkPages: Bool) {
        self.store = store
        self.spaceID = spaceID
        self.actions = actions
        self.claude = claude
        self.drag = drag
        self.supportsDarkPages = supportsDarkPages
        super.init(frame: .zero)
        wantsLayer = true

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.list = self
        table.setAccessibilityLabel("Sidebar")

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        addSubview(scrollView)

        drag.addRowSource(for: spaceID) { [weak self] in self?.dragRows() ?? [] }
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        drag.removeRowSource(for: spaceID)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        table.sizeLastColumnToFit()
        prepareRows()
    }

    /// A page beside the one in front lies outside the sidebar, where the table would build no rows, and a
    /// swipe would then build them all on its first frame. Like the SwiftUI list it replaces, every built
    /// page keeps the rows its scroll position shows.
    private func prepareRows() {
        let clip = scrollView.contentView.bounds
        table.prepareContent(in: NSRect(x: 0, y: clip.minY, width: table.bounds.width, height: clip.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { noteSelectedSpace() }
    }

    @objc private func clipScrolled() {
        // Only off-screen pages need it; the table prepares the one in front itself.
        if visibleRect.isEmpty { prepareRows() }
    }

    // MARK: Observing the store

    /// Builds the rows, watching everything that went into them; a change schedules another pass.
    private func update() {
        let next = withObservationTracking {
            let rows = buildRows()
            observeExtras()
            return rows
        } onChange: { [weak self] in
            // The store is main-actor state, so its changes come on the main thread; the pass runs
            // before this turn's display, like SwiftUI's.
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        apply(next)
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }

    /// State read outside the rows: the reveal request and which space is in front.
    private func observeExtras() {
        let request = store.revealRequest
        let selected = store.state.selectedSpaceID
        // The space menu's Change Space Icon… opens the picker from this space's header.
        if store.iconPickerRequest == spaceID {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.store.iconPickerRequest == self.spaceID else { return }
                self.store.iconPickerShown()
                (self.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SpaceHeaderRowCell)?.openPicker(after: 0.15)
            }
        }
        if selected == spaceID { noteSelectedSpace() }
        if let request, request != revealHandled, selected == spaceID {
            revealHandled = request
            // Next turn, so a sidebar that was just shown has laid out.
            DispatchQueue.main.async { [weak self] in self?.reveal(request.rowID) }
        }
    }

    /// The selected space's list is the one a drag autoscrolls.
    private func noteSelectedSpace() {
        guard store.state.selectedSpaceID == spaceID, drag.scrollView !== scrollView else { return }
        drag.scrollView = scrollView
    }

    // MARK: Rows

    private func buildRows() -> [SidebarRowModel] {
        let state = store.state
        guard let index = state.spaceIndex(spaceID) else { return [] }
        let space = state.spaces[index]
        let selectedID = space.selectedTabID
        var rows: [SidebarRowModel] = [.header(.init(
            spaceID: space.id, name: space.name, icon: space.icon, theme: space.theme, hasPinned: !space.pinnedItems.isEmpty,
            pinnedCollapsed: state.isPinnedSectionCollapsed(space.id), isRenaming: store.renamingSpaceID == space.id))]

        // View → Collapse Pinned Tabs leaves only the selected pinned tab.
        let shownPinned = state.shownPinnedItems(in: space)
        appendPinned(shownPinned, parent: nil, depth: 0, space: space, selectedID: selectedID, into: &rows)

        // Arc's Tidy and Clear buttons sit on this divider (UnpinnedSectionDividerCellView).
        let canTidy = TidyTabs.isEnabled() && state.canTidyTabs(inSpace: space.id)
        if !space.pinnedItems.isEmpty || canTidy || !space.tabs.isEmpty {
            rows.append(.divider(.init(
                spaceID: space.id, showsLine: !space.pinnedItems.isEmpty, canTidy: canTidy, canClear: !space.tabs.isEmpty,
                clearAction: state.todayClearAction(inSpace: space.id), isTidying: store.tidyingSpaceIDs.contains(space.id))))
        }
        rows.append(.newTab(spaceID: space.id))
        // Where Instant Links' results will open (Arc's SidebarInstantLinks item).
        for pending in store.instantLinksRows where pending.spaceID == space.id {
            rows.append(.instantLinks(pending))
        }
        for group in SidebarGroup.group(space.tabs.map(\.id), splits: space.splits) {
            let first = space.tabs[group.indices[0]]
            // Tidy Tabs' header rides on the first tab of its group, so drag offsets stay the tabs'.
            let header = state.tabGroupHeader(above: first.id, inSpace: state.selectedSpace)
            if let split = group.split {
                rows.append(.split(splitModel(split, tabs: group.indices.map { space.tabs[$0] }, pinned: false,
                                              selectedID: selectedID, depth: 0, space: space.id, parent: nil, groupHeader: header)))
            } else {
                rows.append(.tab(tabModel(first, pinned: false, selected: first.id == selectedID, depth: 0, space: space.id,
                                          parent: nil, groupHeader: header)))
            }
        }
        return rows
    }

    private func appendPinned(_ items: [PinnedItem], parent: UUID?, depth: Int, space: Space, selectedID: UUID?,
                              into rows: inout [SidebarRowModel]) {
        for group in SidebarGroup.group(items.map(\.id), splits: space.splits) {
            if let split = group.split {
                let tabs = group.indices.compactMap { index -> BrowserTab? in
                    if case .tab(let tab) = items[index] { return tab }
                    return nil
                }
                rows.append(.split(splitModel(split, tabs: tabs, pinned: true, selectedID: selectedID, depth: depth,
                                              space: space.id, parent: parent, groupHeader: nil)))
                continue
            }
            switch items[group.indices[0]] {
            case .tab(let tab):
                rows.append(.tab(tabModel(tab, pinned: true, selected: tab.id == selectedID, depth: depth, space: space.id,
                                          parent: parent, groupHeader: nil)))
            case .folder(let folder):
                rows.append(.folder(folderModel(folder, depth: depth, space: space.id, parent: parent)))
                // Like Arc, a collapsed folder still shows its selected tab.
                let visible = folder.isExpanded
                    ? folder.items
                    : folder.items.tabs.filter { $0.id == selectedID }.map(PinnedItem.tab)
                appendPinned(visible, parent: folder.id, depth: depth + 1, space: space, selectedID: selectedID, into: &rows)
            }
        }
    }

    /// Tabs Claude is driving right now (none in incognito).
    private var claudeControlled: Set<UUID> { claude.automation?.controlledTabIDs ?? [] }

    private func tabModel(_ tab: BrowserTab, pinned: Bool, selected: Bool, depth: Int, space: UUID, parent: UUID?,
                          groupHeader: TodayTabGroup?) -> SidebarRowModel.Tab {
        let live = parent.flatMap { store.state.folder(matching: $0.uuidString)?.folder }.flatMap { $0.live == nil ? nil : $0 }
        let audio = store.tabAudio[tab.id]
        let controlled = claudeControlled.contains(tab.id)
        let claudeState = claude.automation?.tabState(tab.id)
        var claudeControl: String?
        if case .working(let note?)? = claudeState {
            claudeControl = ClaudeTabState.working(note: note).help
        } else if case .working? = claudeState {
            let session = claude.automation?.sessionName(controlling: tab.id).map { " (\($0))" } ?? ""
            claudeControl = controlled ? "Claude is controlling this tab\(session)" : "Claude is working here\(session)"
        }
        // The line under the title. Working: Claude's working note, else Kite's words for its last tool call there
        // while it drives the tab (`ClaudeActivity`), else what it waits on. Stalled: "Claude stopped here, ask it to
        // pick up". Nothing for a handoff (its step is ringed on the page) or done.
        var claudeActivity: String?, claudeActivityLog: String?
        if case .working(let note)? = claudeState, let help = claudeControl {
            let log = claude.automation?.tabActivity[tab.id]
            claudeActivity = note ?? (controlled ? log?.latest?.text : nil) ?? ClaudeTabState.waitingLine
            claudeActivityLog = ClaudeActivity.tooltip(help: help, log: log)
        } else if claudeState?.isStalled == true {
            claudeActivity = ClaudeTabState.stoppedHereLine
        }
        return .init(
            tab: tab, space: space, parent: parent, depth: depth, isPinned: pinned, isSelected: selected,
            showsClose: store.state.showsCloseButton(tab: tab.id),
            isRenaming: store.renamingTabID == tab.id,
            aiRename: store.aiRenames[tab.id],
            canReset: pinned && tab.hasLeftPinnedURL,
            isAudible: audio?.isAudible ?? false,
            isMuted: audio?.isMuted ?? false,
            isUnread: live?.isUnread(tab) ?? false,
            liveIconTab: live != nil,
            peek: store.linkPeekBadges[tab.id],
            claudeControl: claudeControl,
            claudeActivity: claudeActivity,
            claudeActivityLog: claudeActivityLog,
            claudeNeedsYou: claudeState?.isNeedsYou == true ? claudeState?.help : nil,
            claudeDone: { if case .done? = claudeState { claudeState?.help } else { nil } }(),
            splitSide: drag.splitSide(for: tab.id),
            groupHeader: groupHeader)
    }

    private func folderModel(_ folder: TabFolder, depth: Int, space: UUID, parent: UUID?) -> SidebarRowModel.Folder {
        .init(folder: folder, space: space, parent: parent, depth: depth,
              isRenaming: store.renamingFolderID == folder.id,
              showsIntro: store.liveFolderIntroID == folder.id,
              claudeActive: claudeShowsActivity(on: folder),
              claudeNeedsYou: claudeNeedsYouCount(in: folder))
    }

    private func splitModel(_ split: SplitView, tabs: [BrowserTab], pinned: Bool, selectedID: UUID?, depth: Int, space: UUID,
                            parent: UUID?, groupHeader: TodayTabGroup?) -> SidebarRowModel.Split {
        .init(split: split, tabs: tabs, space: space, parent: parent, depth: depth, isPinned: pinned,
              focusedID: tabs.contains { $0.id == selectedID } ? selectedID : nil,
              audio: tabs.map { store.tabAudio[$0.id] ?? TabAudio() }
                  .map { SidebarRowModel.Split.Audio(audible: $0.isAudible, muted: $0.isMuted) },
              optionHeld: HeldModifiers.shared.flags.chordModifiers == .alt,
              groupHeader: groupHeader)
    }

    /// A Claude folder (Space › Claude › session) shows Claude at work while Claude drives a tab in it:
    /// the folder holding the tab, and a collapsed folder above it, so it shows wherever the tab is hidden.
    private func claudeShowsActivity(on folder: TabFolder) -> Bool {
        guard folder.ephemeral == true else { return false }
        let controlled = claudeControlled
        guard !controlled.isEmpty, folder.items.tabs.contains(where: { controlled.contains($0.id) }) else { return false }
        if !folder.isExpanded { return true }
        return folder.items.contains { item in
            if case .tab(let tab) = item { return controlled.contains(tab.id) }
            return false
        }
    }

    /// How many tabs in a folded folder have a step Claude handed the user (handoff), so the folder says so
    /// while its tab rows are hidden. 0 for an open folder: its rows show it.
    private func claudeNeedsYouCount(in folder: TabFolder) -> Int {
        guard !folder.isExpanded, let automation = claude.automation else { return 0 }
        return folder.items.tabs.filter { automation.tabState($0.id)?.isNeedsYou == true }.count
    }

    // MARK: Applying a new list

    private func apply(_ next: [SidebarRowModel]) {
        let old = rows
        let oldIDs = old.map(\.id), newIDs = next.map(\.id)
        guard oldIDs != newIDs else {
            rows = next
            refreshRows(from: old)
            return
        }
        // A first fill, or a list off screen, changes without animation.
        let animate = !old.isEmpty && window != nil && store.state.selectedSpaceID == spaceID
        let newSet = Set(newIDs)
        let oldSet = Set(oldIDs)
        let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })

        let change = {
            self.table.beginUpdates()
            // Rows that went, from the bottom up.
            let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
            self.table.removeRows(at: removed, withAnimation: animate ? .effectFade : [])
            var current = oldIDs.filter { newSet.contains($0) }
            // Rows that stayed, into their new order.
            let staying = newIDs.filter { oldSet.contains($0) }
            for (target, id) in staying.enumerated() {
                guard let from = current.firstIndex(of: id), from != target else { continue }
                self.table.moveRow(at: from, to: target)
                current.remove(at: from)
                current.insert(id, at: target)
            }
            self.rows = next
            // New rows, top down, each at its final index.
            self.table.insertRows(at: inserted, withAnimation: animate ? .effectFade : [])
            self.table.endUpdates()
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                let c = ArcMetrics.Motion.sidebarRowsCurve
                context.duration = ArcMetrics.Motion.sidebarRowsDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: c.x1, c.y1, c.x2, c.y2)
                context.allowsImplicitAnimation = true
                change()
                fadeIn(inserted, context: context)
            }
        } else {
            change()
        }
        refreshRows(from: old)
    }

    /// `.effectFade` alone leaves a new row opaque; like Arc's, new rows fade in on the group's timing.
    private func fadeIn(_ indexes: IndexSet, context: NSAnimationContext) {
        for row in indexes where row < table.numberOfRows {
            guard let view = table.rowView(atRow: row, makeIfNecessary: true) else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = context.duration
            fade.timingFunction = context.timingFunction
            layer.add(fade, forKey: "kiteFadeIn")
        }
    }

    /// Hands changed models to the rows on screen, and tells the table about height changes.
    private func refreshRows(from old: [SidebarRowModel]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var heights = IndexSet()
        for (index, model) in rows.enumerated() {
            guard let before = previous[model.id], before != model else { continue }
            if before.height != model.height { heights.insert(index) }
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarRowCell {
                cell.configure(model, list: self)
            }
        }
        if !heights.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: heights)
            }
        }
    }

    // MARK: Scrolling

    /// Tabs › Reveal Tab in Sidebar: scrolls the row into view (animated, like SwiftUI's `scrollTo`).
    private func reveal(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.contains(id) }) else { return }
        let rect = table.rect(ofRow: index)
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        guard !visible.contains(rect) else { return }
        let maxY = max(table.frame.height - clip.bounds.height, 0)
        let y = min(max(rect.midY - clip.bounds.height / 2, 0), maxY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Dragging

    /// The rows a drag aims at, in sidebar points (window points from the top-left).
    private func dragRows() -> [SidebarDragModel.Row] {
        guard window != nil else { return [] }
        return rows.indices.compactMap { index -> SidebarDragModel.Row? in
            guard var row = rows[index].dragRow else { return nil }
            var rect = table.rect(ofRow: index)
            // A tab group header rides on top of its tab; the tab's own pill is what drops aim at.
            rect.origin.y += rows[index].headerHeight
            rect.size.height -= rows[index].headerHeight
            let gap = (M.rowPitch - M.pillHeight) / 2
            if rows[index].isPill { rect = rect.insetBy(dx: 0, dy: gap) }
            row.frame = sidebarRect(from: table, rect: rect)
            return row
        }
    }

    func sidebarRect(from view: NSView, rect: CGRect) -> CGRect {
        let r = view.convert(rect, to: nil)
        let height = window?.contentView?.bounds.height ?? 0
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    func sidebarPoint(_ event: NSEvent) -> CGPoint {
        let p = event.locationInWindow
        return CGPoint(x: p.x, y: (window?.contentView?.bounds.height ?? 0) - p.y)
    }

    /// A press on a row moved far enough to be a drag: picks the row up.
    func beginDrag(_ model: SidebarRowModel, at start: CGPoint) {
        guard var row = model.dragRow else { return }
        if let index = rows.firstIndex(where: { $0.id == model.id }) {
            row.frame = dragRows().first { $0.key == row.key }?.frame ?? .zero
            _ = index
        }
        drag.begin([row.id], row: row, at: start, ghost: model.ghost, tileGhost: model.tileGhost(store.state))
    }

    func moveDrag(to point: CGPoint) {
        drag.move(to: point, in: store.state)
    }

    func endDrag(at point: CGPoint) {
        guard let drop = drag.end(at: point, in: store.state) else { return }
        actions.drop(drop.ids, drop.target)
    }
}

// MARK: - Row models

/// What one row shows. Equatable, so only rows whose model changed are touched.
enum SidebarRowModel: Equatable {
    struct Header: Equatable {
        var spaceID: UUID
        var name: String
        var icon: String
        var theme: Theme
        var hasPinned: Bool
        var pinnedCollapsed: Bool
        var isRenaming: Bool
    }

    struct Divider: Equatable {
        var spaceID: UUID
        var showsLine: Bool
        var canTidy: Bool
        var canClear: Bool
        var clearAction: TodayClearAction
        var isTidying: Bool
    }

    struct Tab: Equatable {
        var tab: BrowserTab
        var space: UUID
        var parent: UUID?
        var depth: Int
        var isPinned: Bool
        var isSelected: Bool
        var showsClose: Bool
        var isRenaming: Bool
        var aiRename: BrowserStore.AIRename?
        var canReset: Bool
        var isAudible: Bool
        var isMuted: Bool
        var isUnread: Bool
        /// In a live folder: a pull request shows GitHub's mark instead of its favicon.
        var liveIconTab: Bool
        var peek: LinkPeekBadge?
        var claudeControl: String?
        /// While Claude works here: the quiet line under the title, and the row's tooltip (the last few actions).
        var claudeActivity: String?
        var claudeActivityLog: String?
        var claudeNeedsYou: String?
        /// Claude is done here: a green dot, with what it did.
        var claudeDone: String?
        var splitSide: SplitDropSide?
        var groupHeader: TodayTabGroup?
    }

    struct Folder: Equatable {
        var folder: TabFolder
        var space: UUID
        var parent: UUID?
        var depth: Int
        var isRenaming: Bool
        var showsIntro: Bool
        var claudeActive: Bool
        var claudeNeedsYou: Int
    }

    struct Split: Equatable {
        struct Audio: Equatable { var audible: Bool; var muted: Bool }
        var split: SplitView
        var tabs: [BrowserTab]
        var space: UUID
        var parent: UUID?
        var depth: Int
        var isPinned: Bool
        var focusedID: UUID?
        var audio: [Audio]
        var optionHeld: Bool
        var groupHeader: TodayTabGroup?
    }

    case header(Header)
    case tab(Tab)
    case folder(Folder)
    case split(Split)
    case divider(Divider)
    case newTab(spaceID: UUID)
    case instantLinks(InstantLinks.Pending)

    var id: String {
        switch self {
        case .header(let h): "header-\(h.spaceID)"
        case .tab(let t): t.tab.id.uuidString
        case .folder(let f): f.folder.id.uuidString
        case .split(let s): s.split.id.uuidString
        case .divider(let d): "divider-\(d.spaceID)"
        case .newTab(let space): "newTab-\(space)"
        case .instantLinks(let p): "instant-\(p.id)"
        }
    }

    private typealias M = ArcMetrics.Sidebar

    /// A Tidy Tabs header riding on the row, and its height.
    var headerHeight: CGFloat {
        switch self {
        case .tab(let t) where t.groupHeader != nil: M.dividerRowHeight
        case .split(let s) where s.groupHeader != nil: M.dividerRowHeight
        default: 0
        }
    }

    /// Pills sit 41pt apart, centred in their row, like Arc's.
    var isPill: Bool {
        switch self {
        case .header, .divider: false
        default: true
        }
    }

    var height: CGFloat {
        switch self {
        case .header: M.headerHeight + M.listTopSpacer
        case .divider: M.dividerRowHeight
        default: M.rowPitch + headerHeight
        }
    }

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .tab(let t): t.tab.id == id
        case .folder(let f): f.folder.id == id
        case .split(let s): s.split.id == id || s.split.tabIDs.contains(id)
        default: false
        }
    }

    /// The row as the drag model sees it; nil for rows a drop can't aim at.
    var dragRow: SidebarDragModel.Row? {
        switch self {
        case .header(let h):
            .init(id: h.spaceID, kind: .header, space: h.spaceID, pinned: true, folder: nil, depth: 0, frame: .zero)
        case .divider(let d):
            .init(id: d.spaceID, kind: .divider, space: d.spaceID, pinned: true, folder: nil, depth: 0, frame: .zero)
        case .newTab(let space):
            .init(id: space, kind: .newTab, space: space, pinned: false, folder: nil, depth: 0, frame: .zero)
        case .tab(let t):
            .init(id: t.tab.id, kind: .tab, space: t.space, pinned: t.isPinned, folder: t.parent, depth: t.depth, frame: .zero)
        case .folder(let f):
            .init(id: f.folder.id, kind: .folder(expanded: f.folder.isExpanded), space: f.space, pinned: true,
                  folder: f.parent, depth: f.depth, frame: .zero)
        case .split(let s):
            .init(id: s.split.id, kind: .split, space: s.space, pinned: s.isPinned, folder: s.parent, depth: s.depth,
                  frame: .zero, members: s.split.tabIDs)
        case .instantLinks:
            nil
        }
    }

    /// Whether a press on the row can pick it up.
    var isDraggable: Bool {
        switch self {
        case .tab, .folder, .split: true
        default: false
        }
    }

    @MainActor var ghost: AnyView {
        switch self {
        case .tab(let t): AnyView(DragGhost(icon: .tabs([t.tab]), title: t.tab.displayTitle, depth: t.depth))
        case .folder(let f): AnyView(DragGhost(icon: .symbol("folder.fill"), title: f.folder.name, depth: f.depth))
        case .split(let s): AnyView(DragGhost(icon: .tabs(s.tabs), title: "", depth: s.depth))
        default: AnyView(EmptyView())
        }
    }

    /// Arc swaps a tab's drag image for a favorite tile, the size of the tray's open slot, once
    /// it's over the tray (`collectionView:updateDraggingItemsForDrag:`, decompiled).
    @MainActor func tileGhost(_ state: BrowserState) -> AnyView? {
        switch self {
        case .tab(let t): AnyView(FavoriteGhost(tabs: [t.tab]))
        case .split(let s): s.tabs.isEmpty ? nil : AnyView(FavoriteGhost(tabs: s.tabs))
        default: nil
        }
    }
}

// MARK: - Table plumbing

extension SidebarSpaceList: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < rows.count ? rows[row].height : M.rowPitch
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SidebarRowView")
        return tableView.makeView(withIdentifier: id, owner: nil) as? SidebarTableRowView ?? {
            let view = SidebarTableRowView()
            view.identifier = id
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let model = rows[row]
        let id = NSUserInterfaceItemIdentifier(model.cellKind)
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarRowCell ?? SidebarRowCell.make(kind: model.cellKind)
        cell.identifier = id
        cell.configure(model, list: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

extension SidebarRowModel {
    /// Rows of the same kind reuse each other's views.
    var cellKind: String {
        switch self {
        case .header: "header"
        case .tab: "tab"
        case .folder: "folder"
        case .split: "split"
        case .divider: "divider"
        case .newTab: "newTab"
        case .instantLinks: "instantLinks"
        }
    }
}

/// The table under the sidebar's rows. Rows draw their own pills; the table draws nothing.
final class SidebarTableView: NSTableView {
    weak var list: SidebarSpaceList?

    override var mouseDownCanMoveWindow: Bool { false }
    override func drawBackground(inClipRect clipRect: NSRect) {}
    override func drawGrid(inClipRect clipRect: NSRect) {}
    override var acceptsFirstResponder: Bool { false }
    // Rows handle their own presses; the table never selects or tracks.
    override func mouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// A row with nothing of its own: no selection, separators or group styling.
final class SidebarTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
    override var isOpaque: Bool { false }
    // The gaps between pills belong to the row, as they did to the SwiftUI list's cell: a press there
    // never moves the window and lands nowhere.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let view = super.hitTest(point) else { return nil }
        return view is SidebarRowCell || view.isDescendant(of: self) && view.enclosingRowCell != nil ? view : self
    }
}

private extension NSView {
    var enclosingRowCell: SidebarRowCell? {
        var view: NSView? = self
        while let v = view, !(v is SidebarRowCell) { view = v.superview }
        return view as? SidebarRowCell
    }
}

/// The list's scroll view: no scrollers (scrolling still works), like the SwiftUI list's
/// `.scrollIndicators(.never)`.
final class SidebarListScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}

extension NSEvent.ModifierFlags {
    var chordModifiers: KeyChord.Modifiers {
        var m: KeyChord.Modifiers = []
        if contains(.option) { m.insert(.alt) }
        if contains(.control) { m.insert(.control) }
        if contains(.command) { m.insert(.meta) }
        if contains(.shift) { m.insert(.shift) }
        return m
    }
}
