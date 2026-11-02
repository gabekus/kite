import Foundation

/// Dragging a space's icon along the strip at the bottom of the sidebar to reorder spaces, after Arc's
/// `SidebarDock` (an `NSCollectionView`). Observed in Arc 1.171 on 1 Nov 2026 (accessibility frames and
/// dock-region captures during a synthetic drag) and read from its `SidebarDockCollectionViewLayout`:
///
/// - The strip lays out `count - dragged + (drop target ? 1 : 0)` slots on a 34pt pitch, centred. The
///   dragged icon leaves its slot and follows the pointer; while the pointer is over the strip an empty
///   slot opens where it would land and the other icons slide aside.
/// - The open slot is the one whose centre is nearest the pointer (it moved when the pointer crossed the
///   midpoint between two slots).
/// - Off the strip (above it, for one) the open slot closes and the remaining icons re-centre; back over
///   the strip it opens again.
/// - Dropping on the strip moves the space there; the current space stays the current space.
///
/// Positions are x offsets in points along the strip, all Foundation-only so they can be tested.
public enum SpaceReorder {
    /// Which slot a drop at `pointerX` lands in, for a strip of `count` spaces (the dragged one
    /// included) whose first slot starts at `stripMinX` with cells `pitch` apart.
    public static func dropIndex(pointerX: Double, stripMinX: Double, count: Int, pitch: Double, cellWidth: Double) -> Int {
        guard count > 0 else { return 0 }
        let first = stripMinX + cellWidth / 2
        let slot = ((pointerX - first) / pitch).rounded()
        return Int(min(max(slot, 0), Double(count - 1)))
    }

    /// The order the strip shows during a drag: the spaces without the dragged one, with `nil` for the
    /// open slot when the drag aims at the strip.
    public static func slots<ID: Equatable>(_ ids: [ID], dragging: ID, target: Int?) -> [ID?] {
        var slots: [ID?] = ids.filter { $0 != dragging }
        if let target { slots.insert(nil, at: min(max(target, 0), slots.count)) }
        return slots
    }

    /// The strip's width for `slots` cells: `pitch` apart, the last one its full width.
    public static func width(slots: Int, pitch: Double, cellWidth: Double) -> Double {
        slots > 0 ? Double(slots - 1) * pitch + cellWidth : 0
    }
}
