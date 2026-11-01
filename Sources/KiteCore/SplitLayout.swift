import Foundation

/// An outer edge of the content area that a dragged link can be dropped on to open it in a new pane.
/// Leading and trailing make (or extend) a side-by-side split; top and bottom a top/bottom one.
public enum SplitEdge: String, CaseIterable, Sendable {
    case leading
    case trailing
    case top
    case bottom

    public var orientation: SplitOrientation {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// The new pane goes first (leading or top) rather than last.
    public var isStart: Bool { self == .leading || self == .top }
}

extension SplitView {
    /// Inserts a pane at `index` with an equal share, 1/(n+1), taken from the others in proportion.
    /// Arc sizes a drop's proposed pane this way (`SplitViewController.draggingEntered:`).
    mutating func insertEqualShare(_ tabID: UUID, at index: Int) {
        let factors = normalizedFactors
        let n = Double(factors.count + 1)
        var scaled = factors.map { $0 * (n - 1) / n }
        let at = max(0, min(index, tabIDs.count))
        scaled.insert(1 / n, at: at)
        tabIDs.insert(tabID, at: at)
        widthFactors = scaled
    }
}

extension BrowserState {
    /// Edges a dropped link can open a new pane at, for what's on screen now.
    /// A single page takes all four; a split keeps its orientation, so only the two ends of its axis;
    /// a full split takes none.
    public var splitDropEdges: Set<SplitEdge> {
        guard selectedTab != nil else { return [] }
        guard let split = selectedSplit else { return Set(SplitEdge.allCases) }
        guard split.tabIDs.count < SplitView.maxPanes else { return [] }
        return Set(SplitEdge.allCases.filter { $0.orientation == split.orientation })
    }

    /// A link dropped on an edge of the content area: opens `url` in a new pane at that end and focuses it.
    @discardableResult
    public mutating func openInSplit(url: URL, edge: SplitEdge, id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        guard splitDropEdges.contains(edge) else { return selectedSplit == nil ? .noTab : .full }
        let result = addSplitPane(id: id, now: now)
        guard case .added(let pane) = result,
              let found = split(containing: pane),
              let i = spaces[found.space].splits.firstIndex(where: { $0.id == found.split.id }) else { return result }
        update(tab: pane) { $0.url = url }
        var split = spaces[found.space].splits[i]
        // Undo Add Split View's halving: the pane went in right after the focused one with half its share.
        var factors = split.normalizedFactors
        if let p = split.tabIDs.firstIndex(of: pane), p > 0 {
            factors[p - 1] += factors[p]
            factors.remove(at: p)
            split.tabIDs.remove(at: p)
            split.widthFactors = factors
        }
        split.insertEqualShare(pane, at: edge.isStart ? 0 : split.tabIDs.count)
        split.orientation = edge.orientation
        spaces[found.space].splits[i] = split
        return result
    }

    /// Arc's command bar "Add Vertical Split View": adds a pane like Add Split View, in a top/bottom layout.
    @discardableResult
    public mutating func addVerticalSplitPane(id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        let result = addSplitPane(id: id, now: now)
        if case .added(let pane) = result, let found = split(containing: pane) {
            setSplitOrientation(found.split.id, .vertical)
        }
        return result
    }

    /// Arc's "Convert to Horizontal/Vertical Split View": the same panes and shares, in a row or a column.
    public mutating func setSplitOrientation(_ splitID: UUID, _ orientation: SplitOrientation) {
        for s in spaces.indices {
            if let i = spaces[s].splits.firstIndex(where: { $0.id == splitID }) {
                spaces[s].splits[i].orientation = orientation
                return
            }
        }
    }
}
