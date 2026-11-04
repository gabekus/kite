import Foundation
import KiteCore

/// Loads an OAuth request again when a sign-in detour brought its page back without it (`OAuthResume`).
/// Pages call it with each URL they report, on either engine; it does nothing else.
@MainActor
enum OAuthResumeTracker {
    private static var state = OAuthResume()

    /// `key` is the tab's id, or a Little Kite window's own.
    static func page(_ page: WebPage, movedTo url: URL?, key: UUID) {
        guard let request = state.observe(url, tab: key) else { return }
        NSLog("Kite: an OAuth sign-in came back to %@ without its request; loading the request again.", request.host() ?? "")
        // Out of the engine's navigation callback before starting another load.
        DispatchQueue.main.async { [weak page] in page?.load(request) }
    }

    static func forget(_ key: UUID) {
        state.forget(tab: key)
    }
}
