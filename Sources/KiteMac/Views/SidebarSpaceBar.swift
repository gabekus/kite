import AppKit
import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

/// The sidebar's bottom bar (SwiftUI's `SpaceBar`): Arc's Library button at the leading end (carrying download
/// progress), the spaces centred in the room between the end buttons (scrolling when they don't fit), and the
/// + menu at the trailing end. Arc's cells are 36×34 on a 34pt pitch; the space you're in shows its icon in
/// colour, others greyed (or a dot when they have no icon), each lit by its share of the sidebar while the
/// pages slide. A space icon drags to a new place in the strip.
@MainActor
final class SpaceBarView: SidebarFlippedView {
    private let store: BrowserStore
    private let actions: SidebarActions
    private let swipe: SpaceSwipeModel
    private let drag: SidebarDragModel
    private let library: LibraryModel

    private let libraryButton: LibraryButtonView
    private let plus = SymbolButton(symbol: "plus", pointSize: 15, label: "New…")
    private let scroll = NSScrollView()
    private let strip = SidebarFlippedView()
    private var cells: [UUID: SpaceCellView] = [:]
    private var order: [UUID] = []
    private let ghost = SpaceCellView()
    private var reorder: Reorder?
    private var updateScheduled = false

    /// A space icon on its way to a new place in the strip.
    private struct Reorder {
        var id: UUID
        /// Where the pointer went down, and where it is (bar points).
        var start: CGPoint
        var location: CGPoint
        /// The centre of the icon's cell when it was picked up.
        var pickedUp: CGPoint
        /// The open slot, nil while the pointer is off the strip.
        var target: Int?
        /// Once dropped: settling into its slot.
        var landing = false
    }

    /// The bar's spacing between its buttons and the strip.
    private static let buttonGap: CGFloat = 4
    /// Unverified: Arc's collection view animates the slide and the landing; its duration isn't measured.
    private static let slide: TimeInterval = 0.2

