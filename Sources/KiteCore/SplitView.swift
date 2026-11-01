import Foundation

/// Arc's `SplitViewLayoutOrientation`: panes in one row or one column.
public enum SplitOrientation: String, Hashable, Codable, Sendable {
    case horizontal
    case vertical
}

/// Tabs shown side by side in one sidebar row, like Arc's split view.
/// The member tabs stay in their space's pinned or unpinned list, next to each
/// other; the split only groups them.
public struct SplitView: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Pane order, leading to trailing (or top to bottom).
    public var tabIDs: [UUID]
    /// Each pane's share of the width (or height), summing to 1. Arc's `itemWidthFactors`.
    public var widthFactors: [Double]
    public var orientation: SplitOrientation
    /// Arc's Expand Current Split: the pane shown full size while the others stay in the split.
    /// `widthFactors` are kept, so the old widths come back when the split is shown again
    /// (focusing another pane, dragging a divider, adding a pane, closing the expanded one).
    public var expandedTabID: UUID?

    /// Arc refuses a fifth pane with a "Cannot Add New Pane" toast.
    public static let maxPanes = 4

    public init(id: UUID = UUID(), tabIDs: [UUID], widthFactors: [Double]? = nil, orientation: SplitOrientation = .horizontal) {
        self.id = id
        self.tabIDs = tabIDs
        self.widthFactors = widthFactors ?? Self.equalFactors(tabIDs.count)
        self.orientation = orientation
    }

    static func equalFactors(_ count: Int) -> [Double] {
        count > 0 ? Array(repeating: 1 / Double(count), count: count) : []
    }

    /// Factors that match `tabIDs` and sum to 1, whatever was stored.
    public var normalizedFactors: [Double] {
        guard widthFactors.count == tabIDs.count, widthFactors.allSatisfy({ $0 > 0 }) else {
            return Self.equalFactors(tabIDs.count)
        }
        let total = widthFactors.reduce(0, +)
        return widthFactors.map { $0 / total }
    }

    /// What the panes are laid out with: the expanded pane takes everything (1) and the rest
    /// nothing (0), as Arc's maximize sets them; otherwise `normalizedFactors`.
    public var layoutFactors: [Double] {
        guard let expandedTabID, tabIDs.contains(expandedTabID) else { return normalizedFactors }
        return tabIDs.map { $0 == expandedTabID ? 1 : 0 }
    }

    /// Drops a pane and gives its share to the others in proportion.
    mutating func remove(_ tabID: UUID) {
        guard let i = tabIDs.firstIndex(of: tabID) else { return }
        var factors = normalizedFactors
        if expandedTabID == tabID { expandedTabID = nil }
        tabIDs.remove(at: i)
        factors.remove(at: i)
        let total = factors.reduce(0, +)
        widthFactors = total > 0 ? factors.map { $0 / total } : Self.equalFactors(tabIDs.count)
    }

    /// Inserts a pane after `index`, splitting that pane's share in half.
    mutating func insert(_ tabID: UUID, after index: Int) {
        var factors = normalizedFactors
        let at = min(index + 1, tabIDs.count)
        let source = min(index, factors.count - 1)
        let half = factors[source] / 2
        factors[source] = half
        factors.insert(half, at: at)
        tabIDs.insert(tabID, at: at)
        widthFactors = factors
        // A new pane has to be seen to be filled.
        expandedTabID = nil
    }
}

public enum AddSplitResult: Equatable, Sendable {
    /// The new, empty pane: the shell opens the command bar for it.
    case added(UUID)
    /// Already `SplitView.maxPanes` panes.
    case full
    case noTab
}

extension BrowserState {
    // MARK: Lookup

    /// The split holding the tab, in whichever space it is.
    public func split(containing tabID: UUID) -> (space: Int, split: SplitView)? {
        for (s, space) in spaces.enumerated() {
            if let split = space.splits.first(where: { $0.tabIDs.contains(tabID) }) {
                return (s, split)
            }
        }
        return nil
    }

    /// The selected tab's split, if it's in one.
    public var selectedSplit: SplitView? {
        selectedSpace.selectedTabID.flatMap { split(containing: $0)?.split }
    }

    /// The tabs on screen, in pane order: the selected split's, or just the selected tab.
    public var visibleTabs: [BrowserTab] {
        if let split = selectedSplit {
            return split.tabIDs.compactMap(tab)
        }
        return selectedTab.map { [$0] } ?? []
    }

    /// The split's pane to focus when its sidebar row is clicked: the one used last.
    public func focusTarget(of split: SplitView) -> UUID? {
        split.tabIDs.compactMap(tab).max { $0.lastActiveAt < $1.lastActiveAt }?.id
    }

