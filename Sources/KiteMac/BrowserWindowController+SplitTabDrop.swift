import AppKit
import KiteCore

/// A sidebar tab dragged onto the pages makes a split or adds a pane, like Arc's window-contents
/// split view (`onDropSidebarItem`; regions from `ARCUI.SplitViewController`, see `SplitTabDrop`).
extension BrowserWindowController: SidebarDragContentTarget {
    /// Where a drop at `point` would put the dragged items: beside which pane, on which side, and
    /// the new pane's slot in the drop zones' points.
    struct TabDropProposal {
        var pane: UUID
        var before: Bool
        var slot: CGRect
    }

    func sidebarDrag(_ ids: [UUID], movedTo point: CGPoint?) {
        splitDropZones.showTabPlaceholder(point.flatMap { tabDropProposal(ids, at: $0)?.slot })
    }

    func sidebarDrag(_ ids: [UUID], droppedAt point: CGPoint) -> Bool {
        let proposal = tabDropProposal(ids, at: point)
        splitDropZones.showTabPlaceholder(nil)
        guard let proposal else { return false }
        store.hideCommandBar()
        var outcome: SidebarDropOutcome?
        store.mutate { outcome = $0.dropSidebarItems(ids, besidePane: proposal.pane, before: proposal.before) }
        guard let outcome else { return false }
        sidebarDropped(outcome)
        return true
    }

    /// `point` is a SwiftUI global point: window points from the content view's top-left.
    func tabDropProposal(_ ids: [UUID], at point: CGPoint) -> TabDropProposal? {
        guard let content = window?.contentView, splitDropZones.superview != nil else { return nil }
        let windowPoint = content.convert(NSPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y), to: nil)
        let local = splitDropZones.convert(windowPoint, from: nil)
        let zones = splitDropZones.bounds
        guard zones.contains(local) else { return nil }

        let state = store.state
        let visible = state.visibleTabs.map(\.id)
        guard !visible.isEmpty else { return nil }
        let split = state.selectedSplit
        let orientation = split?.orientation ?? .horizontal
        // Each pane's frame in the drop zones' points; one page fills the content card.
        let frames: [CGRect] = visible.map { id in
            guard visible.count > 1, splitPanes.superview != nil, let frame = splitPanes.frame(of: id) else { return zones }
            return splitDropZones.convert(frame, from: splitPanes)
        }
        let half = ArcMetrics.Split.gap / 2
        guard let index = frames.firstIndex(where: { $0.insetBy(dx: -half, dy: -half).contains(local) }) else { return nil }
        let frame = frames[index]
        let pane = visible[index]
        guard state.canDropSidebarItems(ids, besidePane: pane) else { return nil }
        let region = SplitTabDrop.region(x: Double(local.x - frame.minX), y: Double(local.y - frame.minY),
                                         width: Double(frame.width), height: Double(frame.height),
                                         paneCount: visible.count, orientation: orientation)
        // The middle of a pane: Arc replaces it when its delegate allows, or inserts; Kite inserts after it.
        let before = region.isBefore
        let factors = split?.normalizedFactors ?? [1]
        let insertAt = index + (before ? 0 : 1)
        let share = SplitTabDrop.slot(factors: factors, insertingAt: insertAt)
        // Lay the slot out as SplitPanesView will: the gaps come out of the length first.
        let horizontal = orientation == .horizontal
        let length = horizontal ? zones.width : zones.height
        let gap = ArcMetrics.Split.gap
        let available = max(length - gap * CGFloat(factors.count), 0)
        let start = CGFloat(share.start) * available + CGFloat(insertAt) * gap
        let size = CGFloat(share.length) * available
        let slot = horizontal
            ? CGRect(x: start, y: 0, width: size, height: zones.height)
            : CGRect(x: 0, y: start, width: zones.width, height: size)
        return TabDropProposal(pane: pane, before: before, slot: slot.integral)
    }
}
