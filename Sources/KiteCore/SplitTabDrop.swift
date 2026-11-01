import Foundation

/// Dragging a sidebar tab onto the page area to make a split or add a pane, after Arc's
/// window-contents split view (`ARCUI.SplitViewController`, `onDropSidebarItem`; Arc 1.169 decompile).
///
/// Arc tests the pointer against each pane in turn. Inside a pane, a band along each edge proposes a
/// new pane on that side (`FUN_100a45034`); the bands' depth (`FUN_100a453dc` / `FUN_100a45484`):
/// - one pane: 45% of its width from the left and right (40% when top/bottom drops are allowed, then
///   with top and bottom bands of a quarter of its height, at most 50pt);
/// - several panes: min(width / 3, 80pt) from the ends of a side-by-side split's panes, or
///   min(height / 3, 50pt) from the ends of a top/bottom one's.
/// What's left in the middle offers to replace the pane when Arc's delegate allows it, and otherwise
/// inserts a pane there; Kite doesn't replace (see docs/arc-visual-spec.md) and inserts after the pane.
public enum SplitTabDropRegion: Equatable, Sendable {
    case none
    case leading
    case trailing
    case top
    case bottom

    /// The new pane goes before the pane the pointer is in.
    public var isBefore: Bool { self == .leading || self == .top }
}

public enum SplitTabDrop {
    /// The edge bands' sizes (fractions of the pane, or points).
    public static let singlePaneFraction = 0.45
    public static let singlePaneFractionWithVertical = 0.4
    public static let multiPaneMaxWidth = 80.0
    public static let maxHeight = 50.0

    /// Where in a pane of `width` × `height` the point (`x`, `y`, from the pane's top-left) falls.
    /// `paneCount` is the panes on screen; `orientation` the split's (a single page passes its own,
    /// which Arc treats as side by side unless `verticalAllowed`).
    /// `verticalAllowed` is ARCUI's `verticalLayoutOrientationFromDragAllowed`, false by default
    /// (@100a50820); whether Arc's window turns it on wasn't traced.
    public static func region(x: Double, y: Double, width: Double, height: Double,
                              paneCount: Int, orientation: SplitOrientation,
                              verticalAllowed: Bool = false) -> SplitTabDropRegion {
        if paneCount < 2 {
            let dx = width * (verticalAllowed ? singlePaneFractionWithVertical : singlePaneFraction)
            if verticalAllowed {
                let dy = min(height * 0.25, maxHeight)
                if y < dy { return .top }
                if y > height - dy { return .bottom }
            }
            if x < dx { return .leading }
            if x > width - dx { return .trailing }
            return .none
        }
        switch orientation {
        case .vertical:
            let dy = min(height / 3, maxHeight)
            if y < dy { return .top }
            if y > height - dy { return .bottom }
        case .horizontal:
            let dx = min(width / 3, multiPaneMaxWidth)
            if x < dx { return .leading }
            if x > width - dx { return .trailing }
        }
        return .none
    }

    /// The new pane's slot along the split's axis, as fractions of it (start, length), when a pane
    /// goes in at `index` among panes sharing the axis by `factors`: an equal share, 1/(n+1),
    /// taken from the others in proportion, as Arc sizes its proposed pane.
    public static func slot(factors: [Double], insertingAt index: Int) -> (start: Double, length: Double) {
        let n = Double(factors.count + 1)
        let total = factors.reduce(0, +)
        let scaled = factors.map { (total > 0 ? $0 / total : 1 / Double(max(factors.count, 1))) * (n - 1) / n }
        let at = max(0, min(index, factors.count))
        return (scaled.prefix(at).reduce(0, +), 1 / n)
    }
}

extension BrowserState {
    /// Whether the sidebar items `ids` (a drag's rows) can be dropped beside `pane`, one of the
    /// panes on screen: tabs or splits, not folders or favorites, not already on screen, and the
    /// split can take them all.
    public func canDropSidebarItems(_ ids: [UUID], besidePane pane: UUID) -> Bool {
        guard visibleTabs.contains(where: { $0.id == pane }), !ids.isEmpty else { return false }
        for id in ids {
            // Favorites stay in the tray; Arc's drop from the tray onto a page wasn't traced.
            if location(of: id)?.section == .favorite { return false }
        }
        return canDrop(ids, on: .split(with: pane, side: .right))
    }

    /// Drops sidebar items beside `pane` in the split on screen (or the single page, which becomes a
    /// split). The tabs move into the split, so they leave their place in the sidebar and show in
    /// the split's row; the new pane gets an equal share and focus. Nil when the drop isn't allowed.
    @discardableResult
    public mutating func dropSidebarItems(_ ids: [UUID], besidePane pane: UUID, before: Bool) -> SidebarDropOutcome? {
        guard canDropSidebarItems(ids, besidePane: pane) else { return nil }
        let old = split(containing: pane)?.split
        let oldIDs = old?.tabIDs ?? [pane]
        let oldFactors = old?.normalizedFactors ?? [1]
        let orientation = old?.orientation ?? .horizontal
        guard let outcome = dropSidebarItems(ids, on: .split(with: pane, side: before ? .left : .right)) else { return nil }
        // The join gives every pane an equal share; Arc takes the new pane's share from the others in proportion.
        guard let found = split(containing: pane),
              let i = spaces[found.space].splits.firstIndex(where: { $0.id == found.split.id }) else { return outcome }
        var split = spaces[found.space].splits[i]
        var rebuilt = SplitView(id: split.id, tabIDs: oldIDs.filter { split.tabIDs.contains($0) })
        rebuilt.widthFactors = oldFactors.count == rebuilt.tabIDs.count ? oldFactors : SplitView.equalFactors(rebuilt.tabIDs.count)
        for (index, id) in split.tabIDs.enumerated() where !rebuilt.tabIDs.contains(id) {
            rebuilt.insertEqualShare(id, at: index)
        }
        split.widthFactors = rebuilt.widthFactors
        split.orientation = orientation
        spaces[found.space].splits[i] = split
        return outcome
    }
}
