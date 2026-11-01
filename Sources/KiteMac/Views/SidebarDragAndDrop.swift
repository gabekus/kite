import AppKit
import KiteCore
import SwiftUI

/// Dragging tabs, folders, splits and favorites around the sidebar, after Arc's tab list
/// (an `NSOutlineView` with `SidebarDropType` before / after / on drops and a white insertion
/// line) and its favorites tray (`AppTray`, shown while dragging even when empty).
///
/// Rows report their frames in the sidebar's coordinate space; a drag works out its
/// `SidebarDropTarget` from those frames, and the overlay draws the dragged row and the
/// insertion line. The drag is SwiftUI's own (not an `NSDraggingSession`), so it works with
/// synthetic events from `kite ui input` and never leaves the window.
@MainActor
@Observable
final class SidebarDragModel {

    struct Row: Equatable {
        enum Kind: Equatable {
            case tab
            case split
            case folder(expanded: Bool)
            /// The space's name above its pinned items: drops go to the top of the pinned section.
            case header
            /// The line between pinned and Today: above it ends the pinned section, below starts Today.
            case divider
            case newTab
        }

        /// The drag ID: a tab, a folder or a split. Header, divider and New Tab rows use their space's ID.
        var id: UUID
        var kind: Kind
        var space: UUID
        var pinned: Bool
        /// The folder the row is in, nil at the top level.
        var folder: UUID?
        var depth: Int
        var frame: CGRect
        /// A split row's panes, so a gap named by its first pane finds the row.
        var members: [UUID] = []

        var key: String {
            switch kind {
            case .tab, .split, .folder: id.uuidString
            case .header: "header-\(space)"
            case .divider: "divider-\(space)"
            case .newTab: "newTab-\(space)"
            }
        }
    }

    struct Session: Equatable {
        var ids: [UUID]
        var row: Row
        /// Where the pointer went down, and where it is now (sidebar points).
        var start: CGPoint
        var location: CGPoint
        var target: SidebarDropTarget?
        /// A tab row the pointer rests on, and since when: after `splitDelay` it offers a split.
        var hover: (id: UUID, since: Date)?

        static func == (a: Session, b: Session) -> Bool {
            a.ids == b.ids && a.start == b.start && a.location == b.location && a.target == b.target && a.hover?.id == b.hover?.id
        }
    }

    private(set) var rows: [String: Row] = [:]
    private(set) var tiles: [UUID: CGRect] = [:]
    var favoritesArea: CGRect?
    /// The favorites tray's open slot while a drag aims at it (Arc's `dropGapFrame`).
    var dropGap: CGRect?
    private(set) var spaceIcons: [UUID: CGRect] = [:]
    var bounds: CGRect = .zero
    private(set) var session: Session?
    /// The ghost for the session: the row as it was when picked up.
    private(set) var ghost: AnyView?

    /// How long a tab row has to be the drop target before the drop offers a split. Arc 1.169's
    /// `splitDropTargetDelaySatisfied` turns on 0.2s after the row becomes the target (binary).
    static let splitDelay: TimeInterval = 0.2
    /// Arc's `TablistEdgeDragController` (binary): a drag resting within 20pt of the tab list's left
    /// or right edge for 0.35s (`switchThreshold`, one-shot, restarted by a move over 3pt) pages
    /// to the space on that side, once per rest.
    static let edgeZone: CGFloat = 20
    static let edgeDwell: TimeInterval = 0.35
    static let edgeSlop: CGFloat = 3

    /// The window's store, for timers that re-aim a drag without a pointer move.
    weak var store: BrowserStore?
    private var edgeTimer: Timer?
    private var edgeArmedAt: CGPoint?
    private var splitTimer: Timer?

    var isDragging: Bool { session != nil }

    func report(_ row: Row) {
        if rows[row.key] != row { rows[row.key] = row }
    }

    func forget(_ row: Row) { rows[row.key] = nil }

    private func row(_ id: UUID) -> Row? {
        rows[id.uuidString] ?? rows.values.first { $0.members.contains(id) }
    }

    func reportTile(_ id: UUID, frame: CGRect?) {
        if tiles[id] != frame { tiles[id] = frame }
    }

    func reportSpaceIcon(_ id: UUID, frame: CGRect?) {
        if spaceIcons[id] != frame { spaceIcons[id] = frame }
    }

    func begin(_ ids: [UUID], row: Row, at start: CGPoint, ghost: AnyView) {
        session = Session(ids: ids, row: row, start: start, location: start)
        self.ghost = ghost
    }

