#if canImport(CEFBridge)
import AppKit
import CEFBridge
import KiteCore
import PDFKit

/// Chromium via CEF: Chrome's engine, Chrome DevTools, and an optional CDP port.
@MainActor
final class ChromiumEngine: WebEngine {
    let name = "Chromium"
    let supportsDevTools = true
    let supportsDarkPages = true
    var countsBlockedRequests: Bool { KCRuntime.supportsAdblock }
    private var adblocker: Adblocker?
    /// nil is the persistent profile.
    private let context: KCRequestContext?

    init(context: KCRequestContext? = nil) {
        self.context = context
    }

    func makePage(url: URL?, restoring state: Any?) -> WebPage {
        // CEF has no equivalent of WebKit's interactionState, so a revived tab reloads its URL.
        ChromiumPage(
            browser: KCBrowser(url: url, delegate: ChromiumDelegateProxy.placeholder, context: context),
            adblocker: adblocker
        )
    }

    /// Shares the ad blocker, whose engine and policy are already wired up process-wide.
    func makeEphemeral() -> WebEngine {
        let engine = ChromiumEngine(context: .incognito())
        engine.adblocker = adblocker
        return engine
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
    var linkPeekPolicy: ((URL, Bool) -> Bool)?
    private var mediaInUse = false
    private let adblocker: Adblocker?
    private var address: URL?
    /// Bumped per load so a page that navigated away stops being polled.
    private var cosmeticGeneration = 0

    /// When to collect the classes and ids a page queued after it loads: right
    /// away, then a few more times to catch ads that arrive late.
    private static let cosmeticPolls: [TimeInterval] = [0, 1, 3, 8]
    private var findCompletion: ((FindResult) -> Void)?
    private var historySwipe: HistorySwipeController?

    /// Media elements that are currently playing; used to keep music tabs alive.
    private static let playingMediaScript =
        "[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && m.readyState > 2)"

    init(browser: KCBrowser, adblocker: Adblocker?) {
        self.browser = browser
        self.adblocker = adblocker
        super.init()
        browser.delegate = self
        prepareVerificationCodes()
        ZapInjection.attach(to: self)
        historySwipe = HistorySwipeController(
            view: browser.view,
            canNavigate: { [weak browser] in $0 == .back ? browser?.canGoBack == true : browser?.canGoForward == true },
            navigate: { [weak browser] in $0 == .back ? browser?.goBack() : browser?.goForward() },
            evaluate: { [weak browser] script, completion in
                guard let browser else { return completion(nil) }
                browser.evaluateJavaScript(script, completion: completion)
            },
            zoomFactor: { [weak browser] in browser?.zoomFactor ?? 1 }
        )
    }

    /// Every page gets Kite's code-field script in its own world (VerificationCodeScript);
    /// the binding exists only there, so pages can't ask for codes themselves.
    private func prepareVerificationCodes() {
        browser.pageFeatureEventHandler = { [weak self] method, params in self?.handlePageFeatureEvent(method, params) }
        browser.executeDevToolsMethod(
            "Runtime.addBinding",
            params: ["name": VerificationCodeScript.bindingName, "executionContextName": VerificationCodeScript.worldName],
            completion: nil
        )
        browser.executeDevToolsMethod("Page.enable", params: nil, completion: nil)
        browser.executeDevToolsMethod(
            "Page.addScriptToEvaluateOnNewDocument",
            params: ["source": VerificationCodeScript.source, "worldName": VerificationCodeScript.worldName],
            completion: nil
        )
        prepareMediaState()
    }

    /// The media script reports what the page plays (MediaStateScript) from its own world;
    /// the page hook runs in the page's world to reach its Media Session handlers.
    private func prepareMediaState() {
        browser.executeDevToolsMethod(
            "Runtime.addBinding",
            params: ["name": MediaStateScript.bindingName, "executionContextName": MediaStateScript.worldName],
            completion: nil
        )
        browser.executeDevToolsMethod("Page.addScriptToEvaluateOnNewDocument", params: ["source": MediaStateScript.pageHook], completion: nil)
        browser.executeDevToolsMethod(
            "Page.addScriptToEvaluateOnNewDocument",
            params: ["source": MediaStateScript.source, "worldName": MediaStateScript.worldName],
            completion: nil
        )
    }

    /// The media script's execution context, from its latest report; commands run there.
    private var mediaContext: Int?

    func runMediaCommand(_ command: MediaCommand) {
        guard let mediaContext else { return }
        // As if you'd clicked: play() and requestPictureInPicture() need a user gesture.
        let params: [String: Any] = ["expression": command.script, "contextId": mediaContext, "userGesture": true]
        browser.callDevToolsMethod("Runtime.evaluate", params: params) { _, _ in }
    }

    /// As the renderer last reported it (KiteHelper sends its pid with each main-frame script context).
    var processIdentifier: pid_t? {
        let pid = browser.renderProcessIdentifier
        return pid > 0 ? pid : nil
    }

    var isAudioMuted: Bool {
        get { browser.audioMuted }
        set { browser.audioMuted = newValue }
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
    func blur() { browser.blur() }
    func allowFocus() { browser.allowFocus() }
    func setVisible(_ visible: Bool) { browser.setHidden(!visible) }
    func showDevTools(_ panel: DevToolsPanel) { browser.showDevToolsRunningFrontendScript(panel.chromiumFrontendScript) }

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

    /// Chromium's own print path for a child browser is an app-modal panel with no preview, so the
    /// page is printed to PDF on the sheet's paper and PDFKit prints that, preview included.
    func makePrintOperation(_ completion: @escaping (NSPrintOperation?) -> Void) {
        let info = NSPrintInfo.printInfoForPage()
        let params = PagePrint.pdfParameters(paperWidthPoints: Double(info.paperSize.width),
                                             paperHeightPoints: Double(info.paperSize.height))
        browser.executeDevToolsMethod("Page.printToPDF", params: params) { result in
            guard let encoded = result?["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let document = PDFDocument(data: data) else { return completion(nil) }
            // The PDF already carries the margins.
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            completion(document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true))
        }
    }

    func archive(completion: @escaping (Data?, String) -> Void) {
        browser.executeDevToolsMethod("Page.captureSnapshot", params: ["format": "mhtml"]) { result in
            completion((result?["data"] as? String)?.data(using: .utf8), "mhtml")
        }
    }

    func captureImage(area: CGRect?, completion: @escaping (Data?) -> Void) {
        let viewWidth = Double(browser.view.bounds.width)
        let deviceScale = Double(browser.view.window?.backingScaleFactor ?? 2)
        browser.callDevToolsMethod("Page.getLayoutMetrics", params: nil) { [weak self] metrics, _ in
            guard let self, let metrics else { return completion(nil) }
            let visual = metrics["cssVisualViewport"] as? [String: Any] ?? [:]
            let pageX = visual["pageX"] as? Double ?? 0, pageY = visual["pageY"] as? Double ?? 0
            let cssWidth = visual["clientWidth"] as? Double ?? viewWidth
            var params: [String: Any] = ["format": "png"]
            if let area {
                // View points to CSS pixels (page zoom); clip scale 1 keeps device resolution.
                let k = viewWidth > 0 ? cssWidth / viewWidth : 1
                params["clip"] = ["x": pageX + Double(area.minX) * k, "y": pageY + Double(area.minY) * k,
                                  "width": Double(area.width) * k, "height": Double(area.height) * k, "scale": 1]
            } else {
                let content = metrics["cssContentSize"] as? [String: Any] ?? [:]
                let width = content["width"] as? Double ?? cssWidth
                let height = content["height"] as? Double ?? (visual["clientHeight"] as? Double ?? 0)
                let scale = Capture.fullPageScale(contentHeight: height, deviceScale: deviceScale)
                params["clip"] = ["x": 0, "y": 0, "width": width, "height": height, "scale": scale]
                params["captureBeyondViewport"] = true
            }
            self.browser.callDevToolsMethod("Page.captureScreenshot", params: params) { result, _ in
                completion((result?["data"] as? String).flatMap { Data(base64Encoded: $0) })
            }
        }
    }

    func clearSiteData(_ kind: SiteDataKind, for url: URL, completion: @escaping () -> Void) {
        guard let scheme = url.scheme, let host = url.host() else { return completion() }
        let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        let types = kind == .cookies ? "cookies" : "cache_storage,service_workers"
        browser.executeDevToolsMethod("Storage.clearDataForOrigin", params: ["origin": origin, "storageTypes": types]) { _ in
            completion()
        }
    }
    func setForceDark(_ enabled: Bool) { browser.setForceDark(enabled) }

    func sitePermission(_ permission: SitePermission, for url: URL) -> SitePermissionValue? {
        switch browser.sitePermission(Self.bridged(permission), for: Self.site(url)) {
        case .allow: .allow
        case .block: .block
        default: .ask
        }
    }

    func setSitePermission(_ permission: SitePermission, _ value: SitePermissionValue, for url: URL) {
        let bridged: KCSitePermissionValue = switch value {
        case .allow: .allow
        case .block: .block
        case .ask: .default
        }
        browser.setSitePermission(Self.bridged(permission), value: bridged, for: Self.site(url))
    }

    /// Content settings are per origin.
    private static func site(_ url: URL) -> URL {
        SiteControls.origin(of: url).flatMap(URL.init(string:)) ?? url
    }

    private static func bridged(_ permission: SitePermission) -> KCSitePermission {
        switch permission {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .notifications: .notifications
        }
    }

    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void) {
        browser.evaluateJavaScript(script, completion: completion)
    }

    /// Like evaluateJavaScript, awaiting a returned promise, and optionally as if the user
    /// had just clicked (APIs such as chrome.management.uninstall require that). Only for
    /// Kite's own pages: the result is the value, or nil with the protocol's error.
    func evaluate(_ expression: String, userGesture: Bool, completion: @escaping (Any?, String?) -> Void) {
        let params: [String: Any] = ["expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": userGesture]
        browser.callDevToolsMethod("Runtime.evaluate", params: params) { result, error in
            if let error { return completion(nil, error) }
            if let exception = result?["exceptionDetails"] as? [String: Any] {
                return completion(nil, (exception["exception"] as? [String: Any])?["description"] as? String ?? "exception")
            }
            completion((result?["result"] as? [String: Any])?["value"], nil)
        }
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

    // MARK: Add to Kite on Google results

    private var googleWorldRegistered = false
    /// Kite's isolated-world execution contexts, by id, with their frame ids.
    private var kiteContexts: [Int: String] = [:]

    /// Registers the isolated world and its binding the first time this tab shows
    /// Google results; other tabs never get them. Runtime is (re-)enabled on each
    /// results page, in case automation turned it off.
    private func prepareGoogleResults() {
        browser.executeDevToolsMethod("Runtime.enable", params: nil, completion: nil)
        guard !googleWorldRegistered else { return }
        googleWorldRegistered = true
        browser.pageFeatureEventHandler = { [weak self] method, params in self?.handlePageFeatureEvent(method, params) }
        browser.executeDevToolsMethod(
            "Runtime.addBinding",
            params: ["name": GoogleResultsScript.bindingName, "executionContextName": GoogleResultsScript.worldName],
            completion: nil
        )
        browser.executeDevToolsMethod(
            "Page.addScriptToEvaluateOnNewDocument",
            params: ["source": GoogleResultsScript.source, "worldName": GoogleResultsScript.worldName, "runImmediately": true],
            completion: nil
        )
    }

    private func handlePageFeatureEvent(_ method: String, _ params: [AnyHashable: Any]) {
        switch method {
        case "Runtime.executionContextCreated":
            guard let context = params["context"] as? [String: Any],
                  context["name"] as? String == GoogleResultsScript.worldName, let id = context["id"] as? Int,
                  let frame = (context["auxData"] as? [String: Any])?["frameId"] as? String else { return }
            kiteContexts[id] = frame
        case "Runtime.executionContextDestroyed":
            if let id = params["executionContextId"] as? Int { kiteContexts[id] = nil }
        case "Runtime.executionContextsCleared":
            kiteContexts.removeAll()
        case "Runtime.bindingCalled" where params["name"] as? String == MediaStateScript.bindingName:
            guard let context = params["executionContextId"] as? Int,
                  let report = MediaState.parse(params["payload"] as? String ?? "") else { return }
            mediaContext = context
            onEvent?(.media(report))
        case "Runtime.bindingCalled" where params["name"] as? String == VerificationCodeScript.bindingName:
            guard let context = params["executionContextId"] as? Int,
                  let payload = (params["payload"] as? String)?.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let host = request["host"] as? String, host == address?.host else { return }
            if request["done"] as? Bool == true {
                VerificationCodeService.shared.codeUsed(by: self)
            } else {
                VerificationCodeService.shared.codeWanted(by: self, context: context, host: host)
            }
        case "Runtime.bindingCalled":
            // Only from Kite's world, in the main frame of a Google results page.
            guard params["name"] as? String == GoogleResultsScript.bindingName,
                  let context = params["executionContextId"] as? Int, let frame = kiteContexts[context],
                  GoogleSearch.isResultsPage(address),
                  let id = GoogleResultsScript.extensionID(fromPayload: params["payload"] as? String ?? "") else { return }
            browser.executeDevToolsMethod("Page.getFrameTree", params: nil) { [weak self] result in
                guard let self else { return }
                let main = ((result?["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
                guard main == frame, GoogleSearch.isResultsPage(self.address) else { return }
                self.onEvent?(.addExtension(id: id))
            }
        default:
            break
        }
    }

    /// The extension whose origin this page's requests carry (ExtensionOrigin), if any.
    private var extensionOrigin: String?

    private func setExtensionOrigin(for url: URL) {
        let origin = ExtensionOrigin.origin(of: url)
        guard origin != extensionOrigin else { return }
        extensionOrigin = origin
        if origin != nil { browser.executeDevToolsMethod("Network.enable", params: nil, completion: nil) }
        browser.executeDevToolsMethod("Network.setExtraHTTPHeaders", params: ["headers": origin.map { ["Origin": $0] } ?? [:]], completion: nil)
    }

    // MARK: KCBrowserDelegate

    func browser(_ browser: KCBrowser, titleDidChange title: String) { onEvent?(.title(title)) }
    func browser(_ browser: KCBrowser, addressDidChange url: URL) {
        address = url
        if GoogleSearch.isResultsPage(url) { prepareGoogleResults() }
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

    @objc(browser:opensLinkInPeek:shift:)
    func browser(_ browser: KCBrowser, opensLinkInPeek url: URL, shift: Bool) -> Bool {
        guard linkPeekPolicy?(url, shift) == true else { return false }
        onEvent?(.openInLinkPeek(url))
        return true
    }

    @objc(browser:renderProcessDidTerminateWithCode:)
    func browser(_ browser: KCBrowser, renderProcessDidTerminateWithCode code: Int32) { onEvent?(.crashed(code: Int(code))) }

    @objc(browser:isExtensionPackageWithMIMEType:suggestedName:url:)
    func browser(_ browser: KCBrowser, isExtensionPackageWithMIMEType mimeType: String, suggestedName: String, url: URL?) -> Bool {
        ExtensionPackage.isDownload(mimeType: mimeType, suggestedName: suggestedName, url: url)
    }

    @objc(browser:statusMessageDidChange:)
    func browser(_ browser: KCBrowser, statusMessageDidChange message: String?) {
        onEvent?(.linkHover(LinkPreview.link(fromStatus: message).map { LinkHover(url: $0) }))
    }

    @objc(browser:blockedCountDidChange:)
    func browser(_ browser: KCBrowser, blockedCountDidChange count: Int) { onEvent?(.blockedCount(count)) }

    @objc(browser:documentStartScriptForURL:)
    func browser(_ browser: KCBrowser, documentStartScriptFor url: URL) -> String? {
        setExtensionOrigin(for: url)
        let scripts = [adblocker?.documentStartScript(for: url), WebStoreScript.script(for: url), ExtensionTabsScript.script(for: url)]
            .compactMap { $0 }
        return scripts.isEmpty ? nil : scripts.joined(separator: "\n")
    }

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
