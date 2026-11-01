import Foundation

/// Arc's tab switcher (`ModalItemSwitcher`, "Tab Switcher (forward)" ⌃Tab and "(backward)" ⌃⇧Tab): like
/// ⌘Tab on the Mac, holding ⌃ and pressing Tab again moves deeper through the recently used tabs, and
/// letting go of ⌃ switches to the one highlighted. Esc closes it without switching; ← and → move too, and W
/// closes the highlighted tab. The overlay waits 0.1 s before it shows, so a quick ⌃Tab just goes back to
/// the last tab. (Arc 1.171's binary: `ModalItemSwitcherWindowController`, see docs/arc-visual-spec.md.)
public struct RecentTabSwitcher: Equatable, Sendable {
    /// Arc's overlay title (`NSLocalizedString("Recent Items", comment: "Title for the recent tabs overlay")`).
    public static let title = "Recent Items"
    /// Arc's `presentationTimer`: the overlay shows this long after the first ⌃Tab.
    public static let presentationDelay: TimeInterval = 0.1

    /// The tabs, most recently used first: the current tab, then the one before it, and so on.
    public private(set) var items: [UUID]
    public private(set) var focusedIndex: Int
    /// When the first ⌃Tab came.
    public let startedAt: Date

    /// Starts on the current space's tabs (favorites, pinned and unpinned), most recent first. Forward
    /// highlights the previous tab, backward the least recent one. Nil when there's nothing to switch to.
    public init?(state: BrowserState, forward: Bool = true, now: Date = Date()) {
        let current = state.selectedSpace.selectedTabID
        var tabs = state.sidebarTabs(in: state.selectedSpaceIndex)
        tabs.sort { a, b in
            if a.id == current { return b.id != current }
            if b.id == current { return false }
            return a.lastActiveAt > b.lastActiveAt
        }
        guard tabs.count > 1 else { return nil }
        items = tabs.map(\.id)
        focusedIndex = forward ? 1 : tabs.count - 1
        startedAt = now
    }

    public var focusedID: UUID { items[focusedIndex] }

    /// ⌃Tab / → (forward) or ⌃⇧Tab / ← (backward), wrapping at the ends.
    public mutating func cycle(forward: Bool) {
        let n = items.count
        focusedIndex = ((focusedIndex + (forward ? 1 : -1)) % n + n) % n
    }

    public mutating func focus(_ id: UUID) {
        if let index = items.firstIndex(of: id) { focusedIndex = index }
    }

    /// The highlighted tab was closed (W): it leaves the switcher and the next one takes its place.
    /// Returns false when fewer than two are left and the switcher should close.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(of: id) else { return items.count > 1 }
        items.remove(at: index)
        if items.isEmpty { return false }
        if index < focusedIndex { focusedIndex -= 1 }
        focusedIndex = min(focusedIndex, items.count - 1)
        return items.count > 1
    }

    /// Drops tabs that are gone (closed elsewhere), keeping the highlight on the same tab when it's still there.
    public mutating func keep(_ live: Set<UUID>) -> Bool {
        let focused = focusedID
        items.removeAll { !live.contains($0) }
        if let index = items.firstIndex(of: focused) {
            focusedIndex = index
        } else {
            focusedIndex = min(focusedIndex, max(items.count - 1, 0))
        }
        return items.count > 1
    }
}
