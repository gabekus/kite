import Foundation

/// What one browser window shows: its space, and the tab it last showed in each space.
/// Arc's normal windows share one sidebar (its `global` sidebar context: spaces, pinned tabs,
/// favourites, unpinned tabs) and each keeps its own selection, so Kite gives every normal
/// window its own `BrowserState` copy and keeps their content in step.
public struct WindowSelection: Codable, Equatable, Sendable {
    public var spaceID: UUID
    /// Space id → that space's selected tab, nil when the window shows none there.
    public var tabIDs: [UUID: UUID?]

    public init(spaceID: UUID, tabIDs: [UUID: UUID?] = [:]) {
        self.spaceID = spaceID
        self.tabIDs = tabIDs
    }
}

extension BrowserState {
    public var selection: WindowSelection {
        WindowSelection(
            spaceID: selectedSpaceID,
            tabIDs: Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.selectedTabID) })
        )
    }

    /// Applies `selection` where its space and tabs still exist. A space it doesn't name (one
    /// made since) keeps the selection it has; a tab that has gone leaves that space with none.
    public mutating func select(_ selection: WindowSelection) {
        if spaceIndex(selection.spaceID) != nil { selectedSpaceID = selection.spaceID }
        for s in spaces.indices {
            guard let entry = selection.tabIDs[spaces[s].id] else { continue }
            spaces[s].selectedTabID = entry.flatMap { wanted in sidebarTabs(in: s).contains { $0.id == wanted } ? wanted : nil }
        }
    }

    /// `other`'s content with this window's selection: how a normal window takes a change made
    /// in another one. Spaces and tabs this window hasn't selected anything in follow `other`.
    public func adoptingContent(of other: BrowserState) -> BrowserState {
        var result = other
        result.select(selection)
        return result
    }

    /// A second normal window: the same content, on `space`, with nothing selected there, so it
    /// opens on its own page rather than a second copy of another window's tab.
    public func newWindowState(on space: UUID? = nil) -> BrowserState {
        var state = self
        if let space, spaceIndex(space) != nil { state.selectedSpaceID = space }
        state.spaces[state.selectedSpaceIndex].selectedTabID = nil
        return state
    }
}