    func move(to location: CGPoint, in state: BrowserState) {
        guard var session else { return }
        session.location = location
        let resolved = resolve(location, session: &session, state: state)
        session.target = resolved.flatMap { state.canDrop(session.ids, on: $0) ? $0 : nil }
        self.session = session
        lastState = state
        updateAutoscroll()
        updateEdgeSwitch()
        // A split offer comes due with the pointer at rest: aim again then.
        if let hover = self.session?.hover, splitTimer == nil {
            let due = Self.splitDelay - Date().timeIntervalSince(hover.since)
            splitTimer = Timer.scheduledTimer(withTimeInterval: max(due, 0) + 0.01, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.splitTimer = nil
                    if let session = self.session, let store = self.store { self.move(to: session.location, in: store.state) }
                }
            }
        }
    }

    private func updateEdgeSwitch() {
        guard let session, let list = listFrame,
              session.location.y >= list.minY, session.location.y <= list.maxY,
              session.location.x - list.minX < Self.edgeZone || list.maxX - session.location.x < Self.edgeZone,
              bounds.contains(session.location) else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            edgeArmedAt = nil
            return
        }
        if let armed = edgeArmedAt, hypot(armed.x - session.location.x, armed.y - session.location.y) <= Self.edgeSlop { return }
        edgeArmedAt = session.location
        edgeTimer?.invalidate()
        edgeTimer = Timer.scheduledTimer(withTimeInterval: Self.edgeDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, let store = self.store, let list = self.listFrame else { return }
                self.edgeTimer = nil
                let offset = session.location.x < list.midX ? -1 : 1
                withAnimation(.spring(response: ArcMetrics.Motion.spaceSwitchResponse, dampingFraction: ArcMetrics.Motion.spaceSwitchDamping)) {
                    store.mutate { $0.selectAdjacentSpace(offset: offset) }
                }
                self.move(to: session.location, in: store.state)
            }
        }
    }

    /// The tab list's frame in sidebar points.
    var listFrame: CGRect? {
        guard let scrollView, let content = scrollView.window?.contentView else { return nil }
        // SwiftUI's global space: window points from the content view's top-left.
        let r = scrollView.convert(scrollView.bounds, to: nil)
        return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Scrolling the list while dragging

    /// The space's list, found from inside one of its rows. Like NSTableView's own drags, a drag
    /// held near the list's top or bottom edge scrolls it.
    weak var scrollView: NSScrollView?
    private var autoscroll: Timer?
    private var lastState: BrowserState?
    /// Unverified: AppKit's autoscroll zone and speed, which Arc's outline view would use.
    static let autoscrollZone: CGFloat = 24
    static let autoscrollSpeed: CGFloat = 600

    private func autoscrollStep() -> CGFloat {
        guard let session, let frame = listFrame else { return 0 }
        let y = session.location.y
        guard session.location.x >= frame.minX, session.location.x <= frame.maxX else { return 0 }
        let top = frame.minY + Self.autoscrollZone - y, bottom = y - (frame.maxY - Self.autoscrollZone)
        if top > 0, y > frame.minY - Self.autoscrollZone { return -min(top, Self.autoscrollZone) / Self.autoscrollZone }
        if bottom > 0, y < frame.maxY + Self.autoscrollZone { return min(bottom, Self.autoscrollZone) / Self.autoscrollZone }
        return 0
    }

    /// The sidebar's hosting view, whose flipped coordinates are sidebar points.
    weak var sidebarView: NSView?

    private func updateAutoscroll() {
        let wanted = session != nil && autoscrollStep() != 0
        if wanted, autoscroll == nil {
            autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickAutoscroll() }
            }
        } else if !wanted {
            autoscroll?.invalidate()
            autoscroll = nil
        }
    }

    private func tickAutoscroll() {
        let step = autoscrollStep()
        guard step != 0, let scrollView, let session, let state = lastState else { return updateAutoscroll() }
        let clip = scrollView.contentView
        let maxY = max((scrollView.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + step * Self.autoscrollSpeed / 60, 0), maxY)
        guard origin.y != clip.bounds.origin.y else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        // Rows report their new frames on the next pass; aim again then.
        DispatchQueue.main.async { [weak self] in self?.move(to: session.location, in: state) }
    }

    /// Ends the drag: the drop to make, if any.
    func end(at location: CGPoint, in state: BrowserState) -> (ids: [UUID], target: SidebarDropTarget)? {
        move(to: location, in: state)
        defer {
            session = nil
            ghost = nil
            updateAutoscroll()
            updateEdgeSwitch()
        }
        guard let session, let target = session.target else { return nil }
        return (session.ids, target)
    }

    func cancel() {
        session = nil
        ghost = nil
        updateAutoscroll()
        updateEdgeSwitch()
    }

    // MARK: Where a drop lands

    private func resolve(_ p: CGPoint, session: inout Session, state: BrowserState) -> SidebarDropTarget? {
        guard bounds.insetBy(dx: -1, dy: -1).contains(p) else {
            session.hover = nil
            return nil
        }
        if let (id, _) = spaceIcons.first(where: { $0.value.insetBy(dx: -2, dy: -2).contains(p) }) {
            session.hover = nil
            return .space(id)
        }
        if let area = favoritesArea, area.insetBy(dx: 0, dy: -ArcMetrics.Sidebar.favoritesBottomGap / 2).contains(p) {
            session.hover = nil
            return favoritesTarget(at: p, state: state)
        }
        let space = state.selectedSpaceID
        let list = rows.values.filter { $0.space == space }.sorted { $0.frame.minY < $1.frame.minY }
        guard !list.isEmpty else { return nil }
        // The row whose band (its pill plus half the gap either side) holds the pointer, or the nearest.
        let row = list.min { abs($0.frame.midY - p.y) < abs($1.frame.midY - p.y) }!
        let fraction = (p.y - row.frame.minY) / max(row.frame.height, 1)

        if row.kind != .tab { session.hover = nil }
        switch row.kind {
        case .header:
            return .pinned(space: space, folder: nil, before: state.selectedSpace.pinnedItems.first?.id)
        case .divider:
            return fraction < 0.5
                ? .pinned(space: space, folder: nil, before: nil)
                : .unpinned(space: space, before: state.selectedSpace.tabs.first?.id)
        case .newTab:
            return .unpinned(space: space, before: state.selectedSpace.tabs.first?.id)
        case .folder(let expanded):
            if fraction < 0.25 { return before(row) }
            if fraction > 0.75 {
                if expanded, let first = state.selectedSpace.pinnedItems.folder(row.id)?.items.first {
                    return .pinned(space: space, folder: row.id, before: first.id)
                }
                return after(row, state: state)
            }
            return .folder(row.id)
        case .tab, .split:
            if row.kind == .tab, fraction >= 0.25, fraction <= 0.75, !session.ids.contains(row.id) {
                if session.hover?.id != row.id { session.hover = (row.id, Date()) }
                if let hover = session.hover, Date().timeIntervalSince(hover.since) >= Self.splitDelay {
                    return .split(with: row.id, side: p.x < row.frame.midX ? .left : .right)
                }
            } else {
                session.hover = nil
            }
            return fraction < 0.5 ? before(row) : after(row, state: state)
        }
    }

    private func before(_ row: Row) -> SidebarDropTarget {
        let anchor = row.id
        return row.pinned
            ? .pinned(space: row.space, folder: row.folder, before: anchor)
            : .unpinned(space: row.space, before: anchor)
    }

    /// The gap after a row: before the next item at its level.
    private func after(_ row: Row, state: BrowserState) -> SidebarDropTarget {
        guard let s = state.spaceIndex(row.space) else { return before(row) }
        let space = state.spaces[s]
        if row.pinned {
            let level = row.folder.flatMap { space.pinnedItems.folder($0)?.items } ?? space.pinnedItems
            return .pinned(space: row.space, folder: row.folder, before: next(after: row.id, in: level.map(\.id), splits: space.splits))
        }
        return .unpinned(space: row.space, before: next(after: row.id, in: space.tabs.map(\.id), splits: space.splits))
    }

    /// The item after `id` (a tab, folder or split) in a list, skipping a split's other panes.
    private func next(after id: UUID, in ids: [UUID], splits: [SplitView]) -> UUID? {
        let members = splits.first { $0.id == id || $0.tabIDs.contains(id) }?.tabIDs ?? [id]
        guard let last = ids.lastIndex(where: { members.contains($0) }), last + 1 < ids.count else { return nil }
        return ids[last + 1]
    }

    private func favoritesTarget(at p: CGPoint, state: BrowserState) -> SidebarDropTarget {
        // Over the open gap: it stays where it is, or the tiles it pushed aside would chase the pointer.
        if let gap = dropGap, gap.contains(p), case .favorites? = session?.target, let target = session?.target { return target }
        let order = state.favorites.map(\.id)
        // The tile under the pointer, or the nearest on its row; its right half means after it.
        let candidates = order.compactMap { id in tiles[id].map { (id, $0) } }
        guard let (id, frame) = candidates.min(by: { distance(p, $0.1) < distance(p, $1.1) }) else {
            return .favorites(before: nil)
        }
        if p.x < frame.midX { return .favorites(before: id) }
        let i = order.firstIndex(of: id)!
        return .favorites(before: i + 1 < order.count ? order[i + 1] : nil)
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    // MARK: Drawing

    /// The insertion line for the current target: y, leading x and width, in sidebar points.
    var insertionLine: (y: CGFloat, x: CGFloat, width: CGFloat)? {
        guard let session, let target = session.target else { return nil }
        let gap = (ArcMetrics.Sidebar.rowPitch - ArcMetrics.Sidebar.pillHeight) / 2
        func line(before anchor: UUID?, space: UUID, pinned: Bool, folder: UUID?) -> (CGFloat, CGFloat, CGFloat)? {
            let level = rows.values.filter { $0.space == space && $0.pinned == pinned && $0.folder == folder && ($0.kind == .tab || $0.kind == .split || isFolder($0.kind)) }
            if let anchor, let row = row(anchor) {
                return (row.frame.minY - gap, row.frame.minX + Self.lineInset + indent(row.depth), row.frame.width - Self.lineInset - Self.lineEndInset - indent(row.depth))
            }
            // The end of a level: under its last row, or under the folder's row when it's empty.
            if let last = level.max(by: { $0.frame.maxY < $1.frame.maxY }) {
                let bottom = folder.flatMap { f in rows.values.filter { descends($0, from: f) }.map(\.frame.maxY).max() } ?? last.frame.maxY
                return (max(bottom, last.frame.maxY) + gap, last.frame.minX + Self.lineInset + indent(last.depth), last.frame.width - Self.lineInset - Self.lineEndInset - indent(last.depth))
            }
            if let folder, let row = row(folder) {
                return (row.frame.maxY + gap, row.frame.minX + Self.lineInset + indent(row.depth + 1), row.frame.width - Self.lineInset - Self.lineEndInset - indent(row.depth + 1))
            }
            // An empty section: at the divider (pinned) or under New Tab (Today).
            let marker = rows.values.first { $0.space == space && $0.kind == (pinned ? .divider : .newTab) }
            return marker.map { (pinned ? $0.frame.midY : $0.frame.maxY + gap, $0.frame.minX + Self.lineInset, $0.frame.width - Self.lineInset - Self.lineEndInset) }
        }
        let result: (CGFloat, CGFloat, CGFloat)?
        switch target {
        case .pinned(let space, let folder, let before): result = line(before: before, space: space, pinned: true, folder: folder)
        case .unpinned(let space, let before): result = line(before: before, space: space, pinned: false, folder: nil)
        default: result = nil
        }
        return result.map { (y: $0.0, x: $0.1, width: $0.2) }
    }

    /// A folder, split or space icon the drop goes on.
    var highlightedRow: CGRect? {
        guard let session, let target = session.target else { return nil }
        switch target {
        case .folder(let id): return row(id)?.frame
        case .space(let id): return spaceIcons[id]
        default: return nil
        }
    }

    /// The side a drop would split this tab on, while it would.
    func splitSide(for id: UUID) -> SplitDropSide? {
        guard let session, case .split(let target, let side) = session.target, target == id else { return nil }
        return side
    }

    /// Arc's line starts 8pt inside the row and stops 3.5pt short of its end.
    static let lineInset: CGFloat = 8
    static let lineEndInset: CGFloat = 3.5

    private func isFolder(_ kind: Row.Kind) -> Bool {
        if case .folder = kind { true } else { false }
    }

    private func descends(_ item: Row, from folder: UUID) -> Bool {
        var parent = item.folder
        while let p = parent {
            if p == folder { return true }
            parent = row(p)?.folder
        }
        return false
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * ArcMetrics.Sidebar.nestingIndent }
}

