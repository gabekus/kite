import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Chosen in main.swift before the app finishes launching.
    var engine: WebEngine!

    private var store: BrowserStore!
    /// For Settings, which changes the search engine directly.
    var browserStore: BrowserStore? { store }
    private var history: HistoryStore!
    private(set) var keyBindings: KeyBindingsStore!
    private var adblocker: Adblocker!
    private(set) var windowController: BrowserWindowController!
    private var incognitoControllers: [BrowserWindowController] = []
    /// New and blank windows (⌘N, ⌃⌘N), restored on relaunch.
    private var windows: BrowserWindows!
    private var littleControllers: [LittleKiteWindowController] = []
    /// Installed web apps (File › Install Page as App…, Window › Web Apps, kite-app:// links).
    private(set) lazy var webApps = WebAppsController(supportDirectory: Self.supportDirectory)
    private lazy var airTraffic = AirTrafficControlStore(fileURL: Self.supportDirectory.appendingPathComponent("LinkRouting.json"))
    /// Routes menu commands to whichever browser window is in front.
    private var menuRouter: MenuRouter!
    private var archiveTimer: Timer?
    /// Settings › Links: the ⌥⌘N hotkey in any app, and "Archive Little Kites after:".
    private(set) var littleKiteHotkey: LittleKiteHotkey?
    private var littleArchiveTimer: Timer?
    #if canImport(CEFBridge)
    /// Shows extensions Kite's tabs (tabs.query and friends).
    /// One per Chromium profile in use: its extensions see the tabs in its profile.
    var extensionTabs: [String: ExtensionTabsBridge] = [:]
    #endif
    private var automation: AutomationController!
    private var claudeTasks: ClaudeTasksController!
    private var liveFolders: LiveFoldersController!
    private var diagnostics: DiagnosticsRecorder!
    /// Links opened before launch finished (Kite as the default browser).
    private var pendingURLs: [URL] = []
    #if canImport(CEFBridge)
    /// The menu bar's Extensions menu.
    var extensionsMenu: ExtensionsMenuBar?
    #endif


    /// Every browser window: the first, ⌘N and blank windows, and incognito windows.
    var browserControllers: [BrowserWindowController] {
        (windowController.map { [$0] } ?? []) + (windows?.all ?? []) + incognitoControllers
    }

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kite", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = BrowserStore(session: SessionStore(fileURL: Self.supportDirectory.appendingPathComponent("session.json")))
        store.archiveStaleTabs()
        applyPageAppearance()
        // Deleted profiles whose folders are gone (ProfileFolders) free their names.
        let removed = Set(store.state.retiredProfileDirectories.filter { !ProfileFolders.exists($0) })
        if !removed.isEmpty { store.mutate { $0.forgetRetiredProfiles(removed) } }
        history = HistoryStore(fileURL: Self.supportDirectory.appendingPathComponent("history.json"))
        store.historyRoot = history
        DownloadsModel.shared.start(fileURL: Self.supportDirectory.appendingPathComponent("downloads.json"))
        DownloadsModel.shared.currentTabTitle = { DownloadTidier.frontBrowser?.store.state.selectedTab?.title }
        BoostsModel.shared.start(fileURL: Self.supportDirectory.appendingPathComponent("boosts.json"))

        adblocker = Adblocker(directory: Self.supportDirectory.appendingPathComponent("Adblock", isDirectory: true))
        adblocker.setPolicy(enabled: store.state.blocksAds, allowedHosts: store.state.adblockAllowedHosts)
        engine.attach(adblocker)
        adblocker.start()

        windowController = BrowserWindowController(store: store, engine: engine, adblocker: adblocker)
        menuRouter = MenuRouter(fallback: windowController)
        NSApp.mainMenu = MainMenu.build(target: menuRouter)
        #if canImport(CEFBridge)
        if engine is ChromiumEngine, let mainMenu = NSApp.mainMenu {
            extensionsMenu = ExtensionsMenuBar(model: ExtensionsModel.shared(engine: engine))
            extensionsMenu?.install(in: mainMenu)
        }
        #endif
        keyBindings = KeyBindingsStore(fileURL: Self.supportDirectory.appendingPathComponent("keybindings.json"))
        keyBindings.apply(to: NSApp.mainMenu)
        // Registered after the menu bar is set so AppKit adds Help search and the window list.
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        windowController.showWindow(nil)
        windows = BrowserWindows(
            main: store, mainController: windowController, engine: engine, adblocker: adblocker,
            history: history, fileURL: Self.supportDirectory.appendingPathComponent("windows.json")
        )
        #if canImport(CEFBridge)
        windows.didMakeController = { [weak self] controller in self?.followProfiles(of: controller) }
        #endif
        windows.restore()
        setUpWebApps()

        automation = AutomationController(store: store, supportDirectory: Self.supportDirectory)
        automation.host = windowController
        windowController.installAutomationBanner(automation)
        automation.start()
        // A test build on a throwaway profile with KITE_DIAGNOSTICS=1 comes up ready for Claude.
        if UIDiagnostics.enabledByEnvironment && !automation.isEnabled { automation.setEnabled(true) }
        UIDiagnostics.shared.applySetting()
        automation.jev = JevClient.fromKeychain()
        claudeTasks = ClaudeTasksController(store: store, automation: automation, supportDirectory: Self.supportDirectory)
        // A notification clicked: the bubble, on that task.
        claudeTasks.showPanel = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            self?.windowController.window?.makeKeyAndOrderFront(nil)
            self?.windowController.claudeBubble.open(task: id)
        }
        claudeTasks.isPanelVisible = { [weak self] in self?.windowController.claudeBubble.isOpen == true }
        windowController.claudeBubble.tasks = claudeTasks
        windowController.hidesInsteadOfClosing = { [weak self] in self?.claudeTasks.isRunningAny == true }
        windowController.claudeButton.tasks = claudeTasks
        windowController.claudeButton.open = { [weak self] in self?.claudeButtonClicked() }
        #if canImport(CEFBridge)
        // Pages extensions open (welcome pages, chrome.windows.create) become background
        // tabs, so installing one doesn't pull you off the page you're on.
        ExtensionPopover.openTab = { [weak self] tab in
            guard let controller = self?.windowController else { return }
            switch tab {
            case .url(let url): controller.store.mutate { _ = $0.openTab(url: url) }
            case .page(let page): controller.pool.openTab(with: page)
            }
            controller.window?.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.addObserver(forName: .KCRuntimeOpenURL, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            MainActor.assumeIsolated { _ = self?.store.mutate { $0.openTab(url: url, select: false) } }
        }
        if windowController.pool.engine is ChromiumEngine {
            windowController.didSync = { [weak self] in self?.extensionTabs.values.forEach { $0.setNeedsUpdate() } }
            let engine = windowController.pool.engine
            VerificationCodeService.shared.configure(engine: engine)
            // The popup of the profile the button's window is showing.
            PasswordManagerFieldButton.open = { [weak self] view, popup in
                MainActor.assumeIsolated {
                    let controller = self?.browserControllers.first { $0.window === view.window }
                    return PasswordManagerIntegration.showPopup(engine: controller?.pool.currentEngine ?? engine,
                                                                relativeTo: view.bounds, of: view, popupURL: popup)
                }
            }
            prepareProfile(engine)
            followPasswordManager()
            for controller in browserControllers where !controller.isIncognito { followProfiles(of: controller) }
        }
        DownloadLocation.installForChromium()
        KCRuntime.extensionDialogAnchor = { [weak self] window in
            MainActor.assumeIsolated {
                guard let self else { return .zero }
                return self.browserControllers.first { $0.window === window }?.webAreaInWindow ?? .zero
            }
        }
        #endif
        // A diagnostics run stays in the background and behind the user's windows, so testing never takes their
        // focus or covers their work (capture reads covered windows).
        if UIDiagnostics.enabledByEnvironment {
            windowController.window?.orderBack(nil)
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // A test run (KITE_DIAGNOSTICS=1 on a throwaway profile) can open a link the way another
        // app would, without going through Launch Services and the user's default browser.
        if UIDiagnostics.enabledByEnvironment, let test = ProcessInfo.processInfo.environment["KITE_TEST_OPEN_URL"],
           let url = URL(string: test) {
            pendingURLs.append(url)
        }
        open(pendingURLs)
        pendingURLs = []
        // A test run can open the Zap picker directly (users open it from the Boost editor's Zap tool).
        // A test run can open the shown site's Boost editor (Edit Boost) 10 s after launch.
        if UIDiagnostics.enabledByEnvironment, ProcessInfo.processInfo.environment["KITE_TEST_BOOST_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.windowController.editBoost(nil) }
        }
        // "copy" opens it in copy selector mode (the editor's Pick Selector).
        if UIDiagnostics.enabledByEnvironment, let zap = ProcessInfo.processInfo.environment["KITE_TEST_ZAP_PICKER"], zap == "1" || zap == "copy" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.windowController.showZapPicker(boostID: nil, mode: zap == "copy" ? .copySelector : .zap)
            }
        }

        diagnostics = DiagnosticsRecorder(directory: Self.supportDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics.start()

        liveFolders = LiveFoldersController(store: store, engine: windowController.pool.engine) { [weak self] in
            self?.windowController.window?.contentView
        }
        LiveFoldersController.shared = liveFolders

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs() }
        }
        littleArchiveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveStaleLittleKites() }
        }
        littleKiteHotkey = LittleKiteHotkey(
            menuItem: { NSApp.mainMenu.flatMap { Self.menuItem(withID: "newLittleBrowserWindow", in: $0) } },
            onPress: { [weak self] in self?.openLittleKiteWindow(url: nil) }
        )
        keyBindings.didApply = { [weak self] in self?.littleKiteHotkey?.update() }
    }

    /// Links from other apps and opened HTML files, each in a new tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        if store == nil {
            pendingURLs += urls
        } else {
            open(urls)
        }
    }

    /// Air Traffic Control routes each web link: the first route that matches sends it to a
    /// space or Little Kite, else the default route (Little Kite while Kite menu → Open Links from
    /// Other Apps in Little Kite is on, Arc's default). Files and everything else open as tabs
    /// in the main window. mailto: links go to the default mail app (MailHandlers).
    private func open(_ urls: [URL]) {
        let little = LittleKite.opensExternalLinks(in: .standard)
        let spaceIDs = Set(store.state.spaces.map(\.id))
        var openedTab = false
        for url in urls {
            // A web app's launcher (~/Applications/Kite Apps/<Name>.app) opens kite-app://<id>.
            if webApps.handleLaunchURL(url) { continue }
            if MailHandler.isMailto(url) {
                // Kite as the default mail app (it registers for mailto, as Arc does): the default
                // web mail app's compose page in a new tab, else the system's mail app if that isn't Kite.
                if let compose = MailHandlers.shared.destination(for: url) {
                    store.mutate { _ = $0.openTab(url: compose) }
                    openedTab = true
                } else {
                    MailHandlers.shared.openInSystemMailApp(url)
                }
                continue
            }
            switch airTraffic.state.destination(for: url, spaceIDs: spaceIDs, opensExternalLinksInLittleKite: little) {
            case .littleKite:
                openLittleKiteWindow(url: url)
            case .mostRecentSpace:
                store.mutate { _ = $0.openTab(url: url) }
                openedTab = true
            case .space(let id):
                store.mutate { _ = $0.openTab(url: url, in: id) }
                openedTab = true
            }
        }
        if openedTab { windowController.window?.makeKeyAndOrderFront(nil) }
    }

    /// Installed apps' windows send links and popups to the main window, like Little Kite's.
    private func setUpWebApps() {
        let main = windowController!
        let store = self.store!
        webApps.host = WebAppsController.Host(
            engine: { [weak main] in main?.pool.engine ?? self.engine },
            openTab: { [weak main] url in
                store.mutate { _ = $0.openTab(url: url) }
                if !UIDiagnostics.enabledByEnvironment { main?.window?.makeKeyAndOrderFront(nil) }
            },
            adoptPopup: { [weak main] page in main?.adopt(page, url: nil, title: nil, in: nil) },
            move: { [weak main] page, url, title in main?.adopt(page, url: url, title: title, in: nil) },
            mainWindow: { [weak main] in main?.window }
        )
        WebAppInstallOffers.shared.isInstalled = { [weak webApps] id in webApps?.state.app(id: id) != nil }
        webApps.menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Web Apps")?.submenu
    }

    /// Kite menu → Air Traffic Control… (Arc: Preferences → Links → Air Traffic Control…).
    @objc func showAirTrafficControl(_ sender: Any?) {
        let store = self.store!
        AirTrafficControlWindow.show(store: airTraffic) {
            store.state.spaces.map { .init(id: $0.id, name: $0.name, icon: $0.icon) }
        }
    }

    /// File → New Little Kite Window (⌥⌘N) with no URL, or a link from another app.
    func openLittleKiteWindow(url: URL?) {
        let main = windowController!
        let store = self.store!
        func destination(_ space: Space) -> LittleKiteWindowController.Destination {
            .init(id: space.id, name: space.name, theme: space.theme)
        }
        let host = LittleKiteWindowController.Host(
            currentSpace: { destination(store.state.selectedSpace) },
            spaces: { store.state.spaces.map(destination) },
            resolve: { URLInput.resolve($0, engine: store.state.searchEngine) },
            move: { [weak main] page, url, title, spaceID in main?.adopt(page, url: url, title: title, in: spaceID) },
            openTab: { url in store.mutate { _ = $0.openTab(url: url) } },
            adoptPopup: { [weak main] page in main?.adopt(page, url: nil, title: nil, in: nil) },
            archive: { url, title, reason in
                store.mutate { _ = $0.archiveLittleKite(url: url, title: title ?? "", reason: reason) }
            }
        )
        let controller = LittleKiteWindowController(engine: main.pool.engine, url: url, host: host)
        controller.didClose = { [weak self] closed in self?.littleControllers.removeAll { $0 === closed } }
        littleControllers.append(controller)
        // Offset from another Little Kite window so they don't stack exactly.
        if let previous = littleControllers.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        }
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Settings › Links › "Archive Little Kites after:": closes Little Kite windows left unused that long.
    func archiveStaleLittleKites(now: Date = Date()) {
        let threshold = LittleKite.ArchiveThreshold.current(in: .standard)
        for controller in littleControllers { controller.archiveIfStale(threshold, now: now) }
    }

    static func menuItem(withID id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == id { return item }
            if let submenu = item.submenu, let found = menuItem(withID: id, in: submenu) { return found }
        }
        return nil
    }

    /// Kite menu → Open Links from Other Apps in Little Kite (Arc: Preferences → Links,
    /// "Links from other apps open in Little Arc").
    @objc func toggleLittleKiteLinks(_ sender: Any?) {
        UserDefaults.standard.set(!LittleKite.opensExternalLinks(in: .standard), forKey: LittleKite.opensExternalLinksKey)
    }

    /// Kite menu → Link Previews: Arc Max's ⇧-hover cards, off until turned on (Arc's `hoverCardsEnabled`).
    @objc func toggleLinkPreviews(_ sender: Any?) {
        UserDefaults.standard.set(!LinkPreview.isEnabled(in: .standard), forKey: LinkPreview.enabledKey)
    }

    /// Kite menu → Play Kite Sound Effects: Arc's "Play Arc sound effects", on by default.
    @objc func toggleSoundEffects(_ sender: Any?) {
        UserDefaults.standard.set(!SoundEffects.isEnabled(in: .standard), forKey: SoundEffects.enabledKey)
    }

    /// Kite menu → Tidy Tabs: Arc Max's Tidy button on the Today divider (Arc's `tidyTabsEnabled`,
    /// on in Gabe's Arc, so on by default).
    @objc func toggleTidyTabs(_ sender: Any?) {
        UserDefaults.standard.set(!TidyTabs.isEnabled(in: .standard), forKey: TidyTabs.enabledKey)
        // The sidebar reads the setting when it redraws.
        store.mutate { _ in }
    }

    /// Kite menu → Tidy Downloads: Arc Max's AI rename of finished downloads (Arc's `renameDownloadsEnabled`).
    @objc func toggleTidyDownloads(_ sender: Any?) {
        UserDefaults.standard.set(!TidyDownloads.isEnabled(in: .standard), forKey: TidyDownloads.enabledKey)
    }

    /// Kite menu → Show Full URL in Toolbar: the toolbar prints the whole address instead of the
    /// host (Arc: "Show full URL when Toolbar is enabled").
    @objc func toggleToolbarFullURLs(_ sender: Any?) {
        UserDefaults.standard.set(!ToolbarURL.showsFullURL(in: .standard), forKey: ToolbarURL.showsFullURLKey)
    }

    /// Kite menu → Ask on Page: Arc Max's find-bar questions, off until turned on (Arc's `askOnPageEnabled`).
    @objc func toggleAskOnPage(_ sender: Any?) {
        UserDefaults.standard.set(!AskOnPage.isEnabled(in: .standard), forKey: AskOnPage.enabledKey)
    }

    /// Kite menu → Tidy Tab Titles: Arc Max's AI names for tabs you pin (Arc's `renamePinnedTabsEnabled`).
    @objc func toggleTidyTabTitles(_ sender: Any?) {
        UserDefaults.standard.set(!TidyTabTitles.isEnabled(in: .standard), forKey: TidyTabTitles.enabledKey)
    }

    /// The extensions menu's links (Chrome Web Store, an extension's options), as a new tab.
    @objc func openURLFromExtensionsMenu(_ sender: Any?) {
        guard let url = sender as? URL else { return }
        store.mutate { _ = $0.openTab(url: url) }
    }

    /// Kite › Check for Updates…: asks GitHub releases; a release opens in a new tab.
    @objc func checkForUpdates(_ sender: Any?) {
        UpdaterWindow.shared.openURL = { [weak self] url in self?.store.mutate { _ = $0.openTab(url: url) } }
        UpdaterWindow.shared.checkForUpdates()
    }

    /// ⌘N: another window on the shared sidebar; with `url`, showing it instead of the command bar.
    func openNewWindow(url: URL? = nil) { windows.openNewWindow(url: url) }

    /// ⌃⌘N: a window with a sidebar of its own.
    func openBlankWindow() { windows.openBlankWindow() }

    /// ⇧⌘N. Each incognito window gets its own in-memory profile, gone when it closes. With `url`
    /// (the page menu's Open Link in Incognito Window) it shows that page instead of the command bar.
    @discardableResult
    func openIncognitoWindow(url: URL? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(
            store: .incognito(), engine: engine.makeEphemeral(), adblocker: adblocker, incognito: true
        )
        incognitoControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated { self?.incognitoControllers.removeAll { $0 === controller } }
        }
        // Offset from the window in front so the two don't stack exactly. Read it
        // before showWindow, which makes the new window main.
        let front = NSApp.mainWindow ?? windowController.window
        // Test runs stay behind the user's windows.
        if UIDiagnostics.enabledByEnvironment { controller.window?.orderBack(nil) } else { controller.showWindow(nil) }
        if let front, front !== controller.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        if let url { controller.store.mutate { _ = $0.openTab(url: url) } } else { controller.newTab(nil) }
        return controller
    }

    // MARK: AppleScript (AppleScript.swift)

    /// The browser windows AppleScript's `windows` lists, front to back.
    var scriptControllers: [BrowserWindowController] {
        guard let windowController else { return [] }
        let all = [windowController] + windows.all + incognitoControllers
        return NSApp.orderedWindows.compactMap { window in all.first { $0.window === window } }
    }

    /// `make new window`: File › New Window, or New Incognito Window.
    func openScriptWindow(incognito: Bool) -> BrowserWindowController {
        incognito ? openIncognitoWindow() : windows.openNewWindow()
    }

    var allowsJavaScriptFromAppleEvents: Bool { store?.state.allowsJavaScriptFromAppleEvents ?? false }

    /// View › Developer › Allow JavaScript from Apple Events (Arc's item, off by default).
    @objc func toggleJavaScriptFromAppleEvents(_ sender: Any?) {
        store.mutate { $0.allowsJavaScriptFromAppleEvents.toggle() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The Dock icon brings back the window hidden while Claude tasks ran.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { windowController?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        claudeTasks?.stopAll()
        claudeTasks?.saveNow()
        windows?.applicationWillTerminate()
        saveSession()
        automation?.shutdown()
    }

    func saveSession() {
        store?.saveNow()
        history?.saveNow()
        DownloadsModel.shared.saveNow()
        BoostsModel.shared.flush()
    }

    // MARK: Settings

    /// Kite → Settings… (⌘,).
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// Chromium's Energy Saver (30fps on low battery). Off unless the user turns it on.
    static let energySaverKey = "chromiumEnergySaver"

    @objc func toggleEnergySaver(_ sender: Any?) {
        #if canImport(CEFBridge)
        KCRuntime.energySaverEnabled.toggle()
        UserDefaults.standard.set(KCRuntime.energySaverEnabled, forKey: Self.energySaverKey)
        #endif
    }

    /// Kite menu → Archive tabs after, until there's a Settings window. The tag is the ArchiveInterval's index.
    @objc func setArchiveInterval(_ sender: NSMenuItem) {
        let intervals = ArchiveInterval.allCases
        guard intervals.indices.contains(sender.tag) else { return }
        store.mutate { $0.archiveAfter = intervals[sender.tag] }
        store.archiveStaleTabs()
    }

    // MARK: Quitting

    /// ⌘Q and Kite → Quit Kite. Only these ask first: quits from the Dock, scripts
    /// (scripts/install-app.sh) and logging out go straight to terminate.
    @objc func quitKite(_ sender: Any?) {
        guard let store, store.state.warnsBeforeQuitting else { return NSApp.terminate(sender) }
        switch QuitDialog.run(over: NSApp.keyWindow ?? NSApp.mainWindow) {
        case .quit:
            NSApp.terminate(sender)
        case .quitAndDontAskAgain:
            store.mutate { $0.warnsBeforeQuitting = false }
            NSApp.terminate(sender)
        case .cancel:
            break
        }
    }

    /// Every quit (⌘Q after "Quit Kite?", the Dock, scripts, logging out) stops here while
    /// downloads are running: Arc's "Downloads in progress" asks first, from its own
    /// applicationShouldTerminate(_:). Close Kite cancels them; Keep browsing cancels the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = DownloadsModel.shared.list.active
        guard !active.isEmpty else { return .terminateNow }
        guard QuitDialog.runDownloadsInProgress(over: NSApp.keyWindow ?? NSApp.mainWindow) else { return .terminateCancel }
        active.forEach { DownloadsModel.shared.cancel($0) }
        return .terminateNow
    }

    // MARK: View › Appearance

    /// View › Appearance, by Arc's selectors (its AppDelegate's setAutomatic/Light/DarkAppearance:).
    /// Like Arc, it sets the app's appearance: CEF and WebKit hand it to pages as
    /// `prefers-color-scheme`. Views with an appearance of their own (the sidebar's, from the space
    /// theme) keep it.
    @objc func setAutomaticAppearance(_ sender: Any?) { setPageAppearance(.automatic) }
    @objc func setLightAppearance(_ sender: Any?) { setPageAppearance(.light) }
    @objc func setDarkAppearance(_ sender: Any?) { setPageAppearance(.dark) }

    private func setPageAppearance(_ appearance: PageAppearance) {
        store.mutate { $0.pageAppearance = appearance }
        applyPageAppearance()
    }

    private func applyPageAppearance() {
        NSApp.appearance = store.state.pageAppearance.appearanceName.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
    }

    /// Kite menu → Warn Before Quitting, until there's a Settings window (Arc has it in General).
    @objc func toggleQuitWarning(_ sender: Any?) {
        store.mutate { $0.warnsBeforeQuitting.toggle() }
    }

    // MARK: Claude

    @objc func toggleClaudeSpace(_ sender: Any?) {
        automation.setUseClaudeSpace(!automation.settings.useClaudeSpace)
    }

    /// Kite menu → Ask Claude in the Claude App: where ⌘J sends requests.
    @objc func toggleClaudeRunsInDesktop(_ sender: Any?) {
        claudeTasks.runsIn = claudeTasks.runsIn == .desktop ? .kite : .desktop
    }

    /// Kite menu → Ask Before Claude Acts: confirm commits, file opens and closing the user's tabs.
    @objc func toggleAskBeforeClaudeActs(_ sender: Any?) {
        automation.setAskBeforeActing(!automation.settings.askBeforeActing)
    }

    @objc func toggleRecordNetwork(_ sender: Any?) {
        automation.setRecordNetwork(!automation.settings.recordNetwork)
    }

    /// The sidebar's Claude button: sets Claude up the first time, then toggles the bubble.
    private func claudeButtonClicked() {
        guard !claudeTasks.isSetUp else { return windowController.claudeBubble.toggle() }
        Task { @MainActor in
            if await claudeTasks.setUp() { windowController.claudeBubble.open() }
        }
    }


    @objc func connectClaudeCode(_ sender: Any?) {
        if !automation.isEnabled { automation.setEnabled(true) }
        guard automation.isEnabled else { return }
        ClaudeConnect.present(automation)
    }

    @objc func toggleClaudeDiagnostics(_ sender: Any?) {
        UIDiagnostics.shared.setEnabled(!UserDefaults.standard.bool(forKey: UIDiagnostics.defaultsKey))
    }

    @objc func toggleClaudeControl(_ sender: Any?) {
        let enable = !automation.isEnabled
        automation.setEnabled(enable)
        guard enable, automation.isEnabled else { return }
        let alert = NSAlert()
        alert.messageText = "Claude can now control Kite"
        alert.informativeText = """
            To connect Claude Code, run:

            \(automation.claudeCodeCommand)

            Or choose Connect Claude… to have Kite do it, for Claude Code and the Claude app.

            Kite shows when Claude is controlling a tab. To be asked before Claude submits a form, sends, posts, \
            pays, buys or deletes anything, turn on Ask Before Claude Acts. Turn this off in the Kite menu at any time.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Connect Claude…")
        if alert.runModal() == .alertSecondButtonReturn {
            ClaudeConnect.present(automation)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let automation else { return true }
        switch item.action {
        case #selector(toggleClaudeControl(_:)):
            item.state = automation.isEnabled ? .on : .off
        case #selector(toggleClaudeSpace(_:)):
            item.state = automation.settings.useClaudeSpace ? .on : .off
            return automation.isEnabled
        case #selector(toggleClaudeDiagnostics(_:)):
            item.state = UIDiagnostics.isEnabled ? .on : .off
            return automation.isEnabled && !UIDiagnostics.enabledByEnvironment
        case #selector(toggleClaudeRunsInDesktop(_:)):
            item.state = claudeTasks?.runsIn == .desktop ? .on : .off
            return ClaudeDesktop.isInstalled
        case #selector(toggleAskBeforeClaudeActs(_:)):
            item.state = automation.settings.askBeforeActing ? .on : .off
            return automation.isEnabled
        case #selector(toggleRecordNetwork(_:)):
            item.state = automation.settings.recordNetwork ? .on : .off
            return automation.isEnabled
        default:
            break
        }
        if item.action == #selector(setArchiveInterval(_:)), let store {
            item.state = ArchiveInterval.allCases.firstIndex(of: store.state.archiveAfter) == item.tag ? .on : .off
        }
        if item.action == #selector(toggleTidyDownloads(_:)) {
            item.state = TidyDownloads.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleLinkPreviews(_:)) {
            item.state = LinkPreview.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleSoundEffects(_:)) {
            item.state = SoundEffects.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleTidyTabs(_:)) {
            item.state = TidyTabs.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleToolbarFullURLs(_:)) {
            item.state = ToolbarURL.showsFullURL(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleAskOnPage(_:)) {
            item.state = AskOnPage.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleTidyTabTitles(_:)) {
            item.state = TidyTabTitles.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleLittleKiteLinks(_:)) {
            item.state = LittleKite.opensExternalLinks(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleJavaScriptFromAppleEvents(_:)) {
            item.state = allowsJavaScriptFromAppleEvents ? .on : .off
        }
        // Arc checks the item matching NSApp.appearance (none set: Automatic).
        let appearances: [Selector: PageAppearance] = [
            #selector(setAutomaticAppearance(_:)): .automatic,
            #selector(setLightAppearance(_:)): .light,
            #selector(setDarkAppearance(_:)): .dark,
        ]
        if let action = item.action, let appearance = appearances[action] {
            item.state = PageAppearance(appearanceName: NSApp.appearance?.name.rawValue) == appearance ? .on : .off
        }
        if item.action == #selector(toggleQuitWarning(_:)), let store {
            item.state = store.state.warnsBeforeQuitting ? .on : .off
        }
        if item.action == #selector(toggleEnergySaver(_:)) {
            #if canImport(CEFBridge)
            item.state = KCRuntime.energySaverEnabled ? .on : .off
            return KCRuntime.isInitialized
            #else
            return false
            #endif
        }
        return true
    }
}
