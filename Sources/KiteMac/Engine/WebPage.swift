import AppKit
import KiteCore

extension NSPrintInfo {
    /// A copy of the app's print settings (paper, printer) for printing one page, with Chrome's
    /// margins, so the shared settings only change when someone picks Page Setup.
    static func printInfoForPage() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let margin = PagePrint.marginInches * 72
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

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
    /// A link ⌥⌘-clicked in the page opens in a new Split View pane next to this tab (`LinkClick`).
    case openInSplit(URL)
    /// A link ⌥⌘-clicked in the page opens in Little Kite (Settings › Links, `LinkClick`).
    case openInLittleKite(URL)
    case closeRequested
    /// Requests the ad blocker stopped since the page started loading.
    case blockedCount(Int)
    /// The page's process died; the tab shows the crashed-tab page until it loads again.
    case crashed(code: Int)
    /// Kite's own "Add to Kite" button on a Google result was clicked (checked by the
    /// engine): install that Chrome Web Store extension without leaving the page.
    case addExtension(id: String)
    /// What the page is playing changed (MediaStateScript); nil when it has no media.
    case media(MediaState?)
    /// The page's call controls changed (MediaStateScript's Media Session report).
    case callControls(CallControls)
    /// The page started or stopped using the camera or microphone (the engine's capture state).
    case capturing(Bool)
    /// The pointer moved onto a link (nil: off it). Drives ⇧-hover link previews.
    case linkHover(LinkHover?)
    /// An "Open Link in …" item of the page's right-click menu (Arc's link items).
    case openLink(URL, PageContextMenu.LinkTarget)
    /// Save As…, Print… or View Page Source from the page's right-click menu.
    case pageCommand(PageContextMenu.PageCommand)
    /// The site asks for the camera, microphone, location or notifications: Arc's prompt.
    case permissionRequest(PermissionRequest)
    /// The engine dropped the prompt with this id itself (the page navigated or closed).
    case permissionRequestCancelled(id: Int)
}

/// A site's permission request waiting for an answer. `respond(true)` allows and `false` blocks,
/// both stored for the site where the engine keeps them (Chromium; Site Controls shows them); nil
/// dismisses without storing anything. Call it once.
struct PermissionRequest {
    let id: Int
    let origin: URL
    let permissions: [SitePermission]
    let respond: (Bool?) -> Void
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
    /// What the page's window can do with a link, asked as the right-click menu opens. Nil: a
    /// tab in a normal window.
    var contextMenuHost: (() -> PageContextMenu.Host)? { get set }
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
    /// Opens DevTools (Web Inspector on WebKit) on `panel`.
    func showDevTools(_ panel: DevToolsPanel)
    /// Highlights matches of `text`. `findNext` moves through matches of the same text;
    /// `completion` may run more than once as results come in.
    func find(_ text: String, forward: Bool, findNext: Bool, completion: @escaping (FindResult) -> Void)
    func stopFinding()
    /// File › Print: the page as an AppKit print operation, which the window runs as its print
    /// sheet with a page preview. nil when the page can't be printed.
    func makePrintOperation(_ completion: @escaping (NSPrintOperation?) -> Void)
    /// The page as one file for Save Page As: MHTML on Chromium, a web archive on WebKit.
    func archive(completion: @escaping (_ data: Data?, _ fileExtension: String) -> Void)
    /// A PNG of the page for Capture: `area` (points from the view's top-left corner) at device
    /// resolution, or with nil the whole page, beyond the viewport.
    func captureImage(area: CGRect?, completion: @escaping (Data?) -> Void)
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
    /// Asks the page's media (the element that played last) to play, pause, change track or
    /// enter picture in picture, as if you'd clicked.
    func runMediaCommand(_ command: MediaCommand)
    /// The browser's tab mute: the page keeps playing, silently, and isn't told.
    var isAudioMuted: Bool { get set }
    /// The pid of the process rendering the page, for the Task Manager; nil when unknown.
    var processIdentifier: pid_t? { get }
    /// Bytes the page's requests have received and sent so far, for the Task Manager's Network
    /// column; nil when the engine can't count them.
    var networkBytes: UInt64? { get }
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
    /// The engine for `profile`'s pages (Profiles.swift): its own cookies, logins, history and
    /// extensions. The same object every time for one profile; the default profile's is the
    /// app's own engine.
    func forProfile(_ profile: Profile) -> WebEngine
    /// The profile folder this engine's pages use; nil for incognito.
    var profileDirectory: String? { get }
}