    /// Sidebar order with each split counted once, at its first member: what ⌘1…⌘9 and ⌃⌥↑↓ step through.
    /// A split stands for the pane it would focus (or the focused one, if it's the selected split).
    func sidebarStops(in s: Int) -> [UUID] {
        var seen = Set<UUID>()
        return sidebarTabs(in: s).compactMap { tab in
            guard let split = spaces[s].splits.first(where: { $0.tabIDs.contains(tab.id) }) else { return tab.id }
            guard seen.insert(split.id).inserted else { return nil }
            if let selected = spaces[s].selectedTabID, split.tabIDs.contains(selected) { return selected }
            return focusTarget(of: split)
        }
    }

    // MARK: Commands

    /// Arc's Add Split View: adds an empty pane after the focused one and focuses it.
    /// A tab that isn't split yet becomes a two-pane split.
    @discardableResult
    public mutating func addSplitPane(id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        guard let focused = selectedTab, let location = location(of: focused.id) else { return .noTab }
        // Favorites belong to no space; split them in the current one.
        let s = location.space ?? selectedSpaceIndex
        let newTab = BrowserTab(id: id, url: nil, lastActiveAt: now)

        if let i = spaces[s].splits.firstIndex(where: { $0.tabIDs.contains(focused.id) }) {
            guard spaces[s].splits[i].tabIDs.count < SplitView.maxPanes else { return .full }
            insertNextTo(focused.id, newTab, in: s)
            let index = spaces[s].splits[i].tabIDs.firstIndex(of: focused.id)!
            spaces[s].splits[i].insert(newTab.id, after: index)
        } else if location.section == .favorite {
            // A favorite stays in the grid; the split is made of an unpinned copy and the new pane.
            let copy = BrowserTab(url: focused.url, title: focused.title, faviconURL: focused.faviconURL, lastActiveAt: now)
            spaces[s].tabs.insert(contentsOf: [copy, newTab], at: 0)
            spaces[s].splits.append(SplitView(tabIDs: [copy.id, newTab.id]))
        } else {
            insertNextTo(focused.id, newTab, in: s)
            spaces[s].splits.append(SplitView(tabIDs: [focused.id, newTab.id]))
        }
        spaces[s].selectedTabID = newTab.id
        selectedSpaceID = spaces[s].id
        return .added(newTab.id)
    }

    /// Puts `tab` right after `neighbor` in the neighbor's list, so a split's members stay together.
    private mutating func insertNextTo(_ neighbor: UUID, _ tab: BrowserTab, in s: Int) {
        if let i = spaces[s].tabs.firstIndex(where: { $0.id == neighbor }) {
            spaces[s].tabs.insert(tab, at: i + 1)
        } else if !spaces[s].pinnedItems.insertTab(tab, after: neighbor) {
            spaces[s].tabs.insert(tab, at: 0)
        }
    }

    /// Esc on a new pane's command bar: the still-empty pane goes away without being archived,
    /// and the pane before it gets focus back. A pane that has loaded something stays.
    public mutating func cancelSplitPane(_ id: UUID) {
        // Chromium reports about:blank for the empty pane's page, so that counts as empty too.
        guard let s = split(containing: id)?.space, tab(id)?.url.map({ $0.absoluteString == "about:blank" }) ?? true,
              let split = spaces[s].splits.first(where: { $0.tabIDs.contains(id) }),
              let index = split.tabIDs.firstIndex(of: id) else { return }
        let rest = split.tabIDs.filter { $0 != id }
        if let i = spaces[s].tabs.firstIndex(where: { $0.id == id }) {
            spaces[s].tabs.remove(at: i)
        } else {
            _ = spaces[s].pinnedItems.removeTab(id)
        }
        normalizeSplits()
        if spaces[s].selectedTabID == id, !rest.isEmpty {
            spaces[s].selectedTabID = rest[max(index - 1, 0)]
        }
    }

    /// Arc's Separate Page from Split View: the tab leaves the split and stays open on its own.
    public mutating func separateFromSplit(tab id: UUID) {
        guard let s = split(containing: id)?.space, let i = spaces[s].splits.firstIndex(where: { $0.tabIDs.contains(id) }) else { return }
        spaces[s].splits[i].remove(id)
        // Its own row now: just below the split's members.
        if let tabIndex = spaces[s].tabs.firstIndex(where: { $0.id == id }),
           let last = spaces[s].tabs.lastIndex(where: { spaces[s].splits[i].tabIDs.contains($0.id) }),
           last > tabIndex {
            let tab = spaces[s].tabs.remove(at: tabIndex)
            spaces[s].tabs.insert(tab, at: last)
        }
        normalizeSplits()
    }

    /// Arc's Expand Current Split: the focused pane fills the split; the others stay in it, hidden.
    /// It only expands, as Arc's handler does: running it again changes nothing.
    public mutating func expandSplitPane() {
        guard let focused = selectedSpace.selectedTabID, let s = split(containing: focused)?.space,
              let i = spaces[s].splits.firstIndex(where: { $0.tabIDs.contains(focused) }) else { return }
        spaces[s].splits[i].expandedTabID = focused
    }

