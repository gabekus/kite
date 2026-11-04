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
    /// Incognito pages don't run Boosts.
    private var appliesBoosts = true
    let profileDirectory: String?
    var downloadContextKey: String { context?.downloadContextKey ?? "" }
    /// The default profile's engine keeps the others, so every window gets the same one.
    private var profileEngines: [String: ChromiumEngine] = [:]
    private weak var defaultEngine: ChromiumEngine?

    init(context: KCRequestContext? = nil, profileDirectory: String? = Profile.defaultDirectory) {
        self.context = context
        self.profileDirectory = profileDirectory
    }

    func forProfile(_ profile: Profile) -> WebEngine {
        let root = defaultEngine ?? self
        if profile.isDefault || root.profileDirectory == nil { return root }
        if let engine = root.profileEngines[profile.directory] { return engine }
        let engine = ChromiumEngine(context: KCRequestContext(profileDirectory: profile.directory), profileDirectory: profile.directory)
        engine.adblocker = root.adblocker
        engine.defaultEngine = root
        root.profileEngines[profile.directory] = engine
        return engine
    }

    func makePage(url: URL?, restoring state: Any?) -> WebPage {
        // CEF has no equivalent of WebKit's interactionState, so a revived tab reloads its URL.
        ChromiumPage(
            browser: KCBrowser(url: url, delegate: ChromiumDelegateProxy.placeholder, context: context),
            adblocker: adblocker,
            appliesBoosts: appliesBoosts
        )
    }

    /// Shares the ad blocker, whose engine and policy are already wired up process-wide.
    func makeEphemeral() -> WebEngine {
        let engine = ChromiumEngine(context: .incognito(), profileDirectory: nil)
        engine.adblocker = adblocker
        engine.appliesBoosts = false
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

    var deletableBrowsingData: [BrowsingDataType] { BrowsingDataType.allCases }

    /// Chromium's own remover, through Kite's helper extension (chrome.browsingData). Kite's
    /// history and downloads list are Kite's, deleted by the caller; this clears Chromium's too.
    func deleteBrowsingData(_ types: Set<BrowsingDataType>, since: Date?, completion: @escaping () -> Void) {
        let engineTypes = types.subtracting([.siteSettings])
        guard !engineTypes.isEmpty, profileDirectory != nil else { return completion() }
        ExtensionsModel.shared(engine: self).deleteBrowsingData(engineTypes, since: since, completion: completion)
    }
}

@MainActor
final class ChromiumPage: NSObject, WebPage, KCBrowserDelegate {
    let browser: KCBrowser
    /// The page's alert, confirm or prompt on screen (`PageDialogs`).
    private var pageDialog: ArcDialog?
    /// A close the person asked for, as the page's beforeunload decides it (`requestClose`).
    private var closeFlow = PageClose()
    /// Each pending request's answer, by generation.
    private var closeAnswers: [Int: (PageClose.Outcome) -> Void] = [:]
    private var closeTimer: DispatchWorkItem?
    var onEvent: ((PageEvent) -> Void)?
    var linkPeekPolicy: ((URL, Bool) -> Bool)?
    var contextMenuHost: (() -> PageContextMenu.Host)?
    private var mediaInUse = false
    private let adblocker: Adblocker?
    private var frameAdblock: FrameAdblock?
    private let appliesBoosts: Bool
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

