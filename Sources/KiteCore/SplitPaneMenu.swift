import Foundation

/// Arc's Split View Controls Menu (`ContextMenus/SplitScreenButtonMenu.swift`): the menu behind a pane's split
/// button. Arc builds it from a list of `ContentPanelSplitViewMenuItemType`s, one case per group: Move Left/Right
/// or Move Up/Down, Add Left/Right or Add Top/Bottom Split, Separate Tab from Split, Share Split View…, and
/// Convert to Vertical or Horizontal Split View, the pair matching the split's axis.
public enum SplitPaneMenuItem: Hashable, Sendable {
    /// Move Left / Move Right / Move Up / Move Down: the pane swaps places with its neighbour on that side.
    case move(SplitEdge)
    /// Add Left / Right / Top / Bottom Split: an empty pane next to this one.
    case add(SplitEdge)
    /// Separate Tab from Split.
    case separate
    /// Convert to Vertical / Horizontal Split View.
    case convert(SplitOrientation)
    case separator

    public var title: String? {
        switch self {
        case .move(.leading): "Move Left"
        case .move(.trailing): "Move Right"
        case .move(.top): "Move Up"
        case .move(.bottom): "Move Down"
        case .add(.leading): "Add Left Split"
        case .add(.trailing): "Add Right Split"
        case .add(.top): "Add Top Split"
        case .add(.bottom): "Add Bottom Split"
        case .separate: "Separate Tab from Split"
        case .convert(.vertical): "Convert to Vertical Split View"
        case .convert(.horizontal): "Convert to Horizontal Split View"
        case .separator: nil
        }
    }
}

extension SplitEdge {
    /// The two sides along an axis, start first.
    static func sides(of orientation: SplitOrientation) -> [SplitEdge] {
        orientation == .horizontal ? [.leading, .trailing] : [.top, .bottom]
    }
}

extension BrowserState {
    /// The split button menu for pane `tabID`, with whether each item can run. Empty when the tab isn't in a split.
    /// Order follows Arc's item type enum (move, add, separate, share, convert); Share Split View… is left out
    /// (it copies an arc.net share link, which needs Arc's servers).
    public func splitPaneMenu(for tabID: UUID) -> [(item: SplitPaneMenuItem, enabled: Bool)] {
        guard let split = split(containing: tabID)?.split, let index = split.tabIDs.firstIndex(of: tabID) else { return [] }
        let sides = SplitEdge.sides(of: split.orientation)
        let roomForMore = split.tabIDs.count < SplitView.maxPanes
        let other: SplitOrientation = split.orientation == .horizontal ? .vertical : .horizontal
        return [
            (.move(sides[0]), index > 0),
            (.move(sides[1]), index < split.tabIDs.count - 1),
            (.separator, true),
            (.add(sides[0]), roomForMore),
            (.add(sides[1]), roomForMore),
            (.separator, true),
            (.separate, true),
            (.separator, true),
            (.convert(other), true),
        ]
    }

    /// Move Left / Right / Up / Down: the pane trades places with its neighbour on `side`, keeping its share of
    /// the split, and the split's sidebar row follows the new order. Returns false when there's no neighbour there
    /// (the first pane can't move left) or the side is off the split's axis.
    @discardableResult
    public mutating func moveSplitPane(_ tabID: UUID, toward side: SplitEdge) -> Bool {
        guard let found = split(containing: tabID),
              let i = spaces[found.space].splits.firstIndex(where: { $0.id == found.split.id }) else { return false }
        let s = found.space
        var split = spaces[s].splits[i]
        guard side.orientation == split.orientation, let p = split.tabIDs.firstIndex(of: tabID) else { return false }
        let q = side.isStart ? p - 1 : p + 1
        guard split.tabIDs.indices.contains(q) else { return false }
        let neighbor = split.tabIDs[q]
        var factors = split.normalizedFactors
        split.tabIDs.swapAt(p, q)
        factors.swapAt(p, q)
        split.widthFactors = factors
        spaces[s].splits[i] = split
        if let a = spaces[s].tabs.firstIndex(where: { $0.id == tabID }),
           let b = spaces[s].tabs.firstIndex(where: { $0.id == neighbor }) {
            spaces[s].tabs.swapAt(a, b)
        } else {
            spaces[s].pinnedItems.swapTabs(tabID, neighbor)
        }
        return true
    }
}
