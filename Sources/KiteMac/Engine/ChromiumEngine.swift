#if canImport(CEFBridge)
import AppKit
import CEFBridge

/// Chromium via CEF: Chrome's engine, Chrome DevTools, and an optional CDP port.
@MainActor
final class ChromiumEngine: WebEngine {
    let name = "Chromium"
    let supportsDevTools = true
    let supportsDarkPages = true
    var countsBlockedRequests: Bool { KCRuntime.supportsAdblock }
    private var adblocker: Adblocker?

    func makePage(url: URL?, restoring state: Any?) -> WebPage {
        // CEF has no equivalent of WebKit's interactionState, so a revived tab reloads its URL.
        ChromiumPage(browser: KCBrowser(url: url, delegate: ChromiumDelegateProxy.placeholder), adblocker: adblocker)
    }

    func attach(_ adblocker: Adblocker) {
        self.adblocker = adblocker
        guard KCRuntime.supportsAdblock else { return }
        #if canImport(KiteAdblock)
        // The network thread holds the engine object until its last request is checked.
        adblocker.onEngineChange.append { [unowned adblocker] in
            let engine = adblocker.engine
            KCRuntime.setAdblockEngine(engine.map { UnsafeMutableRawPointer($0.pointer) }, owner: engine)
        }
        #endif
        adblocker.onPolicyChange.append { [unowned adblocker] in
            KCRuntime.setAdblockEnabled(adblocker.isEnabled, allowedHosts: adblocker.allowedHosts)
        }
        KCRuntime.setAdblockEnabled(adblocker.isEnabled, allowedHosts: adblocker.allowedHosts)
    }
}

@MainActor
final class ChromiumPage: NSObject, WebPage, KCBrowserDelegate {
    let browser: KCBrowser
    var onEvent: ((PageEvent) -> Void)?
    private var mediaInUse = false
    private let adblocker: Adblocker?
    private var address: URL?
    /// Bumped per load so a page that navigated away stops being polled.
    private var cosmeticGeneration = 0

    /// When to collect the classes and ids a page queued after it loads: right
    /// away, then a few more times to catch ads that arrive late.
    private static let cosmeticPolls: [TimeInterval] = [0, 1, 3, 8]

    /// Media elements that are currently playing; used to keep music tabs alive.
    private static let playingMediaScript =
        "[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && m.readyState > 2)"

    init(browser: KCBrowser, adblocker: Adblocker?) {
        self.browser = browser
        self.adblocker = adblocker
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
    func stopLoading() { browser.stopLoading() }
    func focus() { browser.focus() }
    func setVisible(_ visible: Bool) { browser.setHidden(!visible) }
    func showDevTools() { browser.showDevTools() }
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
    func browser(_ browser: KCBrowser, addressDidChange url: URL) {
        address = url
        onEvent?(.url(url))
    }
    func browser(_ browser: KCBrowser, faviconDidChange url: URL?) { onEvent?(.favicon(url)) }
    func browser(_ browser: KCBrowser, progressDidChange progress: Double) { onEvent?(.progress(progress)) }

    func browserLoadingStateDidChange(_ browser: KCBrowser) {
        onEvent?(.navigationState(isLoading: browser.isLoading, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward))
        cosmeticGeneration += 1
        if !browser.isLoading { pollCosmetics(generation: cosmeticGeneration) }
    }

    /// Generic hiding rules depend on the classes and ids a page uses, which only
    /// the page knows; it queues them and this collects them.
    private func pollCosmetics(generation: Int) {
        guard let adblocker, adblocker.blocks(address) else { return }
        for delay in Self.cosmeticPolls {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.cosmeticGeneration == generation else { return }
                self.browser.evaluateJavaScript(adblocker.drainScript) { [weak self] result in
                    guard let self, self.cosmeticGeneration == generation, let payload = result as? String,
                          let script = adblocker.genericHidingScript(payload: payload, pageURL: self.address) else { return }
                    self.browser.evaluateJavaScript(script) { _ in }
                }
            }
        }
    }

    func browser(_ browser: KCBrowser, mediaAccessDidChange inUse: Bool) { mediaInUse = inUse }

    func browser(_ browser: KCBrowser, openURLInNewTab url: URL, foreground: Bool) {
        onEvent?(.openInNewTab(url, foreground: foreground))
    }

    func browser(_ browser: KCBrowser, didCreatePopup popup: KCBrowser, url: URL?) {
        onEvent?(.popup(ChromiumPage(browser: popup, adblocker: adblocker)))
    }

    func browserDidRequestClose(_ browser: KCBrowser) { onEvent?(.closeRequested) }

    @objc(browser:blockedCountDidChange:)
    func browser(_ browser: KCBrowser, blockedCountDidChange count: Int) { onEvent?(.blockedCount(count)) }

    @objc(browser:documentStartScriptForURL:)
    func browser(_ browser: KCBrowser, documentStartScriptFor url: URL) -> String? {
        adblocker?.documentStartScript(for: url)
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