extension EnvironmentValues {
    @Entry var sidebarDrag: SidebarDragModel? = nil
}

/// Makes a sidebar row draggable and reports where it is.
struct SidebarDragSource<Ghost: View>: ViewModifier {
    @Environment(\.sidebarDrag) private var drag
    let store: BrowserStore
    let row: SidebarDragModel.Row
    /// Rows that only take drops (header, divider, New Tab) don't start one.
    var draggable = true
    var onDrop: (SidebarDropOutcome) -> Void = { _ in }
    @ViewBuilder let ghost: () -> Ghost

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                var row = row
                row.frame = frame
                drag?.report(row)
            }
            .onDisappear { drag?.forget(row) }
            .gesture(draggable ? gesture : nil)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard let drag else { return }
                if !drag.isDragging {
                    var row = row
                    row.frame = drag.frame(of: row) ?? .zero
                    drag.begin([row.id], row: row, at: value.startLocation, ghost: AnyView(ghost()))
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
            }
    }
}

extension SidebarDragModel {
    func frame(of row: Row) -> CGRect? { rows[row.key]?.frame }
    func tileFrame(_ id: UUID) -> CGRect? { tiles[id] }
}

/// Draws the drag: the row following the pointer, the insertion line, and what a drop lands on.
struct SidebarDragOverlay: View {
    let drag: SidebarDragModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let session = drag.session {
                if let rect = drag.highlightedRow {
                    RoundedRectangle(cornerRadius: ArcMetrics.Sidebar.cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(ArcMetrics.Sidebar.selectedFill))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if let line = drag.insertionLine {
                    InsertionLine(width: line.width)
                        .offset(x: line.x, y: line.y - InsertionLine.thickness / 2)
                }
                if let ghost = drag.ghost {
                    let frame = session.row.frame
                    ghost
                        .frame(width: frame.width, height: frame.height)
                        .opacity(SidebarDragOverlay.ghostOpacity)
                        .offset(x: frame.minX + session.location.x - session.start.x,
                                y: frame.minY + session.location.y - session.start.y)
                }
            }
        }
        // Everything above is in window points; the overlay sits on the sidebar's column.
        .offset(x: -drag.bounds.minX, y: -drag.bounds.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Unverified: Arc's dragged row reads as a translucent copy (docs/arc-visual-spec.md "Tab drag").
    static let ghostOpacity = 0.6
}

/// Arc's insertion mark (an incognito window, 1 Nov 2026, 2× capture): a 2pt line in (239,241,254)
/// centred on the gap between rows, from 8pt inside the row to 3.5pt short of its end, starting
/// with an 8pt ring of the same 2pt stroke.
private struct InsertionLine: View {
    static let thickness: CGFloat = 2
    static let ring: CGFloat = 8
    static let color = Color(red: 239 / 255, green: 241 / 255, blue: 254 / 255)
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Self.color, lineWidth: Self.thickness)
                .frame(width: Self.ring, height: Self.ring)
            Rectangle()
                .fill(Self.color)
                .frame(height: Self.thickness)
        }
        .frame(width: max(width, Self.ring), height: Self.ring)
        .offset(y: -(Self.ring - Self.thickness) / 2)
    }
}

