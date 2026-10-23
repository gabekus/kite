import AppKit

/// What a page reports back to the browser.
enum PageEvent {
    case title(String?)
    case url(URL?)
    case favicon(URL?)
    case progress(Double)
    case navigationState(isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    case openInNewTab(URL, foreground: Bool)
    /// A popup the page opened (window.open, target=_blank). It becomes a new tab.
    case popup(WebPage)
    case closeRequested
    /// Requests the ad blocker stopped since the page started loading.
    case blockedCount(Int)
    /// The page's process died; the tab shows the crashed-tab page until it loads again.
    case crashed(code: Int)
    /// SPIKE: Kite's own "Add to Kite" button on a Google result was clicked
    /// (validated natively); open the store page and start its Add flow there.
    case addExtension(id: String)
}

/// Find-in-page progress. Counts are nil when the engine can't report them (WebKit).
struct FindResult {
    var found: Bool
    var matches: Int?
    var activeMatch: Int?
}

enum SiteDataKind {
    case cookies
    case cache
}

/// One tab's web content, independent of the engine behind it.
@MainActor
protocol WebPage: AnyObject {
    var view: NSView { get }
    var onEvent: ((PageEvent) -> Void)? { get set }
    var isLoading: Bool { get }
    /// 1.0 = 100%.
    var zoomFactor: Double { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    /// ⇧⌘R: reload without the HTTP cache.
    func reloadIgnoringCache()
    func stopLoading()
    func focus()
    /// Offscreen pages should throttle rendering and timers.
    func setVisible(_ visible: Bool)
    func showDevTools()
    /// Highlights matches of `text`. `findNext` moves through matches of the same text;
    /// `completion` may run more than once as results come in.
    func find(_ text: String, forward: Bool, findNext: Bool, completion: @escaping (FindResult) -> Void)
    func stopFinding()
    func printPage()
    /// The page as one file for Save Page As: MHTML on Chromium, a web archive on WebKit.
    func archive(completion: @escaping (_ data: Data?, _ fileExtension: String) -> Void)
    /// Clears one site's cookies or cache (Arc's "Clear … and Refresh"). Reloading is up to the caller.
    func clearSiteData(_ kind: SiteDataKind, for url: URL, completion: @escaping () -> Void)
    func setForceDark(_ enabled: Bool)
    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void)
    /// Engine-specific state for restoring history after hibernation, if supported.
    func hibernationState() -> Any?
    /// Whether the page is playing media or using the camera or mic (don't hibernate it).
    func checkBusy(_ completion: @escaping (Bool) -> Void)
    func close()
}

@MainActor
protocol WebEngine: AnyObject {
    var name: String { get }
    var supportsDevTools: Bool { get }
    var supportsDarkPages: Bool { get }
    /// Whether the engine reports how many requests it blocked (WebKit can't).
    var countsBlockedRequests: Bool { get }
    /// Hooks the engine up to the ad blocker; called once at launch.
    func attach(_ adblocker: Adblocker)
    func makePage(url: URL?, restoring state: Any?) -> WebPage
    /// A sibling engine whose cookies, cache and storage live in memory only (incognito).
    func makeEphemeral() -> WebEngine
}
