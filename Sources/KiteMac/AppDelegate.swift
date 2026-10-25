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
    /// Routes menu commands to whichever browser window is in front.
    private var menuRouter: MenuRouter!
    private var archiveTimer: Timer?
    private var automation: AutomationController!
    private var diagnostics: DiagnosticsRecorder!
    /// Links opened before launch finished (Kite as the default browser).
    private var pendingURLs: [URL] = []


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

        adblocker = Adblocker(directory: Self.supportDirectory.appendingPathComponent("Adblock", isDirectory: true))
        adblocker.setPolicy(enabled: store.state.blocksAds, allowedHosts: store.state.adblockAllowedHosts)
        engine.attach(adblocker)
        adblocker.start()

        windowController = BrowserWindowController(store: store, engine: engine, adblocker: adblocker)
        menuRouter = MenuRouter(fallback: windowController)
        NSApp.mainMenu = MainMenu.build(target: menuRouter)
        keyBindings = KeyBindingsStore(fileURL: Self.supportDirectory.appendingPathComponent("keybindings.json"))
        keyBindings.apply(to: NSApp.mainMenu)
        // Registered after the menu bar is set so AppKit adds Help search and the window list.
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        windowController.showWindow(nil)

        automation = AutomationController(store: store, supportDirectory: Self.supportDirectory)
        automation.host = windowController
        windowController.installAutomationBanner(automation)
        automation.start()
        NSApp.activate(ignoringOtherApps: true)
        open(pendingURLs)
        pendingURLs = []

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

    private func open(_ urls: [URL]) {
        for url in urls {
            store.mutate { _ = $0.openTab(url: url) }
        }
        if !urls.isEmpty { windowController.window?.makeKeyAndOrderFront(nil) }
    }

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

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        automation?.shutdown()
    }

    func saveSession() {
        store?.saveNow()
        history?.saveNow()
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

    @objc func toggleClaudeJavaScript(_ sender: Any?) {
        automation.setAllowJavaScript(!automation.settings.allowJavaScript)
    }

    @objc func toggleClaudeSpace(_ sender: Any?) {
        automation.setUseClaudeSpace(!automation.settings.useClaudeSpace)
    }

    @objc func connectClaudeCode(_ sender: Any?) {
        if !automation.isEnabled { automation.setEnabled(true) }
        guard automation.isEnabled else { return }
        ClaudeConnect.present(automation)
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

            Or choose Connect Claude Code… to have Kite do it.

            Kite asks you before Claude submits a form, sends, posts, pays, buys or deletes anything, and shows \
            when Claude is controlling a tab. Turn this off in the Kite menu at any time.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Connect Claude Code…")
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
        case #selector(toggleClaudeJavaScript(_:)):
            item.state = automation.settings.allowJavaScript ? .on : .off
            return automation.isEnabled
        case #selector(toggleClaudeSpace(_:)):
            item.state = automation.settings.useClaudeSpace ? .on : .off
            return automation.isEnabled
        default:
            break
        }
        if item.action == #selector(setArchiveInterval(_:)), let store {
            item.state = ArchiveInterval.allCases.firstIndex(of: store.state.archiveAfter) == item.tag ? .on : .off
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
