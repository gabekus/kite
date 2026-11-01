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
    private var history: HistoryStore!
    private(set) var keyBindings: KeyBindingsStore!
    private var adblocker: Adblocker!
    private var windowController: BrowserWindowController!
    private var incognitoControllers: [BrowserWindowController] = []
    /// New and blank windows (⌘N, ⌃⌘N), restored on relaunch.
    private var windows: BrowserWindows!
    private var littleControllers: [LittleKiteWindowController] = []
    private lazy var airTraffic = AirTrafficControlStore(fileURL: Self.supportDirectory.appendingPathComponent("LinkRouting.json"))
    /// Routes menu commands to whichever browser window is in front.
    private var menuRouter: MenuRouter!
    private var archiveTimer: Timer?
    #if canImport(CEFBridge)
    /// Shows extensions Kite's tabs (tabs.query and friends).
    private var extensionTabs: ExtensionTabsBridge?
    #endif
    private var automation: AutomationController!
    private var claudeTasks: ClaudeTasksController!
    private var diagnostics: DiagnosticsRecorder!
    /// Links opened before launch finished (Kite as the default browser).
    private var pendingURLs: [URL] = []
    #if canImport(CEFBridge)
    /// The menu bar's Extensions menu.
    private var extensionsMenu: ExtensionsMenuBar?
    #endif


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
        history = HistoryStore(fileURL: Self.supportDirectory.appendingPathComponent("history.json"))
        store.history = history
        DownloadsModel.shared.start(fileURL: Self.supportDirectory.appendingPathComponent("downloads.json"))

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
        windows.restore()

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
            let bridge = ExtensionTabsBridge(host: windowController)
            windowController.didSync = { [weak bridge] in bridge?.setNeedsUpdate() }
            bridge.start(engine: windowController.pool.engine)
            extensionTabs = bridge
            // Once the window is up, so Chrome's "Add 1Password?" dialog has somewhere to hang.
            let engine = windowController.pool.engine
            VerificationCodeService.shared.configure(engine: engine)
            OnePasswordFieldButton.open = { view in
                MainActor.assumeIsolated { OnePasswordIntegration.showPopup(engine: engine, relativeTo: view.bounds, of: view) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { OnePasswordIntegration.installIfNeeded(engine: engine) }
        }
        KCRuntime.extensionDialogAnchor = { [weak self] window in
            MainActor.assumeIsolated {
                guard let self else { return .zero }
                let controllers = [self.windowController!] + self.windows.all + self.incognitoControllers
                return controllers.first { $0.window === window }?.webAreaInWindow ?? .zero
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
        // A test run can open the Zap picker, which has no menu item until Kite has Arc's Boost editor.
        if UIDiagnostics.enabledByEnvironment, ProcessInfo.processInfo.environment["KITE_TEST_ZAP_PICKER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.windowController.showZapPicker(nil) }
        }

        diagnostics = DiagnosticsRecorder(directory: Self.supportDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics.start()

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs() }
        }
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
    /// in the main window.
    private func open(_ urls: [URL]) {
        let little = LittleKite.opensExternalLinks(in: .standard)
        let spaceIDs = Set(store.state.spaces.map(\.id))
        var openedTab = false
        for url in urls {
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
            adoptPopup: { [weak main] page in main?.adopt(page, url: nil, title: nil, in: nil) }
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

    /// Kite menu → Open Links from Other Apps in Little Kite (Arc: Preferences → Links,
    /// "Links from other apps open in Little Arc").
    @objc func toggleLittleKiteLinks(_ sender: Any?) {
        UserDefaults.standard.set(!LittleKite.opensExternalLinks(in: .standard), forKey: LittleKite.opensExternalLinksKey)
    }

    /// Kite menu → Link Previews: Arc Max's ⇧-hover cards, off until turned on (Arc's `hoverCardsEnabled`).
    @objc func toggleLinkPreviews(_ sender: Any?) {
        UserDefaults.standard.set(!LinkPreview.isEnabled(in: .standard), forKey: LinkPreview.enabledKey)
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

    /// ⌘N: another window on the shared sidebar.
    func openNewWindow() { windows.openNewWindow() }

    /// ⌃⌘N: a window with a sidebar of its own.
    func openBlankWindow() { windows.openBlankWindow() }

    /// ⇧⌘N. Each incognito window gets its own in-memory profile, gone when it closes.
    func openIncognitoWindow() {
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
        controller.showWindow(nil)
        if let front, front !== controller.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        controller.newTab(nil)
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
    }

    // MARK: Settings

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

            Kite asks you before Claude submits a form, sends, posts, pays, buys or deletes anything, and shows \
            when Claude is controlling a tab. Turn this off in the Kite menu at any time.
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
        case #selector(toggleRecordNetwork(_:)):
            item.state = automation.settings.recordNetwork ? .on : .off
            return automation.isEnabled
        default:
            break
        }
        if item.action == #selector(setArchiveInterval(_:)), let store {
            item.state = ArchiveInterval.allCases.firstIndex(of: store.state.archiveAfter) == item.tag ? .on : .off
        }
        if item.action == #selector(toggleLinkPreviews(_:)) {
            item.state = LinkPreview.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleTidyTabTitles(_:)) {
            item.state = TidyTabTitles.isEnabled(in: .standard) ? .on : .off
        }
        if item.action == #selector(toggleLittleKiteLinks(_:)) {
            item.state = LittleKite.opensExternalLinks(in: .standard) ? .on : .off
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