    init(store: BrowserStore, actions: SidebarActions, swipe: SpaceSwipeModel, drag: SidebarDragModel, library: LibraryModel) {
        self.store = store
        self.actions = actions
        self.swipe = swipe
        self.drag = drag
        self.library = library
        libraryButton = LibraryButtonView(library: library)
        super.init(frame: .zero)
        addSubview(libraryButton)
        plus.opacity = 0.7
        plus.toolTip = "New…"
        plus.action = { [weak self] in
            guard let self else { return }
            NewItemMenu.present(from: self.plus, store: self.store, actions: self.actions)
        }
        addSubview(plus)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        ghost.isGhost = true
        ghost.isHidden = true
        addSubview(ghost)
        update()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Observing

    private func update() {
        withObservationTracking { apply() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
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

    private func apply() {
        let state = store.state
        // On Create a Space Arc leaves only the spaces in the bar.
        let creating = store.spaceCreation != nil
        libraryButton.alphaValue = creating ? 0 : 1
        plus.isHidden = creating
        libraryButton.isEnabled = !creating
        let ids = state.spaces.map(\.id)
        let reshaped = ids != order || creating != wasCreating
        wasCreating = creating
        for id in cells.keys where !ids.contains(id) {
            cells[id]?.removeFromSuperview()
            cells[id] = nil
            drag.reportSpaceIcon(id, frame: nil)
            SpaceTipWindow.shared.hide(id)
        }
        order = ids
        let selected = state.selectedSpaceIndex
        let built = SpaceSwipe.builtPages(selected: selected, anchor: swipe.anchor.flatMap(state.spaceIndex), count: state.spaces.count)
        for (index, space) in state.spaces.enumerated() {
            let cell = cells[space.id] ?? {
                let cell = SpaceCellView()
                cell.bar = self
                strip.addSubview(cell)
                cells[space.id] = cell
                return cell
            }()
            let lit = SpaceSwipe.highlight(of: index, selected: selected, built: built, offset: Double(swipe.offset),
                                           pageWidth: Double(swipe.pageWidth))
            cell.show(space: space, number: index + 1, lit: lit, isSelected: space.id == state.selectedSpaceID,
                      profileName: actions.showsProfiles ? state.profile(space.profile).name : nil,
                      dragging: reorder != nil)
        }
        // A swipe's frame only relights the icons; the bar lays out again only when its spaces change.
        if reshaped { needsLayout = true }
    }

    private var wasCreating = false

    // MARK: Layout

    private var room: CGRect {
        let size = M.bottomButtonSize
        let minX = M.padding + size + Self.buttonGap
        let maxX = bounds.width - M.padding - size - Self.buttonGap
        return CGRect(x: minX, y: 0, width: max(maxX - minX, 0), height: bounds.height)
    }

    private func stripWidth(slots: Int) -> CGFloat {
        CGFloat(SpaceReorder.width(slots: slots, pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width))
    }

    private var fits: Bool { stripWidth(slots: order.count) <= room.width }

    /// Where the strip's first cell starts when it has `slots` cells: centred in the room, or from the scroll
    /// view's leading edge when the spaces overflow it.
    private func stripMinX(slots: Int) -> CGFloat {
        guard fits else { return room.minX - scroll.contentView.bounds.minX }
        return room.midX - stripWidth(slots: slots) / 2
    }

    override func layout() {
        super.layout()
        let size = M.bottomButtonSize
        let y = (bounds.height - size) / 2
        libraryButton.frame = CGRect(x: M.padding, y: y, width: size, height: size)
        plus.frame = CGRect(x: bounds.width - M.padding - size, y: y, width: size, height: size)
        let width = stripWidth(slots: order.count)
        let cellY = (bounds.height - M.spaceCellSize.height) / 2
        if fits {
            scroll.frame = CGRect(x: room.midX - width / 2, y: cellY, width: width, height: M.spaceCellSize.height)
        } else {
            scroll.frame = CGRect(x: room.minX, y: cellY, width: room.width, height: M.spaceCellSize.height)
        }
        strip.frame = CGRect(x: 0, y: 0, width: width, height: M.spaceCellSize.height)
        placeCells(animated: false)
        reportFrames()
    }

    private func placeCells(animated: Bool) {
        let slots: [UUID?] = reorder.map { SpaceReorder.slots(order, dragging: $0.id, target: $0.target) } ?? order
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.slide : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = animated
            for id in order {
                guard let cell = cells[id] else { continue }
                let slot = slots.firstIndex(of: id) ?? slots.firstIndex(of: nil) ?? max(slots.count - 1, 0)
                let frame = CGRect(x: CGFloat(slot) * M.spaceCellPitch, y: 0, width: M.spaceCellSize.width, height: M.spaceCellSize.height)
                if animated { cell.animator().frame = frame } else { cell.frame = frame }
            }
        }
        // While an icon is dragged it leaves its cell (kept, invisible) at once, not fading out under the ghost.
        for (id, cell) in cells { cell.alphaValue = reorder?.id == id ? 0 : 1 }
    }

    /// The icons' frames, for tabs dropped onto a space (sidebar points).
    private func reportFrames() {
        guard let window else { return }
        let height = window.contentView?.bounds.height ?? 0
        for (id, cell) in cells {
            let r = cell.convert(cell.bounds, to: nil)
            drag.reportSpaceIcon(id, frame: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
        }
    }

    // MARK: Reordering

    /// The centre of slot `index` in a strip of `slots` cells (bar points).
    private func slotCenter(_ index: Int, slots: Int) -> CGPoint {
        CGPoint(x: stripMinX(slots: slots) + M.spaceCellSize.width / 2 + CGFloat(index) * M.spaceCellPitch, y: bounds.midY)
    }

    /// Arc's dock takes the drop anywhere over the strip's scroll view, which spans the bar's height between its
    /// end buttons; off it the open slot closes.
    private func target(at point: CGPoint) -> Int? {
        guard room.contains(point) else { return nil }
        let count = order.count
        return SpaceReorder.dropIndex(pointerX: point.x, stripMinX: stripMinX(slots: count), count: count,
                                      pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width)
    }

    func cellDragged(_ cell: SpaceCellView, event: NSEvent, start: CGPoint) {
        guard order.count > 1, let id = cells.first(where: { $0.value === cell })?.key, let index = order.firstIndex(of: id),
              reorder?.landing != true else { return }
        let point = convert(event.locationInWindow, from: nil)
        if reorder == nil {
            // Picked up where it sat: its open slot is its own until the pointer says otherwise.
            reorder = Reorder(id: id, start: start, location: point, pickedUp: slotCenter(index, slots: order.count), target: index)
            for cell in cells.values { cell.setDragging(true) }
            ghost.copy(from: cell)
            ghost.isHidden = false
            placeCells(animated: false)
        }
        reorder?.location = point
        placeGhost()
        let aim = target(at: point)
        if aim != reorder?.target {
            reorder?.target = aim
            placeCells(animated: true)
        }
    }

    func cellDragEnded(_ cell: SpaceCellView, event: NSEvent) {
        guard var moving = reorder, !moving.landing else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Dropped off the strip: back to where it came from (unverified in Arc: a refused `NSDraggingSession`
        // drop slides its image home).
        let slot = target(at: point) ?? order.firstIndex(of: moving.id) ?? 0
        moving.landing = true
        moving.target = slot
        reorder = moving
        let landing = slotCenter(slot, slots: order.count)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slide
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            placeCells(animated: true)
            ghost.animator().frame = ghostFrame(center: landing)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.store.state.spaceIndex(moving.id) != slot {
                    self.store.mutate { $0.moveSpace(moving.id, to: slot) }
                }
                self.reorder = nil
                self.ghost.isHidden = true
                // The new order now, not on the observer's next turn: placed in the old order until then, every
                // icon showed back in its old slot for a frame.
                self.apply()
                self.placeCells(animated: false)
            }
        }
    }

    private func ghostFrame(center: CGPoint) -> CGRect {
        CGRect(x: center.x - M.spaceCellSize.width / 2, y: center.y - M.spaceCellSize.height / 2,
               width: M.spaceCellSize.width, height: M.spaceCellSize.height)
    }

    /// The dragged icon follows the pointer from where it was picked up.
    private func placeGhost() {
        guard let r = reorder else { return }
        ghost.frame = ghostFrame(center: CGPoint(x: r.pickedUp.x + r.location.x - r.start.x, y: r.pickedUp.y + r.location.y - r.start.y))
    }

    func select(_ cell: SpaceCellView) {
        guard let id = cells.first(where: { $0.value === cell })?.key else { return }
        store.mutate { $0.selectSpace(id) }
    }

    func menu(for cell: SpaceCellView) -> NSMenu? {
        guard let id = cells.first(where: { $0.value === cell })?.key else { return nil }
        return SpaceContextMenus.menu(store: store, actions: actions, spaceID: id)
    }
}

/// One space in the strip (SwiftUI's `SpaceCell` and `SpaceCellIcon`): the icon crossfading from grey to colour
/// as its space comes in, or a dot for an icon-less space; under the pointer a rounded backing (not for the
/// space you're in) and, after a moment, Arc's tip above it with the space's name, profile and ⌃-number.
@MainActor
final class SpaceCellView: SidebarFlippedView {
    weak var bar: SpaceBarView?
    var isGhost = false { didSet { backing.isHidden = !isGhost } }
    private let backing = FillView()
    private let greyIcon = SpaceIconImageView()
    private let icon = SpaceIconImageView()
    private let dot = FillView()
    private var space: Space?
    private var number = 1
    private var profileName: String?
    private var isSelected = false
    private var hovering = false
    private var dragging = false
    private var tracking: NSTrackingArea?
    private var pressStart: CGPoint?
    private var dragged = false
    private var tipWork: DispatchWorkItem?
    private var dotLit: Double = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        backing.cornerRadius = 8
        backing.fill = { _ in NSColor.labelColor.withAlphaComponent(0.08) }
        backing.isHidden = true
        addSubview(backing)
        greyIcon.size = M.spaceIconFontSize
        greyIcon.greyed = true
        icon.size = M.spaceIconFontSize
        addSubview(greyIcon)
        addSubview(icon)
        dot.cornerRadius = M.spaceDotSize / 2
        addSubview(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func show(space: Space, number: Int, lit: Double, isSelected: Bool, profileName: String?, dragging: Bool) {
        self.space = space
        self.number = number
        self.profileName = profileName
        self.isSelected = isSelected
        setAccessibilityLabel(space.name)
        let hasIcon = !space.icon.isEmpty
        greyIcon.isHidden = !hasIcon
        icon.isHidden = !hasIcon
        dot.isHidden = hasIcon
        if hasIcon {
            greyIcon.show(icon: space.icon, theme: space.theme)
            icon.show(icon: space.icon, theme: space.theme)
            greyIcon.alphaValue = CGFloat(1 - lit)
            icon.alphaValue = CGFloat(lit)
        } else if lit != dotLit {
            dotLit = lit
            let opacity = M.spaceDotOpacity + (1 - M.spaceDotOpacity) * lit
            dot.fill = { _ in NSColor.labelColor.withAlphaComponent(opacity) }
        }
        if dragging != self.dragging { setDragging(dragging) }
    }

    /// The ghost shows what the dragged cell shows, with its backing.
    func copy(from cell: SpaceCellView) {
        guard let space = cell.space else { return }
        show(space: space, number: cell.number, lit: Double(cell.icon.isHidden ? 1 : cell.icon.alphaValue), isSelected: cell.isSelected,
             profileName: cell.profileName, dragging: true)
        backing.isHidden = false
    }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        if dragging, let space { SpaceTipWindow.shared.hide(space.id) }
        updateBacking()
    }

    private func updateBacking() {
        guard !isGhost else { return }
        backing.isHidden = !(hovering && !dragging && !isSelected)
    }

    override func layout() {
        super.layout()
        let b = M.bottomButtonSize
        backing.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
        greyIcon.frame = bounds
        icon.frame = bounds
        let d = M.spaceDotSize
        dot.frame = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isGhost ? nil : super.hitTest(point).map { _ in self } }

    // MARK: Hover, tip and presses

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !isGhost else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateBacking()
        tipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, !self.dragging, let space = self.space, self.window != nil else { return }
            SpaceTipWindow.shared.show(SpaceTip(space: space, number: self.number, profileName: self.profileName),
                                       for: space.id, above: self, gap: M.spaceTipGap)
        }
        tipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + M.spaceTipDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateBacking()
        tipWork?.cancel()
        if let space { SpaceTipWindow.shared.hide(space.id) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let space { SpaceTipWindow.shared.hide(space.id) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        pressStart = bar.map { $0.convert(event.locationInWindow, from: nil) }
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bar, let start = pressStart else { return }
        let point = bar.convert(event.locationInWindow, from: nil)
        if !dragged {
            // SwiftUI's DragGesture(minimumDistance: 4).
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragged = true
        }
        bar.cellDragged(self, event: event, start: start)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil; dragged = false }
        if dragged { return bar?.cellDragEnded(self, event: event) ?? () }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { bar?.select(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        bar?.select(self)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = bar?.menu(for: self) else { return }
        showSidebarMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: self) }
}

/// Arc's Library button (`HomeBadging.HomeButton`, tooltip "Library"): Kite's archivebox at 15pt, 70%. While
/// files download, Arc's `DownloadProgressBadge` (still SwiftUI, hosted only then) sits on it.
@MainActor
final class LibraryButtonView: SidebarFlippedView {
    private let library: LibraryModel
    private let icon = SymbolButton(symbol: "archivebox", pointSize: 15, label: "Library")
    private let badge: PassthroughHost<LibraryBadge>
    var isEnabled = true { didSet { icon.isEnabled = isEnabled } }

    init(library: LibraryModel) {
        self.library = library
        badge = PassthroughHost(rootView: LibraryBadge())
        super.init(frame: .zero)
        icon.opacity = 0.7
        icon.disabledOpacity = 0.7
        icon.toolTip = "Library"
        icon.action = { library.toggle() }
        addSubview(icon)
        badge.sizingOptions = []
        addSubview(badge)
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
        badge.frame = bounds
    }
}

/// A SwiftUI view drawn over AppKit controls that takes no clicks itself.
final class PassthroughHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