    init(browser: KCBrowser, adblocker: Adblocker?, appliesBoosts: Bool = true) {
        self.browser = browser
        self.adblocker = adblocker
        self.appliesBoosts = appliesBoosts
        super.init()
        browser.delegate = self
        prepareDocumentScripts()
        if let adblocker, KCRuntime.supportsAdblock {
            frameAdblock = FrameAdblock(browser: browser, adblocker: adblocker, pageURL: { [weak self] in self?.address })
        }
        if appliesBoosts { LiveBoosts.attach(to: self, owner: self) }
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

    /// A script Kite runs in every document's main frame: in the page's world, or in an isolated
    /// `world`; `binding` is how it reports.
    private struct DocumentScript {
        let source: String
        var world: String?
        var binding: String?
    }

    private static let mailBindingName = "kiteMailHandler"

    private static let documentScripts = [
        // Kite's code-field script (VerificationCodeScript); the binding exists only in its world,
        // so pages can't ask for codes themselves.
        DocumentScript(source: VerificationCodeScript.source, world: VerificationCodeScript.worldName,
                       binding: VerificationCodeScript.bindingName),
        // What the page plays (MediaStateScript); the page hook runs in the page's world to reach its
        // Media Session handlers.
        DocumentScript(source: MediaStateScript.source, world: MediaStateScript.worldName, binding: MediaStateScript.bindingName),
        DocumentScript(source: MediaStateScript.pageHook),
        // The page's registerProtocolHandler reports to a main-world binding (MailHandlers.script),
        // which the script takes off the page's global object.
        DocumentScript(
            source: MailHandlers.script(
                send: "(() => { const b = globalThis.\(mailBindingName); try { delete globalThis.\(mailBindingName); } catch (e) {} "
                    + "return typeof b === 'function' ? (s) => b(s) : null; })()"
            ),
            binding: mailBindingName
        ),
    ]

    private func prepareDocumentScripts() {
        browser.pageFeatureEventHandler = { [weak self] method, params in self?.handlePageFeatureEvent(method, params) }
        browser.executeDevToolsMethod("Page.enable", params: nil, completion: nil)
        for script in Self.documentScripts {
            addBinding(for: script)
            var params: [String: Any] = ["source": script.source]
            if let world = script.world { params["worldName"] = world }
            browser.executeDevToolsMethod("Page.addScriptToEvaluateOnNewDocument", params: params, completion: nil)
        }
    }

    private func addBinding(for script: DocumentScript) {
        guard let binding = script.binding else { return }
        var params: [String: Any] = ["name": binding]
        if let world = script.world { params["executionContextName"] = world }
        browser.executeDevToolsMethod("Runtime.addBinding", params: params, completion: nil)
    }

    // MARK: The first document

    private var firstDocumentChecked = false
    /// Whether the media script has reported in this page: it reports as each document starts.
    private var mediaReported = false

    /// Chromium handles a new tab's DevTools calls only once its first document has a renderer, so
    /// that document starts without the document scripts: no media reports, codes or mail handler
    /// until the tab navigates. Checked as that document starts loading: if the scripts ran, the media
    /// script has reported, and the renderer answers the evaluate only after that report. Without
    /// one, they run now; what the page did before then (a handler it set while parsing) they miss.
    private func checkFirstDocument() {
        guard !firstDocumentChecked else { return }
        firstDocumentChecked = true
        browser.callDevToolsMethod("Runtime.evaluate", params: ["expression": "0"]) { [weak self] _, error in
            // An error (the document already gone) says nothing about the scripts.
            guard let self, error == nil, !mediaReported else { return }
            browser.callDevToolsMethod("Page.getFrameTree", params: nil) { [weak self] result, _ in
                guard let self, let frame = (result?["frameTree"] as? [String: Any])?["frame"] as? [String: Any],
                      let frameID = frame["id"] as? String else { return }
                for script in Self.documentScripts { runLate(script, frame: frameID) }
            }
        }
    }

    private func runLate(_ script: DocumentScript, frame: String) {
        guard let world = script.world else {
            // Added again: one added before the renderer existed may not reach this document.
            addBinding(for: script)
            return browser.executeDevToolsMethod("Runtime.evaluate", params: ["expression": script.source], completion: nil)
        }
        browser.callDevToolsMethod("Page.createIsolatedWorld", params: ["frameId": frame, "worldName": world]) { [weak self] result, _ in
            guard let self, let context = result?["executionContextId"] as? Int else { return }
            // A world made here doesn't get bindings added by world name.
            if let binding = script.binding {
                browser.executeDevToolsMethod("Runtime.addBinding", params: ["name": binding, "executionContextId": context], completion: nil)
            }
            browser.executeDevToolsMethod("Runtime.evaluate", params: ["expression": script.source, "contextId": context], completion: nil)
        }
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

    /// Counted in the bridge as each request finishes (KCBrowser's NetworkCountingHandler).
    var networkBytes: UInt64? { browser.networkBytes }

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

    /// Read again for each new document (document-start script) and applied live when it changes.
    var themeCSS: String? {
        didSet {
            guard themeCSS != oldValue else { return }
            browser.evaluateJavaScript(ThemeCSS.script(css: themeCSS)) { _ in }
        }
    }

    func sitePermission(_ permission: SitePermission, for url: URL) -> SitePermissionValue? {
        switch browser.sitePermission(Self.bridged(permission), for: Self.site(url)) {
        case .allow: .allow
        case .block: .block
        default: .ask
        }
    }

    func defaultSitePermission(_ permission: SitePermission) -> SitePermissionValue? {
        switch browser.defaultSitePermission(Self.bridged(permission)) {
        case .allow: .allow
        case .block: .block
        default: .ask
        }
    }

    func setDefaultSitePermission(_ permission: SitePermission, _ value: SitePermissionValue) {
        let bridged: KCSitePermissionValue = switch value {
        case .allow: .allow
        case .block: .block
        case .ask: .ask
        }
        browser.setDefaultSitePermission(Self.bridged(permission), value: bridged)
    }

    func preference(_ name: String) -> Any? { browser.preferenceNamed(name) }

    func setPreference(_ name: String, _ value: Any?) -> Bool { browser.setPreferenceNamed(name, value: value) }

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

    private static func unbridged(_ permission: KCSitePermission) -> SitePermission {
        switch permission {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .notifications: .notifications
        @unknown default: .notifications
        }
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

    func requestClose(_ completion: @escaping (PageClose.Outcome) -> Void) {
        let (generation, effects) = closeFlow.request()
        closeAnswers[generation] = completion
        perform(effects)
    }

    /// Whether the page registered beforeunload: the main frame's listeners (DOMDebugger lists `onbeforeunload`
    /// too). A page with iframes counts as having one, since a frame can ask as well; so does a page that
    /// doesn't answer within the close deadline. Those get asked (and timed out).
    func hasBeforeUnloadHandler(_ completion: @escaping (Bool) -> Void) {
        var answered = false
        let answer = { (has: Bool) in
            guard !answered else { return }
            answered = true
            completion(has)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PageClose.unresponsiveTimeout) { answer(true) }
        let group = "kite-close-check"
        browser.callDevToolsMethod("Runtime.evaluate", params: ["expression": "window.frames.length", "returnByValue": true]) {
            [weak self] result, _ in
            guard let self else { return answer(false) }
            if let frames = (result?["result"] as? [String: Any])?["value"] as? Int, frames > 0 { return answer(true) }
            browser.callDevToolsMethod("Runtime.evaluate", params: ["expression": "window", "objectGroup": group]) {
                [weak self] result, _ in
                guard let self, let objectID = (result?["result"] as? [String: Any])?["objectId"] as? String else {
                    return answer(false)
                }
                browser.callDevToolsMethod("DOMDebugger.getEventListeners", params: ["objectId": objectID]) { [weak self] result, _ in
                    self?.browser.executeDevToolsMethod("Runtime.releaseObjectGroup", params: ["objectGroup": group], completion: nil)
                    let listeners = result?["listeners"] as? [[String: Any]] ?? []
                    answer(listeners.contains { $0["type"] as? String == "beforeunload" })
                }
            }
        }
    }

    private func perform(_ effects: [PageClose.Effect]) {
        for effect in effects {
            switch effect {
            case .startUnload:
                // A page that doesn't exist yet (or is closing) has nothing to ask.
                if !browser.beginUnloadClose() { perform(closeFlow.pageLetGo()) }
            case .armTimer(let generation):
                closeTimer?.cancel()
                let timer = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    perform(closeFlow.timerFired(generation: generation))
                }
                closeTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + PageClose.unresponsiveTimeout, execute: timer)
            case .cancelTimer:
                closeTimer?.cancel()
                closeTimer = nil
            case .forceClose:
                // The page didn't answer in time: close it without asking, as Chrome does a hung tab. A slow
                // background renderer that only now gets to its beforeunload loses its "Leave site?" (the
                // forced close answers it Leave): deliberate, so a busy page can't hold a close up.
                pageDialog?.dismiss()
                pageDialog = nil
                browser.close()
                // Its script is stopped only if it's still running well after that (a page truly stuck in
                // beforeunload or unload), so a slow page's save gets its chance.
                let closing = browser
                DispatchQueue.main.asyncAfter(deadline: .now() + PageClose.stuckScriptTimeout) {
                    closing.stopScriptOfClosingPage()
                }
            case let .finish(outcome, generation):
                if outcome != .close, closeFlow.pending == nil { browser.cancelUnloadClose() }
                guard let answer = closeAnswers.removeValue(forKey: generation) else { continue }
                // Never inside the engine's callback. Not while quitting: closing the tab would change the
                // saved session and show another tab, making a page the quit then waits for.
                DispatchQueue.main.async {
                    if (NSApp.delegate as? AppDelegate)?.isTerminating == true { return }
                    answer(outcome)
                }
            }
        }
    }

    func close() {
        // The request goes first, so dismissing its dialog can't answer it as Cancel.
        perform(closeFlow.forced())
        pageDialog?.dismiss()
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
        frameAdblock?.handle(method, params)
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
            mediaReported = true
            if let call = CallControls.parse(params["payload"] as? String ?? "") {
                if let context = params["executionContextId"] as? Int { mediaContext = context }
                return onEvent?(.callControls(call)) ?? ()
            }
            guard let context = params["executionContextId"] as? Int,
                  let report = MediaState.parse(params["payload"] as? String ?? "") else { return }
            mediaContext = context
            onEvent?(.media(report))
        case "Runtime.bindingCalled" where params["name"] as? String == Self.mailBindingName:
            // MailHandlers checks the handler is on the main frame's origin.
            guard let call = MailHandlers.parse(params["payload"] as? String ?? "") else { return }
            MailHandlers.shared.request(scheme: call.scheme, url: call.url, pageURL: address, from: browser.view)
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

    @objc(browserMainFrameDidStartLoading:)
    func browserMainFrameDidStartLoading(_ browser: KCBrowser) {
        checkFirstDocument()
    }

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
                self.browser.evaluateJavaScript(adblocker.drainScript(last: delay == Self.cosmeticPolls.last)) { [weak self] result in
                    guard let self, self.cosmeticGeneration == generation, let payload = result as? String,
                          let script = adblocker.genericHidingScript(payload: payload, pageURL: self.address) else { return }
                    self.browser.evaluateJavaScript(script) { _ in }
                }
            }
        }
    }

    func browser(_ browser: KCBrowser, mediaAccessDidChange inUse: Bool) {
        guard inUse != mediaInUse else { return }
        mediaInUse = inUse
        onEvent?(.capturing(inUse))
    }

    func browser(_ browser: KCBrowser, requestsPermissions permissions: [NSNumber], origin: URL, promptID: Int,
                 decisionHandler: @escaping (KCPermissionDecision) -> Void) {
        let requested = permissions.compactMap { KCSitePermission(rawValue: $0.intValue).map(Self.unbridged) }
        guard let onEvent, !requested.isEmpty else { return decisionHandler(.dismiss) }
        onEvent(.permissionRequest(PermissionRequest(id: promptID, origin: origin, permissions: requested) { allow in
            decisionHandler(allow.map { $0 ? .allow : .block } ?? .dismiss)
        }))
    }

    func browser(_ browser: KCBrowser, runJavaScriptDialog kind: JavaScriptDialogKind, message: String,
                 defaultText: String, origin: URL?, completion: @escaping (Bool, String?) -> Void) {
        pageDialog?.dismiss()
        let kinds: [JavaScriptDialogKind: PageDialogs.Kind] = [
            .alert: .alert, .confirm: .confirm, .prompt: .prompt, .leave: .leave, .reload: .reload,
        ]
        let request = kind == .leave ? closeFlow.pending : nil
        if request != nil { perform(closeFlow.dialogShown()) }
        let present = { [weak self] in
            guard let self else { return completion(false, nil) }
            pageDialog = PageDialogs.present(kinds[kind] ?? .alert, message: message, defaultText: defaultText,
                                             origin: origin, in: browser.view) { [weak self] ok, text in
                guard let self else { return completion(ok, text) }
                pageDialog = nil
                // Before the engine hears it: answering resets the page's dialog state on the way.
                if request != nil { perform(closeFlow.answered(leave: ok)) }
                completion(ok, text)
            }
        }
        guard request != nil, !isOnScreen else { return present() }
        // Closing a background tab: its tab comes forward first, then the dialog shows on it.
        onEvent?(.showForLeaveDialog)
        presentWhenOnScreen(attempts: 20, present: present, cancel: { completion(false, nil) })
    }

    /// A background tab's page can sit in the window as a hidden view.
    private var isOnScreen: Bool { browser.view.window != nil && !browser.view.isHiddenOrHasHiddenAncestor }

    /// Runs `present` once the page's view is on screen, checking every 50 ms, while a close is still waiting
    /// for it (a newer request, a second click on the close button, takes the same dialog's answer); it gets
    /// Cancel (PageDialogs, without a window) when the view never arrives.
    private func presentWhenOnScreen(attempts: Int, present: @escaping () -> Void, cancel: @escaping () -> Void) {
        guard closeFlow.pending != nil else { return cancel() }
        guard !isOnScreen, attempts > 0 else { return present() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return cancel() }
            presentWhenOnScreen(attempts: attempts - 1, present: present, cancel: cancel)
        }
    }

    func browserDidLetGo(_ browser: KCBrowser) {
        perform(closeFlow.pageLetGo())
    }

    func browserWillCloseWithoutAsking(_ browser: KCBrowser) {
        perform(closeFlow.forced())
    }

    func browserDismissJavaScriptDialogs(_ browser: KCBrowser) {
        perform(closeFlow.dialogReset())
        pageDialog?.dismiss()
        pageDialog = nil
    }

    func browser(_ browser: KCBrowser, permissionPromptDidCancel promptID: Int) {
        onEvent?(.permissionRequestCancelled(id: promptID))
    }

    func browser(_ browser: KCBrowser, openURLInNewTab url: URL, foreground: Bool) {
        // CEF reports only the disposition (⌘-click: background, ⇧⌘: foreground); ⌥ is read from the
        // keyboard, as Arc reads NSEvent.modifierFlags. ⌥⌘-click opens in Little Kite or Split View.
        if !foreground {
            let flags = NSEvent.modifierFlags
            switch LinkClick.commandClickDestination(shift: false, option: flags.contains(.option), command: flags.contains(.command),
                                                     opensLittleKite: LittleKite.opensOnOptionCommandClick(in: .standard)) {
            case .littleKite: return onEvent?(.openInLittleKite(url)) ?? ()
            case .splitView: return onEvent?(.openInSplit(url)) ?? ()
            case .backgroundTab, .foregroundTab: break
            }
        }
        onEvent?(.openInNewTab(url, foreground: foreground))
    }

    func browser(_ browser: KCBrowser, didCreatePopup popup: KCBrowser, url: URL?) -> Bool {
        guard let onEvent else { return false }
        let page = ChromiumPage(browser: popup, adblocker: adblocker, appliesBoosts: appliesBoosts)
        onEvent(.popup(page))
        // Whatever keeps a popup gives it a handler (`PagePool.register`); a background page's handler
        // (a reader, an install, a verification page) lets it go.
        return page.onEvent != nil
    }

    func browserDidRequestClose(_ browser: KCBrowser) { onEvent?(.closeRequested) }

    @objc(browser:opensLinkInPeek:shift:)
    func browser(_ browser: KCBrowser, opensLinkInPeek url: URL, shift: Bool) -> Bool {
        guard linkPeekPolicy?(url, shift) == true else { return false }
        onEvent?(.openInLinkPeek(url))
        return true
    }

    @objc(browser:mailtoDestinationForURL:)
    func browser(_ browser: KCBrowser, mailtoDestinationFor url: URL) -> URL? {
        MailHandlers.shared.destination(for: url)
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
        let scripts = [
            adblocker?.documentStartScript(for: url), WebStoreScript.script(for: url), ExtensionTabsScript.script(for: url),
            appliesBoosts ? BoostsModel.shared.script(for: url) : nil,
            themeCSS.map { ThemeCSS.script(css: $0) },
        ].compactMap { $0 }
        return scripts.isEmpty ? nil : scripts.joined(separator: "\n")
    }

    func browser(_ browser: KCBrowser, findResultCount count: Int32, activeMatch: Int32, final: Bool) {
        findCompletion?(FindResult(found: count > 0, matches: Int(count), activeMatch: Int(activeMatch)))
    }

    // MARK: Right-click menu (Arc's, PageContextMenu)

    private func menuContext(_ params: [String: Any]) -> PageContextMenu.Context {
        let host = contextMenuHost?() ?? PageContextMenu.Host()
        return PageContextMenu.Context(
            linkURL: params["linkURL"] as? URL, imageURL: params["imageURL"] as? URL,
            selectionText: params["selectionText"] as? String ?? "", isEditable: params["editable"] as? Bool ?? false,
            pageURL: params["pageURL"] as? URL, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward,
            searchEngine: host.searchEngine, isSpeaking: PageContextMenuItems.isSpeaking
        )
    }

    @objc(browser:contextMenuItemsForParams:)
    func browser(_ browser: KCBrowser, contextMenuItemsForParams params: [String: Any]) -> [[String: Any]]? {
        let host = contextMenuHost?() ?? PageContextMenu.Host()
        func encode(_ entry: PageContextMenu.Entry) -> [String: Any] {
            ["id": PageContextMenu.commandID(entry.item), "title": entry.title, "enabled": entry.isEnabled,
             "children": entry.children.map(encode)]
        }
        return PageContextMenu.menu(for: menuContext(params), host: host)?.map(encode)
    }

    @objc(browser:performContextMenuItem:params:)
    func browser(_ browser: KCBrowser, performContextMenuItem itemID: Int, params: [String: Any]) {
        guard let item = PageContextMenu.item(commandID: itemID) else { return }
        let context = menuContext(params)
        let point = NSPoint(x: params["x"] as? Double ?? 0, y: params["y"] as? Double ?? 0)
        let send: (PageEvent) -> Void = { [weak self] in self?.onEvent?($0) }
        switch item {
        case .open, .saveLinkAs, .copyLinkAddress, .copyEmailAddress:
            guard let link = context.linkURL else { return }
            PageContextMenuItems.perform(item, url: link, send: send, download: { browser.downloadURL($0) })
        case .back: browser.goBack()
        case .forward: browser.goForward()
        case .reload: browser.reload()
        case .savePageAs: send(.pageCommand(.savePageAs))
        case .print: send(.pageCommand(.print))
        case .viewPageSource: send(.pageCommand(.viewPageSource))
        case .inspect: browser.inspectElement(at: point)
        case .openImageInNewTab:
            // Chromium opens it in the background.
            if let image = context.imageURL { send(.openInNewTab(image, foreground: false)) }
        case .saveImageAs:
            if let image = context.imageURL { browser.downloadURL(image) }
        case .copyImage:
            if let image = context.imageURL { PageContextMenuItems.copyImage(at: image, referrer: context.pageURL) }
        case .copyImageAddress:
            if let image = context.imageURL { PageContextMenuItems.copy(image.absoluteString, asURL: true) }
        case .lookUp:
            PageContextMenuItems.lookUp(context.selectionText, in: browser.view, at: point)
        case .searchSelection:
            // Chromium opens the search (or the address) in a new foreground tab.
            if let url = PageContextMenu.searchURL(context: context) { send(.openInNewTab(url, foreground: true)) }
        case .copy:
            // A test profile's own pasteboard gets the plain text; Chromium's Copy writes the general one.
            if PageContextMenuItems.pasteboard != .general {
                PageContextMenuItems.copy(context.selectionText, asURL: false)
            } else {
                browser.copySelection()
            }
        case .copyLinkToHighlight:
            guard let page = context.pageURL,
                  let link = TextFragment.link(to: page, selection: context.selectionText) else { return NSSound.beep() }
            PageContextMenuItems.copy(link.absoluteString, asURL: true)
        case .startSpeaking: PageContextMenuItems.startSpeaking(context.selectionText)
        case .stopSpeaking: PageContextMenuItems.stopSpeaking()
        case .speech, .separator: break
        }
    }

    @objc(browser:answerContextMenuForTest:)
    func browser(_ browser: KCBrowser, answerContextMenuForTest entries: [[String: Any]]) -> NSNumber? {
        guard PageContextMenuItems.testMode != nil else { return nil }
        let pick = PageContextMenuItems.logForTest(entries.map { entry in
            (title: entry["title"] as? String, enabled: entry["enabled"] as? Bool ?? false)
        })
        guard let pick, let id = entries[pick]["id"] as? Int else { return -1 }
        return NSNumber(value: id)
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
    func browser(_ browser: KCBrowser, didCreatePopup popup: KCBrowser, url: URL?) -> Bool { false }
    func browserDidRequestClose(_ browser: KCBrowser) {}
}
#endif
