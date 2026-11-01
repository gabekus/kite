import AppKit
import KiteCore

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
    /// A link the user clicked opens in Arc's Peek card instead (`WebPage.linkPeekPolicy` said so); the
    /// page didn't navigate.
    case openInLinkPeek(URL)
    case closeRequested
    /// Requests the ad blocker stopped since the page started loading.
    case blockedCount(Int)
    /// The page's process died; the tab shows the crashed-tab page until it loads again.
    case crashed(code: Int)
    /// Kite's own "Add to Kite" button on a Google result was clicked (checked by the
    /// engine): install that Chrome Web Store extension without leaving the page.
    case addExtension(id: String)
    /// The pointer moved onto a link (nil: off it). Drives ⇧-hover link previews.
    case linkHover(LinkHover?)
}

/// The link under the pointer, as the engine reports it.
struct LinkHover {
    var url: URL
    /// The link's box in screen coordinates, when the engine knows it (WebKit).
    var screenRect: NSRect?
    /// The modifier keys of the move that reported it, when the engine knows them (WebKit).
    var modifiers: NSEvent.ModifierFlags?
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
    /// Asked when the user clicks a link to `url` (in this page or a new one, `shift` held or not): true
    /// cancels it and reports `.openInLinkPeek`. Nil (the default) never peeks.
    var linkPeekPolicy: ((_ url: URL, _ shift: Bool) -> Bool)? { get set }
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
    /// The command bar took the keyboard: the page mustn't take it back until `focus` or `allowFocus`.
    func blur()
    func allowFocus()
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
    /// The permission the profile stores for `url`'s site (Chromium content settings); nil
    /// where the engine keeps none Kite can read (WebKit asks every time, through macOS).
    func sitePermission(_ permission: SitePermission, for url: URL) -> SitePermissionValue?
    func setSitePermission(_ permission: SitePermission, _ value: SitePermissionValue, for url: URL)
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
