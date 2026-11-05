import Foundation

/// A tab's saved navigation state (its back/forward list, as a sleeping or relaunched tab gets it back) only counts
/// when it holds a page.
///
/// A page that never committed a load (still waiting on a slow or offline site, or never asked to load) still has
/// an engine state, with an empty back/forward list. Saved (5 s after its URL first changes, when it sleeps, on
/// quit) and restored, that state has nothing to go back to: the tab stays blank and never loads its URL, and saves
/// the same empty state again, so it's blank on every relaunch. So such a state isn't kept, and a restored state
/// that brings back no page falls back to loading the tab's URL.
public enum PageRestore {
    /// Whether to keep a page's state for later: only when it has a committed page (a current back/forward item).
    public static func keepsState(hasCurrentItem: Bool) -> Bool { hasCurrentItem }

    /// After restoring a state: whether to load the tab's URL instead, because the state brought back no page (no
    /// current item, no URL, nothing loading). A state that restored a page keeps it, with its back/forward list.
    public static func loadsURLAfterRestoring(hasURL: Bool, restoredCurrentItem: Bool, restoredURL: Bool,
                                             restoredLoading: Bool) -> Bool {
        hasURL && !restoredCurrentItem && !restoredURL && !restoredLoading
    }

    /// Where a new page's state came from, for a test run's diagnostics.
    public enum Source: String, Sendable {
        case none
        case thisWindow = "this window (asleep)"
        case anotherWindow = "another window (asleep)"
        case file = "Tab History file"
    }
}
