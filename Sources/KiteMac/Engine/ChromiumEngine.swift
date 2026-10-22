#if canImport(CEFBridge)
import AppKit
import CEFBridge

/// Chromium via CEF: Chrome's engine, Chrome DevTools, and an optional CDP port.
@MainActor
final class ChromiumEngine: WebEngine {
    let name = "Chromium"
    let supportsDevTools = true
    let supportsDarkPages = true

    func makePage(url: URL?, restoring state: Any?) -> WebPage {
        // CEF has no equivalent of WebKit's interactionState, so a revived tab reloads its URL.
        ChromiumPage(browser: KCBrowser(url: url, delegate: ChromiumDelegateProxy.placeholder))
    }
}

@MainActor
final class ChromiumPage: NSObject, WebPage, KCBrowserDelegate {
    let browser: KCBrowser
    var onEvent: ((PageEvent) -> Void)?
    private var mediaInUse = false
    private var findCompletion: ((FindResult) -> Void)?

    /// Media elements that are currently playing; used to keep music tabs alive.
    private static let playingMediaScript =
        "[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && m.readyState > 2)"

    init(browser: KCBrowser) {
        self.browser = browser
        super.init()
        browser.delegate = self
    }

    var view: NSView { browser.view }
    var isLoading: Bool { browser.isLoading }

    var zoomFactor: Double {
        get { browser.zoomFactor }
        set { browser.zoomFactor = newValue }
    }

    func load(_ url: URL) { browser.load(url) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { browser.reload() }
    func reloadIgnoringCache() { browser.reloadIgnoringCache() }
    func stopLoading() { browser.stopLoading() }
    func focus() { browser.focus() }
    func setVisible(_ visible: Bool) { browser.setHidden(!visible) }
    func showDevTools() { browser.showDevTools() }

    func find(_ text: String, forward: Bool, findNext: Bool, completion: @escaping (FindResult) -> Void) {
        findCompletion = completion
        browser.find(text, forward: forward, findNext: findNext)
        // A new search only highlights; stepping once makes the first match active (1/N), like Chrome.
        if !findNext { browser.find(text, forward: forward, findNext: true) }
    }

    func stopFinding() {
        findCompletion = nil
        browser.stopFinding()
    }

    func printPage() { browser.print() }
    func setForceDark(_ enabled: Bool) { browser.setForceDark(enabled) }

    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void) {
        browser.evaluateJavaScript(script, completion: completion)
    }

    func hibernationState() -> Any? { nil }

    func checkBusy(_ completion: @escaping (Bool) -> Void) {
        if mediaInUse { return completion(true) }
        browser.evaluateJavaScript(Self.playingMediaScript) { completion(($0 as? Bool) ?? false) }
    }

    func close() {
        browser.close()
        browser.view.removeFromSuperview()
    }

    // MARK: KCBrowserDelegate

    func browser(_ browser: KCBrowser, titleDidChange title: String) { onEvent?(.title(title)) }
    func browser(_ browser: KCBrowser, addressDidChange url: URL) { onEvent?(.url(url)) }
    func browser(_ browser: KCBrowser, faviconDidChange url: URL?) { onEvent?(.favicon(url)) }
    func browser(_ browser: KCBrowser, progressDidChange progress: Double) { onEvent?(.progress(progress)) }

    func browserLoadingStateDidChange(_ browser: KCBrowser) {
        onEvent?(.navigationState(isLoading: browser.isLoading, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward))
    }

    func browser(_ browser: KCBrowser, mediaAccessDidChange inUse: Bool) { mediaInUse = inUse }

    func browser(_ browser: KCBrowser, openURLInNewTab url: URL, foreground: Bool) {
        onEvent?(.openInNewTab(url, foreground: foreground))
    }

    func browser(_ browser: KCBrowser, didCreatePopup popup: KCBrowser, url: URL?) {
        onEvent?(.popup(ChromiumPage(browser: popup)))
    }

    func browserDidRequestClose(_ browser: KCBrowser) { onEvent?(.closeRequested) }

    func browser(_ browser: KCBrowser, findResultCount count: Int32, activeMatch: Int32, final: Bool) {
        findCompletion?(FindResult(found: count > 0, matches: Int(count), activeMatch: Int(activeMatch)))
    }
}

/// KCBrowser wants a delegate at init; ChromiumPage replaces it right away.
private final class ChromiumDelegateProxy: NSObject, KCBrowserDelegate {
    @MainActor static let placeholder = ChromiumDelegateProxy()
    func browser(_ browser: KCBrowser, titleDidChange title: String) {}
    func browser(_ browser: KCBrowser, addressDidChange url: URL) {}
    func browser(_ browser: KCBrowser, faviconDidChange url: URL?) {}
    func browser(_ browser: KCBrowser, progressDidChange progress: Double) {}
    func browserLoadingStateDidChange(_ browser: KCBrowser) {}
    func browser(_ browser: KCBrowser, mediaAccessDidChange inUse: Bool) {}
    func browser(_ browser: KCBrowser, openURLInNewTab url: URL, foreground: Bool) {}
    func browser(_ browser: KCBrowser, didCreatePopup popup: KCBrowser, url: URL?) {}
    func browserDidRequestClose(_ browser: KCBrowser) {}
}
#endif
