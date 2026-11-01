import AppKit
import KiteCore
import WebKit
import KiteCore

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
    /// Incognito pages don't run Boosts.
    private var appliesBoosts = true
    private(set) var profileDirectory: String? = Profile.defaultDirectory
    private var profileEngines: [String: WebKitEngine] = [:]
    private weak var defaultEngine: WebKitEngine?

    init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Without a Safari token some sites serve a degraded page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        Self.allowFullRefreshRate(configuration.preferences)
        self.configuration = configuration
    }

    /// Shares the ad blocker's compiled rules; only the website data is kept in memory.
    func makeEphemeral() -> WebEngine {
        let engine = WebKitEngine(dataStore: .nonPersistent())
        engine.contentRules = contentRules
        engine.appliesBoosts = false
        engine.profileDirectory = nil
        return engine
    }

    /// WebKit keeps each profile in a data store named by the profile's `dataStoreID`.
    func forProfile(_ profile: Profile) -> WebEngine {
        let root = defaultEngine ?? self
        if profile.isDefault || root.profileDirectory == nil { return root }
        if let engine = root.profileEngines[profile.directory] { return engine }
        let engine = WebKitEngine(dataStore: WKWebsiteDataStore(forIdentifier: profile.dataStoreID))
        engine.contentRules = root.contentRules
        engine.profileDirectory = profile.directory
        engine.defaultEngine = root
        root.profileEngines[profile.directory] = engine
        return engine
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
        let page = WebKitPage(
            configuration: configuration.copy() as! WKWebViewConfiguration, downloads: downloads,
            contentRules: contentRules, appliesBoosts: appliesBoosts
        )
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
    var linkPeekPolicy: ((URL, Bool) -> Bool)?
    var contextMenuHost: (() -> PageContextMenu.Host)?
    private let downloads: DownloadCoordinator
    private let contentRules: WebKitContentRules?
    private let appliesBoosts: Bool
    /// The Boost script registered for the current page, so an unchanged one isn't re-added,
    /// and the user script carrying it, so it alone is replaced.
    private var boostScript: String?
    private var boostUserScript: WKUserScript?
    private var observations: [NSKeyValueObservation] = []
    /// Ids for this page's permission prompts.
    private var permissionPromptCount = 0

    private static let inPageSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
    private static let faviconScript = """
        (() => {
          const link = document.querySelector('link[rel~="icon"][href], link[rel="apple-touch-icon"][href]');
          return link ? link.href : location.origin + '/favicon.ico';
        })()
        """

    init(configuration: WKWebViewConfiguration, downloads: DownloadCoordinator, contentRules: WebKitContentRules?, appliesBoosts: Bool = true) {
        // Each page gets its own content controller so ad-block rules and Boosts can differ per site.
        configuration.userContentController = contentRules?.makeController() ?? WKUserContentController()
        // Web Inspector in the window (View › Developer) needs WebKit's private developer
        // extras; isInspectable alone only allows Safari's remote inspector.
        if configuration.preferences.responds(to: NSSelectorFromString("_developerExtrasEnabled")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.downloads = downloads
        self.contentRules = contentRules
        self.appliesBoosts = appliesBoosts
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
        // The right-click test hook needs the page to answer while the test window is covered;
        // WebKit stops serving an occluded window's page (private WKWebView setting).
        let setOcclusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if PageContextMenuItems.testMode != nil, webView.responds(to: setOcclusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: setOcclusion), to: Setter.self)(webView, setOcclusion, false)
        }
        WebKitMediaBridge.shared.attach(self)
        WebKitMailBridge.shared.attach(self)
        if appliesBoosts { LiveZaps.attach(to: self, owner: self) }
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
    // WebKit takes the keyboard only through AppKit, which the command bar already guards.
    func blur() {}
    func allowFocus() {}
    // WebKit throttles views that aren't in a window on its own.
    func setVisible(_ visible: Bool) {}
    /// Web Inspector has no public API; WKWebView's private `_inspector` (`_WKInspector`)
    /// opens it. Each call is guarded, and without it Kite says to use the context menu.
    /// There's no call for the Network tab, so Network Inspector opens the inspector as is.
    func showDevTools(_ panel: DevToolsPanel) {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter), let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject else {
            let alert = NSAlert()
            alert.messageText = "Web Inspector"
            alert.informativeText = "On the WebKit engine, right-click the page and choose Inspect Element."
            alert.runModal()
            return
        }
        func call(_ name: String) {
            let selector = NSSelectorFromString(name)
            if inspector.responds(to: selector) { inspector.perform(selector) }
        }
        call("show")
        switch panel {
        case .last, .network: break
        case .console: call("showConsole")
        case .inspectElement: call("toggleElementSelection")
        }
    }
    // No public force-dark API in WebKit.
    func setForceDark(_ enabled: Bool) {}
    // WKWebView keeps no per-site permissions Kite can read or set.
    func sitePermission(_ permission: SitePermission, for url: URL) -> SitePermissionValue? { nil }
    func setSitePermission(_ permission: SitePermission, _ value: SitePermissionValue, for url: URL) {}

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

    func captureImage(area: CGRect?, completion: @escaping (Data?) -> Void) {
        let deviceScale = webView.window?.backingScaleFactor ?? 2
        guard let area else {
            // takeSnapshot stops at the viewport; a PDF of the page (no rect) holds all of it as one page.
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                guard let pdf = try? result.get(), let rep = NSPDFImageRep(data: pdf) else { return completion(nil) }
                let size = rep.bounds.size
                let scale = deviceScale * Capture.fullPageScale(contentHeight: size.height, deviceScale: deviceScale)
                completion(Self.png(size: size, scale: scale) { rep.draw(in: NSRect(origin: .zero, size: size)) })
            }
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.isFlipped ? area
            : CGRect(x: area.minX, y: webView.bounds.height - area.maxY, width: area.width, height: area.height)
        configuration.snapshotWidth = NSNumber(value: Double(area.width))
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image else { return completion(nil) }
            completion(Self.png(size: area.size, scale: deviceScale) { image.draw(in: NSRect(origin: .zero, size: area.size)) })
        }
    }

    /// Draws into a bitmap of `size` points at `scale` pixels per point and encodes it.
    private static func png(size: CGSize, scale: CGFloat, draw: () -> Void) -> Data? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
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

    func makePrintOperation(_ completion: @escaping (NSPrintOperation?) -> Void) {
        let info = NSPrintInfo.printInfoForPage()
        // Fit the page's width to the paper and run it down the pages, like Safari.
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        // Without a frame WebKit lays the page out at zero size and prints blank pages.
        operation.view?.frame = webView.bounds
        completion(operation)
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

    func runMediaCommand(_ command: MediaCommand) {
        // evaluateJavaScript counts as a user gesture, which play() and picture in picture need.
        webView.evaluateJavaScript(command.script, in: nil, in: WebKitMediaBridge.world) { _ in }
    }

    /// WebKit's page mute (`_setPageMuted:`, private: there's no public API). Without it, does nothing.
    /// WKWebView's private `_webProcessIdentifier` (WebKit has no public API for it); nil if a
    /// macOS release drops it, or before the web process starts.
    var processIdentifier: pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    var isAudioMuted = false {
        didSet {
            let selector = NSSelectorFromString("_setPageMuted:")
            guard isAudioMuted != oldValue, webView.responds(to: selector) else { return }
            typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
            let set = unsafeBitCast(webView.method(for: selector), to: SetMuted.self)
            // _WKMediaAudioMuted = 1 << 0.
            set(webView, selector, isAudioMuted ? 1 : 0)
        }
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

        if MailHandler.isMailto(url) {
            decisionHandler(.cancel)
            // The default mail app's compose page (MailHandlers), in this page, else the system's mail app.
            guard let compose = MailHandlers.shared.destination(for: url) else {
                return MailHandlers.shared.openInSystemMailApp(url)
            }
            if navigationAction.targetFrame?.isMainFrame == true {
                webView.load(URLRequest(url: compose))
            } else {
                onEvent?(.openInNewTab(compose, foreground: true))
            }
            return
        }
        if let scheme = url.scheme?.lowercased(), !Self.inPageSchemes.contains(scheme) {
            // zoommtg:, etc. belong to other apps.
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }

        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated && flags.contains(.command) {
            // ⌘-click opens in the background, ⇧⌘-click opens and switches, ⌥⌘-click opens in Split View.
            switch LinkClick.commandClickDestination(shift: flags.contains(.shift), option: flags.contains(.option)) {
            case .splitView: onEvent?(.openInSplit(url))
            case .foregroundTab: onEvent?(.openInNewTab(url, foreground: true))
            case .backgroundTab: onEvent?(.openInNewTab(url, foreground: false))
            }
            return decisionHandler(.cancel)
        }
        // Arc's Peek: a click in this page or to a new one (target=_blank), not a subframe's own navigation.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           linkPeekPolicy?(url, flags.contains(.shift)) == true {
            onEvent?(.openInLinkPeek(url))
            return decisionHandler(.cancel)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            contentRules?.apply(to: webView.configuration.userContentController, url: url)
            applyBoosts(for: url)
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

extension WebKitPage {
    /// Boosts (code and zaps) for the page about to load, as a document-start user script (top
    /// frame only). WebKit can only remove every user script at once, so the others (the media
    /// bridge's) are added back and only the old Boost script is dropped.
    fileprivate func applyBoosts(for url: URL) {
        let script = appliesBoosts ? BoostsModel.shared.script(for: url) : nil
        guard script != boostScript else { return }
        boostScript = script
        let controller = webView.configuration.userContentController
        if let old = boostUserScript {
            let others = controller.userScripts.filter { $0 !== old && $0.source != old.source }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            boostUserScript = nil
        }
        guard let script else { return }
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(userScript)
        boostUserScript = userScript
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
        let popup = WebKitPage(configuration: configuration, downloads: downloads, contentRules: contentRules, appliesBoosts: appliesBoosts)
        onEvent?(.popup(popup))
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onEvent?(.closeRequested)
    }

    /// getUserMedia: Arc's prompt. WebKit keeps no per-site store Kite can read, so it asks
    /// each time the page does; "Not Now" and closing both deny.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let permissions: [SitePermission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: []
        }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        guard let onEvent, !permissions.isEmpty, let url = components.url else { return decisionHandler(.deny) }
        permissionPromptCount += 1
        onEvent(.permissionRequest(PermissionRequest(id: permissionPromptCount, origin: url, permissions: permissions) { allow in
            decisionHandler(allow == true ? .grant : .deny)
        }))
    }

    /// WebKit's private hover callback (WKUIDelegatePrivate): the element under the pointer after each
    /// move, with the move's modifier keys. Safari's status bar uses it. `hitTestResult` is a
    /// `_WKHitTestResult`, read by key so a missing property gives nil instead of a crash.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(_ webView: WKWebView, mouseDidMoveOverElement hitTestResult: NSObject?, withFlags flags: UInt,
                 userInfo: AnyObject?) {
        func value(_ key: String) -> Any? {
            guard let hitTestResult, hitTestResult.responds(to: NSSelectorFromString(key)) else { return nil }
            return hitTestResult.value(forKey: key)
        }
        guard let url = value("absoluteLinkURL") as? URL, LinkPreview.canPreview(url) else {
            return onEvent?(.linkHover(nil)) ?? ()
        }
        var screenRect: NSRect?
        if let box = (value("elementBoundingBox") as? NSValue)?.rectValue, !box.isEmpty, let window = webView.window {
            screenRect = window.convertToScreen(webView.convert(box, to: nil))
        }
        let modifiers = NSEvent.ModifierFlags(rawValue: flags).intersection(.deviceIndependentFlagsMask)
        onEvent?(.linkHover(LinkHover(url: url, screenRect: screenRect, modifiers: modifiers)))
    }

    /// WebKit's private right-click hook (WKUIDelegatePrivate): the menu WebKit built for the
    /// element under the pointer, returned with Arc's link and image items in place of WebKit's.
    /// `element` is a `_WKContextMenuElementInfo`, read by key like the hover callback above.
    @objc(_webView:contextMenu:forElement:)
    func webView(_ webView: WKWebView, contextMenu menu: NSMenu, forElement element: NSObject?) -> NSMenu {
        func value(_ object: NSObject?, _ key: String) -> Any? {
            guard let object, object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }
        let hit = value(element, "hitTestResult") as? NSObject
        let link = value(hit, "absoluteLinkURL") as? URL
        let image = value(hit, "absoluteImageURL") as? URL
        guard link != nil || image != nil else { return Self.menuForTest(menu) ?? menu }
        let host = contextMenuHost?() ?? PageContextMenu.Host()

        // WebKit's own identifiers (_WKMenuItemIdentifiers, private), so its items can be found.
        let linkIDs: Set<NSUserInterfaceItemIdentifier> = [
            .init("WKMenuItemIdentifierOpenLink"), .init("WKMenuItemIdentifierOpenLinkInNewWindow"),
            .init("WKMenuItemIdentifierDownloadLinkedFile"), .init("WKMenuItemIdentifierCopyLink"),
        ]
        let imageIDs: Set<NSUserInterfaceItemIdentifier> = [
            .init("WKMenuItemIdentifierOpenImageInNewWindow"), .init("WKMenuItemIdentifierDownloadImage"),
            .init("WKMenuItemIdentifierCopyImage"),
        ]
        func webKitItem(_ id: String) -> NSMenuItem? {
            menu.items.first { $0.identifier?.rawValue == id }
        }

        var items: [NSMenuItem] = []
        if let link {
            items += PageContextMenuItems.menuItems(for: link, host: host) { [weak self] item in
                guard let self else { return }
                PageContextMenuItems.perform(item, url: link, send: { self.onEvent?($0) }, download: self.download)
            }
        }
        if let image {
            // Chromium's order. WebKit's own Copy Image item copies the image itself.
            items.append(PageContextMenuItems.action(PageContextMenu.imageTitles[0]) { [weak self] in
                self?.onEvent?(.openInNewTab(image, foreground: false))
            })
            items.append(PageContextMenuItems.action(PageContextMenu.imageTitles[1]) { [weak self] in
                self?.download(image)
            })
            if let copy = webKitItem("WKMenuItemIdentifierCopyImage") {
                copy.title = PageContextMenu.imageTitles[2]
                items.append(copy)
            }
            items.append(PageContextMenuItems.action(PageContextMenu.imageTitles[3]) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(image.absoluteString, forType: .string)
                pasteboard.setString(image.absoluteString, forType: .URL)
            })
            items.append(.separator())
        }
        let replaced = linkIDs.union(imageIDs)
        let rest = menu.items.filter { item in
            guard let id = item.identifier else { return true }
            return !replaced.contains(id)
        }
        let result = NSMenu(title: menu.title)
        for item in PageContextMenuItems.tidySeparators(items + rest) {
            item.menu?.removeItem(item)
            result.addItem(item)
        }
        return Self.menuForTest(result) ?? result
    }

    /// Under KITE_TEST_CONTEXT_MENU: logs `menu` (and runs the item asked for) and returns an empty
    /// menu, which WebKit doesn't show. Nil otherwise.
    private static func menuForTest(_ menu: NSMenu) -> NSMenu? {
        guard PageContextMenuItems.testMode != nil else { return nil }
        menu.update()  // runs menu validation, as showing it would
        let pick = PageContextMenuItems.logForTest(menu.items.map {
            (title: $0.isSeparatorItem ? nil : $0.title, enabled: $0.isEnabled)
        })
        if let pick { menu.performActionForItem(at: pick) }
        return NSMenu()
    }

    private func download(_ url: URL) {
        webView.startDownload(using: URLRequest(url: url)) { [downloads] download in
            download.delegate = downloads
        }
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

/// Delivers MediaStateScript's reports to the page they came from. Installed once per content
/// controller: popups share their opener's, and a controller takes only one handler per name.
@MainActor
final class WebKitMediaBridge: NSObject, WKScriptMessageHandler {
    static let shared = WebKitMediaBridge()
    static let world = WKContentWorld.world(name: MediaStateScript.worldName)
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let pages = NSMapTable<WKWebView, WebKitPage>.weakToWeakObjects()

    func attach(_ page: WebKitPage) {
        pages.setObject(page, forKey: page.webView)
        let controller = page.webView.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.addUserScript(WKUserScript(source: MediaStateScript.pageHook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: MediaStateScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        controller.add(self, contentWorld: Self.world, name: MediaStateScript.bindingName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let page = pages.object(forKey: webView),
              let report = MediaState.parse(message.body as? String ?? "") else { return }
        page.onEvent?(.media(report))
    }
}

/// Reports the page's registerProtocolHandler calls (MailHandlers.script) to MailHandlers, from
/// the main frame only. One handler per content controller, as for WebKitMediaBridge.
@MainActor
final class WebKitMailBridge: NSObject, WKScriptMessageHandler {
    static let shared = WebKitMailBridge()
    static let name = "kiteMailHandler"
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    func attach(_ page: WebKitPage) {
        let controller = page.webView.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        let send = "(() => { const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.name); "
            + "return h ? (s) => h.postMessage(s) : null; })()"
        controller.addUserScript(WKUserScript(source: MailHandlers.script(send: send), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.add(self, contentWorld: .page, name: Self.name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let call = MailHandlers.parse(message.body as? String ?? "") else { return }
        MailHandlers.shared.request(scheme: call.scheme, url: call.url, pageURL: webView.url, from: webView)
    }
}

/// Saves WebKit downloads to ~/Downloads without overwriting existing files, and lists them.
@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Test runs on a throwaway profile save into their own folder, never the user's Downloads.
        let environment = ProcessInfo.processInfo.environment
        if let test = environment["KITE_TEST_DOWNLOADS_PATH"], !test.isEmpty, environment["KITE_SUPPORT_PATH"] != nil {
            directory = URL(fileURLWithPath: test, isDirectory: true)
        }
        let destination = Self.uniqueURL(in: directory, name: suggestedFilename)
        DownloadsModel.shared.track(download, destination: destination, sourceTitle: download.webView?.title)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSApp.requestUserAttention(.informationalRequest)
        DownloadsModel.shared.webKitDownload(download, finished: .complete)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        DownloadsModel.shared.webKitDownload(download, finished: .interrupted)
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
