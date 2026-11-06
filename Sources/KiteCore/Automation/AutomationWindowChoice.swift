import Foundation

/// Which normal window something with no window of its own works in: Claude's tools, links from other apps,
/// the Dock icon, web apps' and Little Kite's moved pages. Claude's tools follow one normal window (its
/// store's selection is the "front" tab and space they act on, and its pool makes the pages they drive).
/// When that window closes they move to the frontmost normal window that's still open; with none left, a
/// caller that needs one opens one rather than acting on a window that's gone.
public enum AutomationWindowChoice {
    public struct Window<ID: Hashable>: Hashable {
        public var id: ID
        /// A normal window: not incognito, Blank or Little Kite.
        public var isNormal: Bool
        /// False once the window has closed (the app may still hold its controller), until it's shown
        /// again. A window hidden while Claude works in it is still open.
        public var isOpen: Bool
        /// On screen (or minimized): not hidden while Claude works.
        public var isVisible: Bool

        public init(id: ID, isNormal: Bool, isOpen: Bool, isVisible: Bool = true) {
            self.id = id
            self.isNormal = isNormal
            self.isOpen = isOpen
            self.isVisible = isVisible
        }
    }

    public enum Pick<ID: Hashable>: Hashable {
        /// The current window still works.
        case keep
        /// Move to this window.
        case use(ID)
        /// No normal window is open: make one (only when the caller needs it).
        case openNew
    }

    /// `windows` front to back. `visibleOnly` leaves out windows hidden while Claude works (for something the
    /// user is meant to see, like Getting Started).
    public static func pick<ID: Hashable>(current: ID?, windows: [Window<ID>], visibleOnly: Bool = false) -> Pick<ID> {
        let usable = windows.filter { $0.isNormal && $0.isOpen && (!visibleOnly || $0.isVisible) }
        if let current, usable.contains(where: { $0.id == current }) { return .keep }
        return usable.first.map { .use($0.id) } ?? .openNew
    }

    /// Front to back, deterministically: windows in `screenOrder` by their place there, then the rest
    /// (hidden while Claude works, or not on screen yet) in the order they were made.
    public static func frontToBack<ID: Hashable>(_ made: [ID], screenOrder: [ID]) -> [ID] {
        var rank: [ID: Int] = [:]
        for (index, id) in screenOrder.enumerated() where rank[id] == nil { rank[id] = index }
        return made.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? (screenOrder.count + a.offset), rb = rank[b.element] ?? (screenOrder.count + b.offset)
            return ra < rb
        }.map(\.element)
    }
}

/// The handoff card's watch on the tools' store (the front tab, and which step tabs are open). The tools
/// moving to another window's store re-arms it: the old store's change callbacks carry an older generation
/// and are dropped, and the new store's first look always counts as a change.
public struct StoreWatch<Key: Equatable>: Sendable where Key: Sendable {
    public private(set) var generation = 0
    private var lastKey: Key?

    public init() {}

    /// The watch moves to another store: returns the generation its new observation carries.
    public mutating func rebind() -> Int {
        generation += 1
        lastKey = nil
        return generation
    }

    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// A look from the observation of `generation` saw `key`: true when it's current and the key changed.
    public mutating func saw(_ key: Key, generation: Int) -> Bool {
        guard isCurrent(generation), key != lastKey else { return false }
        lastKey = key
        return true
    }
}

extension AutomationCommand {
    /// Whether the call works in a browser window: its selection, its pool's pages, or its frame. The shared
    /// sidebar's spaces (list, create, describe) and reports (downloads, the network log, Kite's own `ui`) don't,
    /// and never open a window for themselves. VPN sign-in adopts its page into a window's pool, so it does.
    public var needsWindow: Bool {
        switch self {
        case .ui, .trace, .listDownloads, .networkLog, .networkRequest, .exportHAR, .handoffStatus, .formProfile,
             .listSpaces, .createSpace, .describeSpace:
            false
        case .tabsContext, .tabsCreate, .tabsClose, .switchTab, .tabStatus, .navigate, .resizeWindow, .readPage, .find,
             .getPageText, .screenshot, .click, .type, .formInput, .computer, .javascript, .waitFor, .handleDialog,
             .uploadFile, .signIn, .handoff, .readConsole, .readNetwork, .switchSpace, .pinTab, .createFolder,
             .moveToFolder, .moveToClaudeFolder, .vpn:
            true
        case .batch(let steps):
            steps.contains { $0.needsWindow }
        }
    }
}
