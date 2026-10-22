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
}

/// Find-in-page progress. Counts are nil when the engine can't report them (WebKit).
struct FindResult {
    var found: Bool
    var matches: Int?
    var activeMatch: Int?
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
    func makePage(url: URL?, restoring state: Any?) -> WebPage
}
