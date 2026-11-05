import Foundation

/// What the store learns about a page when the window's page pool registers it.
///
/// An engine starts a new page's load inside `makePage` (WebKit's `load`, Chromium's browser creation), before the
/// pool registers the page and starts listening to it. So the page's first "loading" event goes to no one: a tab
/// restored at launch on a slow URL shows the reload arrow instead of the X, and no loading glow, until the load
/// finishes. The pool reads the page's own state once it listens, and puts it in the store.
public enum PageRegistration {
    /// The loading state to put in the store for a page just registered: true when it's already loading (its first
    /// "loading" event went out unheard), nil to leave the store as it is. A page that isn't loading yet reports
    /// its load when it starts, as before.
    public static func loadingToRecord(pageIsLoading: Bool, recorded: Bool?) -> Bool? {
        guard pageIsLoading, recorded != true else { return nil }
        return true
    }
}
