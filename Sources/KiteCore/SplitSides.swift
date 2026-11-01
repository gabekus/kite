import Foundation

/// Arc's Add Left / Right / Top / Bottom Split (command bar `addLeftSplit`…`addBottomSplit`; the same titles are in
/// its split view controls menu): an empty pane on one side of the focused pane.
extension BrowserState {
    /// Sides the focused page can get a new pane on: all four for a single page, the two along a split's
    /// axis (a split is one row or one column), none for a full split. The same rule as a dropped link.
    public var splitSides: Set<SplitEdge> { splitDropEdges }

    /// Adds an empty pane next to the focused one, on `side`, and focuses it. A single page becomes a two-pane
    /// split in that side's orientation. The new pane takes half the focused pane's share, as Add Split View does.
    /// A side off the split's axis, or a fifth pane, adds nothing (`.full`).
    @discardableResult
    public mutating func addSplitPane(side: SplitEdge, id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        guard selectedTab != nil else { return .noTab }
        guard splitSides.contains(side) else { return .full }
        let result = addSplitPane(id: id, now: now)
        guard case .added(let pane) = result, let found = split(containing: pane) else { return result }
        let s = found.space
        var split = found.split
        if split.tabIDs.count == 2 { split.orientation = side.orientation }
        // Add Split View put the pane just after the focused one (for a favorite, after its unpinned copy),
        // each with half the old share: for a leading or top side, swap the two.
        if side.isStart, let p = split.tabIDs.firstIndex(of: pane), p > 0 {
            let neighbor = split.tabIDs[p - 1]
            split.tabIDs.swapAt(p - 1, p)
            var factors = split.normalizedFactors
            factors.swapAt(p - 1, p)
            split.widthFactors = factors
            // Keep the sidebar row's order the same as the panes'.
            if let a = favorites.firstIndex(where: { $0.id == neighbor }),
               let b = favorites.firstIndex(where: { $0.id == pane }) {
                favorites.swapAt(a, b)
            } else if let a = spaces[s].tabs.firstIndex(where: { $0.id == neighbor }),
               let b = spaces[s].tabs.firstIndex(where: { $0.id == pane }) {
                spaces[s].tabs.swapAt(a, b)
            } else {
                spaces[s].pinnedItems.swapTabs(neighbor, pane)
            }
        }
        updateSplit(split.id) { [split] in $0 = split }
        return result
    }
}

extension [PinnedItem] {
    /// Swaps two tabs that sit at the same level of the pinned tree.
    mutating func swapTabs(_ a: UUID, _ b: UUID) {
        let ia = firstIndex { if case .tab(let t) = $0 { t.id == a } else { false } }
        let ib = firstIndex { if case .tab(let t) = $0 { t.id == b } else { false } }
        if let ia, let ib {
            swapAt(ia, ib)
            return
        }
        for i in indices {
            if case .folder(var folder) = self[i] {
                let before = folder.items
                folder.items.swapTabs(a, b)
                if folder.items != before {
                    self[i] = .folder(folder)
                    return
                }
            }
        }
    }
}