/// A tab row while a drag offers to split it (Arc, incognito capture): the row keeps its own half
/// and the other half is a plain pill, white at about 53% over the sidebar, 12pt apart.
struct SplitDropPreview<Content: View>: View {
    static var gap: CGFloat { 12 }
    static var fill: Double { 0.53 }
    let side: SplitDropSide?
    @ViewBuilder let content: Content

    var body: some View {
        if let side {
            GeometryReader { geometry in
                let half = (geometry.size.width - Self.gap) / 2
                HStack(spacing: Self.gap) {
                    if side == .left { pill(half) }
                    content.frame(width: half)
                    if side == .right { pill(half) }
                }
            }
            .frame(height: ArcMetrics.Sidebar.pillHeight)
        } else {
            content
        }
    }

    private func pill(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: ArcMetrics.Sidebar.cornerRadius, style: .continuous)
            .fill(Color(red: 0.98, green: 0.984, blue: 1).opacity(Self.fill))
            .frame(width: width, height: ArcMetrics.Sidebar.pillHeight)
    }
}

/// Finds the enclosing list's scroll view and the sidebar's hosting view for drag autoscroll.
struct SidebarScrollViewFinder: NSViewRepresentable {
    let drag: SidebarDragModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            drag.scrollView = scrollView
            var host: NSView? = scrollView
            while let v = host, !(v is NSHostingView<SidebarView>) { host = v.superview }
            drag.sidebarView = host
        }
    }
}
