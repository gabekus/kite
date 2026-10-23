import AppKit
import WebKit

/// System WebKit. Small and light on battery; used for `swift run` and as a fallback.
@MainActor
final class WebKitEngine: WebEngine {
    let name = "WebKit"
    let supportsDevTools = false
    let supportsDarkPages = false
    let countsBlockedRequests = false

    private let configuration: WKWebViewConfiguration
    private let downloads = DownloadCoordinator()
    private var contentRules: WebKitContentRules?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Without a Safari token some sites serve a degraded page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        Self.allowFullRefreshRate(configuration.preferences)
        self.configuration = configuration
    }

    func attach(_ adblocker: Adblocker) {
        guard Adblocker.isAvailable else { return }
        contentRules = WebKitContentRules(adblocker: adblocker)
    }

    /// WebKit holds pages near 60fps unless its internal "Prefer Page Rendering
    /// Updates near 60fps" feature is off. It's private API, so look it up
    /// defensively and leave WebKit alone if it's missing.
    private static func allowFullRefreshRate(_ preferences: WKPreferences) {
        let features = NSSelectorFromString("_features")
        let setEnabled = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: features), preferences.responds(to: setEnabled),
              let list = WKPreferences.perform(features)?.takeUnretainedValue() as? [NSObject],
              let feature = list.first(where: {
                  $0.responds(to: NSSelectorFromString("key"))
                      && $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled"
              })
        else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let set = unsafeBitCast(preferences.method(for: setEnabled), to: SetEnabled.self)
        set(preferences, setEnabled, false, feature)
    }

    func makePage(url: URL?, restoring state: Any?) -> WebPage {
        // A copy, since the page swaps in its own content controller.
        let page = WebKitPage(configuration: configuration.copy() as! WKWebViewConfiguration, downloads: downloads, contentRules: contentRules)
        if let state {
            page.webView.interactionState = state
        } else if let url {
            page.load(url)
        }
        return page
    }
}

@MainActor
final class WebKitPage: NSObject, WebPage {
    let webView: WKWebView
    var onEvent: ((PageEvent) -> Void)?
    private let downloads: DownloadCoordinator
    private let contentRules: WebKitContentRules?
    private var observations: [NSKeyValueObservation] = []

    private static let inPageSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
    private static let faviconScript = """
        (() => {
          const link = document.querySelector('link[rel~="icon"][href], link[rel="apple-touch-icon"][href]');
          return link ? link.href : location.origin + '/favicon.ico';
        })()
        """

    init(configuration: WKWebViewConfiguration, downloads: DownloadCoordinator, contentRules: WebKitContentRules?) {
        // Each page gets its own content controller so ad-block rules can differ per site.
        if let contentRules {
            configuration.userContentController = contentRules.makeController()
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.downloads = downloads
        self.contentRules = contentRules
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    var view: NSView { webView }
    var isLoading: Bool { webView.isLoading }

    var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func reloadIgnoringCache() { webView.reloadFromOrigin() }
    func stopLoading() { webView.stopLoading() }
    func focus() { webView.window?.makeFirstResponder(webView) }
    // WebKit throttles views that aren't in a window on its own.
    func setVisible(_ visible: Bool) {}
    // Web Inspector opens from the context menu; there's no public API to open it.
    func showDevTools() {}
    // No public force-dark API in WebKit.
    func setForceDark(_ enabled: Bool) {}

    func find(_ text: String, forward: Bool, findNext: Bool, completion: @escaping (FindResult) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { completion(FindResult(found: $0.matchFound)) }
    }

    /// WebKit's find only selects the match, and Arc leaves that selection on the page.
    func stopFinding() {}

    func archive(completion: @escaping (Data?, String) -> Void) {
        webView.createWebArchiveData { completion(try? $0.get(), "webarchive") }
    }

    func clearSiteData(_ kind: SiteDataKind, for url: URL, completion: @escaping () -> Void) {
        guard let host = url.host() else { return completion() }
        let store = webView.configuration.websiteDataStore
        let types: Set<String> = kind == .cookies
            ? [WKWebsiteDataTypeCookies]
            : [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        store.fetchDataRecords(ofTypes: types) { records in
            // Records are grouped by registrable domain ("example.com" covers "www.example.com").
            let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: matching, completionHandler: completion)
        }
    }

    func printPage() {
        guard let window = webView.window else { return }
        let operation = webView.printOperation(with: .shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(script) { result, _ in completion(result) }
    }

    func hibernationState() -> Any? { webView.interactionState }

    func checkBusy(_ completion: @escaping (Bool) -> Void) {
        if webView.cameraCaptureState == .active || webView.microphoneCaptureState == .active {
            return completion(true)
        }
        webView.requestMediaPlaybackState { completion($0 == .playing) }
    }

    func close() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func observe() {
        // KVO on WKWebView fires on the main thread.
        func send<Value>(
            _ event: @escaping @Sendable @MainActor (WKWebView) -> PageEvent
        ) -> @Sendable (WKWebView, NSKeyValueObservedChange<Value>) -> Void {
            { [weak self] webView, _ in MainActor.assumeIsolated { self?.onEvent?(event(webView)) } }
        }
        let navigationState: @Sendable @MainActor (WKWebView) -> PageEvent = {
            .navigationState(isLoading: $0.isLoading, canGoBack: $0.canGoBack, canGoForward: $0.canGoForward)
        }
        observations = [
            webView.observe(\.title, changeHandler: send { .title($0.title) }),
            webView.observe(\.url, changeHandler: send { .url($0.url) }),
            webView.observe(\.estimatedProgress, changeHandler: send { .progress($0.estimatedProgress) }),
            webView.observe(\.isLoading, changeHandler: send(navigationState)),
            webView.observe(\.canGoBack, changeHandler: send(navigationState)),
            webView.observe(\.canGoForward, changeHandler: send(navigationState)),
        ]
    }
}

extension WebKitPage: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

        if let scheme = url.scheme?.lowercased(), !Self.inPageSchemes.contains(scheme) {
            // mailto:, zoommtg:, etc. belong to other apps.
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }

        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated && flags.contains(.command) {
            // ⌘-click opens in the background, ⇧⌘-click opens and switches.
            onEvent?(.openInNewTab(url, foreground: flags.contains(.shift)))
            return decisionHandler(.cancel)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            contentRules?.apply(to: webView.configuration.userContentController, url: url)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.faviconScript) { [weak self] result, _ in
            guard let href = result as? String else { return }
            self?.onEvent?(.favicon(URL(string: href)))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension WebKitPage: WKUIDelegate {
    /// The popup must use WebKit's configuration so it keeps `window.opener`.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WebKitPage(configuration: configuration, downloads: downloads, contentRules: contentRules)
        onEvent?(.popup(popup))
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onEvent?(.closeRequested)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

/// Saves WebKit downloads to ~/Downloads without overwriting existing files.
@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        completionHandler(Self.uniqueURL(in: directory, name: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}
