import Foundation

/// Which browser window Claude's tools work in. They follow one normal window (its store's selection
/// is the "front" tab and space they act on, and its pool makes the pages they drive). When that window
/// closes they move to the frontmost normal window that's still open; with none left, a tool call opens
/// one rather than acting on a window that's gone.
public enum AutomationWindowChoice {
    public struct Window<ID: Hashable>: Hashable {
        public var id: ID
        /// A normal window: not incognito, Blank or Little Kite.
        public var isNormal: Bool
        /// False once the window has closed (the app may still hold its controller). A window hidden
        /// while Claude works in it is still open.
        public var isOpen: Bool

        public init(id: ID, isNormal: Bool, isOpen: Bool) {
            self.id = id
            self.isNormal = isNormal
            self.isOpen = isOpen
        }
    }

    public enum Pick<ID: Hashable>: Hashable {
        /// The current window still works.
        case keep
        /// Move to this window.
        case use(ID)
        /// No normal window is open: make one (only when a tool needs it).
        case openNew
    }

    /// `windows` front to back.
    public static func pick<ID: Hashable>(current: ID?, windows: [Window<ID>]) -> Pick<ID> {
        let usable = windows.filter { $0.isNormal && $0.isOpen }
        if let current, usable.contains(where: { $0.id == current }) { return .keep }
        return usable.first.map { .use($0.id) } ?? .openNew
    }
}

extension AutomationCommand {
    /// Whether the call works in a browser window (its tabs, selection, pages or frame). Reports that don't
    /// (downloads, the network log, VPN, Kite's own `ui`) never open a window for themselves.
    public var needsWindow: Bool {
        switch self {
        case .ui, .listDownloads, .networkLog, .networkRequest, .exportHAR, .vpn, .handoffStatus: false
        case .batch(let steps): steps.contains { $0.needsWindow }
        default: true
        }
    }
}