    /// Focusing a hidden pane of an expanded split shows the whole split again.
    mutating func collapseExpandedSplit(toShow id: UUID) {
        guard let s = split(containing: id)?.space,
              let i = spaces[s].splits.firstIndex(where: { $0.tabIDs.contains(id) }),
              let expanded = spaces[s].splits[i].expandedTabID, expanded != id else { return }
        spaces[s].splits[i].expandedTabID = nil
    }

    /// Switch to Split View N (1-based), and next/previous with wraparound.
    public mutating func focusPane(number: Int, now: Date = Date()) {
        guard let split = selectedSplit, split.tabIDs.indices.contains(number - 1) else { return }
        select(tab: split.tabIDs[number - 1], now: now)
    }

    public mutating func focusAdjacentPane(offset: Int, now: Date = Date()) {
        guard let split = selectedSplit, let current = selectedSpace.selectedTabID,
              let i = split.tabIDs.firstIndex(of: current) else { return }
        let n = split.tabIDs.count
        select(tab: split.tabIDs[((i + offset) % n + n) % n], now: now)
    }

    /// Sets the share of the two panes either side of divider `index` (0 = between panes 0 and 1).
    /// `fraction` is how far along the pair the divider sits, clamped so neither pane goes under `minimum`.
    public mutating func moveSplitDivider(_ splitID: UUID, index: Int, fraction: Double, minimum: Double = 0) {
        for s in spaces.indices {
            guard let i = spaces[s].splits.firstIndex(where: { $0.id == splitID }) else { continue }
            var factors = spaces[s].splits[i].normalizedFactors
            guard factors.indices.contains(index + 1) else { return }
            let pair = factors[index] + factors[index + 1]
            let low = min(minimum, pair / 2)
            let leading = min(max(fraction * pair, low), pair - low)
            factors[index] = leading
            factors[index + 1] = pair - leading
            spaces[s].splits[i].widthFactors = factors
            spaces[s].splits[i].expandedTabID = nil
            return
        }
    }

    /// Drops members that no longer exist (or moved to the favorites or another space)
    /// and splits left with fewer than two panes. Runs after every mutation that can remove a tab.
    public mutating func normalizeSplits() {
        for s in spaces.indices where !spaces[s].splits.isEmpty {
            let ids = Set(spaces[s].allTabs.map(\.id))
            var claimed = Set<UUID>()
            spaces[s].splits = spaces[s].splits.compactMap { split in
                var split = split
                for id in split.tabIDs where !ids.contains(id) || claimed.contains(id) {
                    split.remove(id)
                }
                claimed.formUnion(split.tabIDs)
                return split.tabIDs.count >= 2 ? split : nil
            }
        }
    }
}

extension [PinnedItem] {
    /// Inserts `tab` just after the tab `neighbor`, at whatever depth it is.
    mutating func insertTab(_ tab: BrowserTab, after neighbor: UUID) -> Bool {
        for i in indices {
            switch self[i] {
            case .tab(let existing) where existing.id == neighbor:
                insert(.tab(tab), at: i + 1)
                return true
            case .folder(var folder):
                if folder.items.insertTab(tab, after: neighbor) {
                    self[i] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}

/// One sidebar row: a single item, or a split shown once where its first member is.
public struct SidebarGroup: Identifiable, Hashable, Sendable {
    /// The split's ID, or the item's.
    public var id: UUID
    public var split: SplitView?
    /// Where the row's items sit in the list that was grouped, in order.
    public var indices: [Int]

    /// Groups a sidebar list (unpinned tabs, or one level of pinned items) by split.
    public static func group(_ ids: [UUID], splits: [SplitView]) -> [SidebarGroup] {
        var groups: [SidebarGroup] = []
        var splitRow: [UUID: Int] = [:]
        for (index, id) in ids.enumerated() {
            if let split = splits.first(where: { $0.tabIDs.contains(id) }) {
                if let row = splitRow[split.id] {
                    groups[row].indices.append(index)
                } else {
                    splitRow[split.id] = groups.count
                    groups.append(SidebarGroup(id: split.id, split: split, indices: [index]))
                }
            } else {
                groups.append(SidebarGroup(id: id, split: nil, indices: [index]))
            }
        }
        return groups
    }

    /// Turns a move of rows (SwiftUI's `onMove`) into the same move of the underlying items.
    public static func itemMove(_ groups: [SidebarGroup], from source: IndexSet, to destination: Int, itemCount: Int) -> (IndexSet, Int) {
        let items = IndexSet(source.flatMap { groups[$0].indices })
        let target = destination < groups.count ? groups[destination].indices.first ?? itemCount : itemCount
        return (items, target)
    }
}
