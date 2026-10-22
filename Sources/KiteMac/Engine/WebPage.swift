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
    func stopLoading()
    func focus()
    /// Offscreen pages should throttle rendering and timers.
    func setVisible(_ visible: Bool)
    func showDevTools()
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
}
