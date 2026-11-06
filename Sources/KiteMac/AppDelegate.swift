import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Chosen in main.swift before the app finishes launching.
    var engine: WebEngine!
    /// Chromium didn't start, even after Kite started itself again, so this run is on WebKit (`EngineFallback`).
    nonisolated(unsafe) static var engineFellBack = false

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
    private(set) lazy var airTraffic = AirTrafficControlStore(fileURL: Self.supportDirectory.appendingPathComponent("LinkRouting.json"))
    /// Routes menu commands to whichever browser window is in front.
    private var menuRouter: MenuRouter!
    private var archiveTimer: Timer?
    /// Settings › Links: the ⌥⌘N hotkey in any app, and "Archive Little Kites after:".
    private(set) var littleKiteHotkey: LittleKiteHotkey?
    #if canImport(CEFBridge)
    /// Shows extensions Kite's tabs (tabs.query and friends).
    /// One per Chromium profile in use: its extensions see the tabs in its profile.
    var extensionTabs: [String: ExtensionTabsBridge] = [:]
    #endif
    private var automation: AutomationController!
    private var claudeTasks: ClaudeTasksController!
    /// The user's own Claude Code sessions, in the ⌘J bar's Claude Code side.
    private var claudeCode: ClaudeCodeSessionsController!
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

    static var sessionURL: URL { supportDirectory.appendingPathComponent("session.json") }
    /// Each tab's back/forward list, so tabs keep it across relaunches.
    static let tabHistory = TabHistoryStore(directory: supportDirectory.appendingPathComponent("Tab History", isDirectory: true))

    func applicationDidFinishLaunching(_ notification: Notification) {
        // On WebKit because Chromium didn't start: say so once the window is up, rather than show empty, signed-out pages.
        if Self.engineFellBack {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = EngineFallback.alertTitle
                alert.informativeText = EngineFallback.alertText
                alert.addButton(withTitle: "Quit Kite")
                alert.addButton(withTitle: "Keep Using It")
                if WindowPresenter.runModal(alert) == .alertFirstButtonReturn { NSApp.terminate(nil) }
            }
        }
        // Release builds check for updates (8-hourly, installing on quit); others do nothing.
        SoftwareUpdater.shared.start()
        // The installed Kite: web links going to a test build of Kite get an alert (RealProfileGuard).
        RealProfileRefusal.checkDefaultBrowser()
        // The login shell's PATH and claude, asked once in the background, so the first claude doesn't wait.
        ClaudeConnect.loginShell.warm()
        // A typed claude:// (zoommtg://, …) link is a URL when another app opens it, not a search.
        URLInput.appOpens = { url in
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
            return Bundle(url: app)?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        // Before the store writes session.json, which tells a new profile from an existing install.
        let showsOnboarding = OnboardingWindow.shouldShowAtLaunch()
        store = BrowserStore(session: SessionStore(fileURL: Self.sessionURL))
        store.archiveStaleTabs()
        applyPageAppearance()
        // Deleted profiles whose folders are gone (ProfileFolders) free their names.
        let removed = Set(store.state.retiredProfileDirectories.filter { !ProfileFolders.exists($0) })
        if !removed.isEmpty { store.mutateWithoutUndo { $0.forgetRetiredProfiles(removed) } }
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
        WindowPresenter.show(windowController)
        windows = BrowserWindows(
            main: store, mainController: windowController, engine: engine, adblocker: adblocker,
            history: history, fileURL: Self.supportDirectory.appendingPathComponent("windows.json")
        )
        windows.didMakeController = { [weak self] controller in
            #if canImport(CEFBridge)
            self?.followProfiles(of: controller)
            #endif
            // Windows restored now are set up once Claude's controllers exist (below).
            if self?.claudeCode != nil { self?.setUpForClaude(controller) }
        }
        windows.normalWindowClosing = { [weak self] controller in self?.normalWindowClosing(controller) }
        windows.restore()
        forgetClosedTabsHistory()
        if let backup = store.recoveredFromBackup {
            let date = DateFormatter.localizedString(from: backup.date, dateStyle: .medium, timeStyle: .short)
            windowController.showToast("Kite restored your tabs from a backup made \(date)")
        }
        setUpWebApps()
        setUpVPNSignIn()

        automation = AutomationController(store: store, supportDirectory: Self.supportDirectory)
        automation.attach(windowController)
        automation.ensureWindow = { [weak self] in self?.ensureAutomationWindow() }
        automation.start()
        // A test build on a throwaway profile with KITE_DIAGNOSTICS=1 comes up ready for Claude.
        if UIDiagnostics.enabledByEnvironment && !automation.isEnabled { automation.setEnabled(true) }
        UIDiagnostics.shared.applySetting()
        automation.jev = JevClient.shared
        claudeTasks = ClaudeTasksController(store: store, automation: automation, supportDirectory: Self.supportDirectory)
        // A notification clicked: the bubble, on that task.
        claudeTasks.showPanel = { [weak self] id in
            // The tools' window, where the task's tabs are. A diagnostics run stays behind the user's windows
            // (kite test-ticket opens the bar too).
            guard let self, let controller = claudeWindow(opening: .user) else { return }
            WindowPresenter.show(controller.window, activate: true)
            controller.claudeBubble.open(task: id)
        }
        claudeTasks.isPanelVisible = { [weak self] in self?.browserControllers.contains { $0.claudeBubble.isOpen } == true }
        claudeCode = ClaudeCodeSessionsController(supportDirectory: Self.supportDirectory)
        // Every normal window, made now or later (didMakeController), gets Claude's hooks and protections once.
        for controller in [windowController!] + windows.all where windows.isNormal(controller) { setUpForClaude(controller) }
        #if canImport(CEFBridge)
        // Pages extensions open (welcome pages, chrome.windows.create) become background
        // tabs, so installing one doesn't pull you off the page you're on.
        ExtensionPopover.openTab = { [weak self] tab in
            guard let controller = self?.windows.currentNormal(opening: .user) else { return }
            switch tab {
            case .url(let url): controller.store.mutateWithoutUndo { _ = $0.openTab(url: url) }
            case .page(let page): controller.pool.openTab(with: page)
            }
            WindowPresenter.show(controller.window)
        }
        NotificationCenter.default.addObserver(forName: .KCRuntimeOpenURL, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            MainActor.assumeIsolated { _ = self?.store.mutateWithoutUndo { $0.openTab(url: url, select: false) } }
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
        if WindowPresenter.testSafe { NSApp.setActivationPolicy(.regular) } else { WindowPresenter.activateApp() }
        // A test run (KITE_DIAGNOSTICS=1 on a throwaway profile) can open a link the way another
        // app would, without going through Launch Services and the user's default browser.
        if UIDiagnostics.enabledByEnvironment, let test = ProcessInfo.processInfo.environment["KITE_TEST_OPEN_URL"],
           let url = URL(string: test) {
            pendingURLs.append(url)
        }
        open(pendingURLs)
        pendingURLs = []
        // A test run can show the main window again after it was closed, as the Dock icon does
        // (`applicationShouldHandleReopen`), KITE_TEST_REOPEN_MAIN_AFTER seconds after launch; behind the user's windows.
        if UIDiagnostics.enabledByEnvironment, let delay = ProcessInfo.processInfo.environment["KITE_TEST_REOPEN_MAIN_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.windowController.window?.isVisible == false { WindowPresenter.showInBackground(self?.windowController.window) }
            }
        }
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
        // A test-safe run can open the main window's find bar (KITE_TEST_FIND_OPEN=1), with a query
        // (KITE_TEST_FIND=text), once its page has loaded: FindTestHook. A real profile ignores both.
        FindTestHookRunner.start(in: windowController)
        // A test-safe run can open the icon picker for a named space (KITE_TEST_ICON_PICKER=name), or Create a Space
        // (KITE_TEST_NEW_SPACE=1, with a name and a preset picked and the theme editor open): SidebarTestHook. A real
        // profile ignores them.
        SidebarTestHookRunner.start(in: windowController)

        diagnostics = DiagnosticsRecorder(directory: Self.supportDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics.start()

        liveFolders = LiveFoldersController(store: store, engine: windowController.pool.engine) { [weak self] in
            self?.windowController.window?.contentView
        }
        LiveFoldersController.shared = liveFolders

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs() }
        }
        // Archiving hours-old tabs can wait a few minutes, so the system can batch the wakeup with others.
        archiveTimer?.tolerance = 3 * 60
        littleKiteHotkey = LittleKiteHotkey(
            menuItem: { NSApp.mainMenu.flatMap { Self.menuItem(withID: "newLittleBrowserWindow", in: $0) } },
            onPress: { [weak self] in self?.openLittleKiteWindow(url: nil) }
        )
        keyBindings.didApply = { [weak self] in self?.littleKiteHotkey?.update() }
        if showsOnboarding { showGettingStarted(nil) }
    }

    /// Help › Getting Started, and onboarding on a new profile's first launch.
    @objc func showGettingStarted(_ sender: Any?) {
        OnboardingWindow.show { [weak self] in
            guard let self else { return nil }
            return windows.currentNormal(visibleOnly: true) ?? windows.openNewWindow()
        }
    }

    /// Help › Restore Data: the main window's store writes the session, so it's the one restored.
    @objc func showRestoreData(_ sender: Any?) {
        guard let store, let backups = store.sessionBackups else { return NSSound.beep() }
        RestoreDataWindow.show(store: store, backups: backups)
    }

    /// Links from other apps and opened HTML and PDF files, each in a new tab.
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
        // Tabs open in the window in front (a new one if every normal window has closed), never a closed one.
        var target: BrowserWindowController?
        func targetStore() -> BrowserStore {
            if target == nil { target = windows.currentNormal(opening: .user) }
            return target?.store ?? store
        }
        for url in urls {
            // A javascript: or data: URL from another app (`open location`) would be AppleScript's `execute`
            // by another name: refused, as the scripting dictionary refuses it, unless Allow JavaScript from
            // Apple Events is on.
            guard AppleScripting.mayLoad(url, allowsJavaScript: allowsJavaScriptFromAppleEvents) else {
                NSLog("Kite: refused a \(url.scheme ?? "") URL from another app: Allow JavaScript from Apple Events is off")
                continue
            }
            // A web app's launcher (~/Applications/Kite Apps/<Name>.app) opens kite-app://<id>.
            if webApps.handleLaunchURL(url) { continue }
            if MailHandler.isMailto(url) {
                // Kite as the default mail app (it registers for mailto, as Arc does): the default
                // web mail app's compose page in a new tab, else the system's mail app if that isn't Kite.
                if let compose = MailHandlers.shared.destination(for: url) {
                    targetStore().mutateWithoutUndo { _ = $0.openTab(url: compose) }
                } else {
                    MailHandlers.shared.openInSystemMailApp(url)
                }
                continue
            }
            let destination = airTraffic.state.destination(for: url, spaceIDs: spaceIDs, opensExternalLinksInLittleKite: little)
            // A VPN client's sign-in page on a watched host signs in on a hidden page (VPNSignIn).
            if case .space(let id) = destination {
                if VPNSignInController.shared.handle(url, spaceID: id) { continue }
            } else if VPNSignInController.shared.handle(url, spaceID: nil) {
                continue
            }
            switch destination {
            case .littleKite:
                openLittleKiteWindow(url: url)
            case .mostRecentSpace:
                targetStore().mutateWithoutUndo { _ = $0.openTab(url: url) }
            case .space(let id):
                targetStore().mutateWithoutUndo { _ = $0.openTab(url: url, in: id) }
            }
        }
        if let target { WindowPresenter.show(target.window) }
    }

    /// Quiet VPN sign-in loads in the destination space's profile, and shows a page that needs
    /// the user as a tab behind the selected one, without raising the window.
    private func setUpVPNSignIn() {
        let main = windowController!
        let store = self.store!
        VPNSignInController.shared.host = .init(
            engine: { [weak main] spaceID in
                let state = store.state
                let engine = main?.pool.engine ?? self.engine!
                guard engine.profileDirectory != nil else { return engine }
                let index = spaceID.flatMap(state.spaceIndex) ?? state.selectedSpaceIndex
                return engine.forProfile(state.profile(state.profileDirectory(ofSpace: index)))
            },
            showInBackground: { [weak self] page, url, title, spaceID, profile in
                // A live normal window's pool (one opened behind, if none is left), never a closed one's.
                guard let target = self?.windows.currentNormal(prefer: self?.automation?.host as? BrowserWindowController,
                                                               opening: .automation) else { return page.close() }
                let id = target.pool.adopt(page, profileDirectory: profile)
                // Kite's VPN sign-in, not the user's step to undo.
                target.store.mutateWithoutUndo { _ = $0.openTab(id: id, url: url, in: spaceID, select: false) }
                target.store.pageTitleChanged(id, title)
            }
        )
    }

    /// Installed apps' windows send links and popups to the window in front, like Little Kite's.
    private func setUpWebApps() {
        let main = windowController!
        webApps.host = WebAppsController.Host(
            engine: { [weak main] in main?.pool.engine ?? self.engine },
            openTab: { [weak self] url in
                guard let target = self?.windows.currentNormal(opening: .user) else { return }
                target.store.mutateWithoutUndo { _ = $0.openTab(url: url) }
                WindowPresenter.show(target.window)
            },
            adoptPopup: { [weak self] page in self?.windows.currentNormal(opening: .user)?.adopt(page, url: nil, title: nil, in: nil) },
            move: { [weak self] page, url, title in
                self?.windows.currentNormal(opening: .user)?.adopt(page, url: url, title: title, in: nil)
            },
            mainWindow: { [weak self] in self?.windows.currentNormal()?.window }
        )
        WebAppInstallOffers.shared.isInstalled = { [weak webApps] id in webApps?.state.app(id: id) != nil }
        webApps.menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Web Apps")?.submenu
    }

    /// Kite menu → Air Traffic Control… (Arc: Preferences → Links → Air Traffic Control…).
    @objc func showAirTrafficControl(_ sender: Any?) {
        let store = self.store!
        AirTrafficControlWindow.show(store: airTraffic) {
            store.state.spaces.map { .init(id: $0.id, name: $0.name, icon: $0.iconText) }
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
            profiles: { store.state.allProfiles },
            initialProfile: { store.state.profile(store.state.selectedProfileDirectory) },
            engine: { [weak main] profile in (main?.pool.engine ?? self.engine).forProfile(profile) },
            move: { [weak self] page, url, title, spaceID, profile in
                self?.windows.currentNormal(opening: .user)?.adopt(page, url: url, title: title, in: spaceID, profileDirectory: profile)
            },
            openTab: { [weak self] url in
                (self?.windows.currentNormal(opening: .user)?.store ?? store).mutateWithoutUndo { _ = $0.openTab(url: url) }
            },
            adoptPopup: { [weak self] page in self?.windows.currentNormal(opening: .user)?.adopt(page, url: nil, title: nil, in: nil) },
            archive: { url, title, reason in
                store.mutateWithoutUndo { _ = $0.archiveLittleKite(url: url, title: title ?? "", reason: reason) }
            }
        )
        let controller = LittleKiteWindowController(url: url, host: host)
        controller.didClose = { [weak self] closed in self?.littleControllers.removeAll { $0 === closed } }
        littleControllers.append(controller)
        // Offset from another Little Kite window so they don't stack exactly.
        if let previous = littleControllers.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        }
        // A test-safe run keeps it behind the user's windows.
        WindowPresenter.show(controller, activate: true)
    }

    /// Settings › Links › "Archive Little Kites after:": closes Little Kite windows left unused that long. Each
    /// window keeps its own timer (`LittleKiteWindowController.scheduleArchive`); a changed setting reschedules them.
    func archiveStaleLittleKites(now: Date = Date()) {
        for controller in littleControllers { controller.scheduleArchive(now: now) }
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
        store.mutateWithoutUndo { _ in }
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
        store.mutateWithoutUndo { _ = $0.openTab(url: url) }
    }

    /// Kite › Check for Updates…: Sparkle in a release build (SoftwareUpdater); otherwise asks GitHub
    /// releases, and a release opens in a new tab.
    @objc func checkForUpdates(_ sender: Any?) {
        if SoftwareUpdater.shared.checkForUpdates() { return }
        UpdaterWindow.shared.openURL = { [weak self] url in self?.store.mutateWithoutUndo { _ = $0.openTab(url: url) } }
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
        let ephemeral = engine.makeEphemeral()
        let downloadContext = ephemeral.downloadContextKey
        let controller = BrowserWindowController(
            store: .incognito(), engine: ephemeral, adblocker: adblocker, incognito: true
        )
        incognitoControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                self?.incognitoControllers.removeAll { $0 === controller }
                // The window's in-memory profile ends with it, and so do its downloads.
                DownloadsModel.shared.endIncognitoSession(context: downloadContext)
            }
        }
        // Offset from the window in front so the two don't stack exactly. Read it
        // before showWindow, which makes the new window main.
        let front = NSApp.mainWindow ?? windowController.window
        // Test runs stay behind the user's windows.
        WindowPresenter.show(controller)
        if let front, front !== controller.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        if let url { controller.store.mutateWithoutUndo { _ = $0.openTab(url: url) } } else { controller.newTab(nil) }
        return controller
    }

    // MARK: AppleScript (AppleScript.swift)

    /// The browser windows AppleScript's `windows` lists, front to back.
    var scriptControllers: [BrowserWindowController] {
        guard let windowController else { return [] }
        let all = [windowController] + windows.all + incognitoControllers
        let onScreen = Set(NSApp.orderedWindows.map(ObjectIdentifier.init))
        return BrowserWindows.frontToBack(all).filter { $0.window.map { onScreen.contains(ObjectIdentifier($0)) } == true }
    }

    /// `make new window`: File › New Window, or New Incognito Window.
    func openScriptWindow(incognito: Bool) -> BrowserWindowController {
        incognito ? openIncognitoWindow() : windows.openNewWindow()
    }

    // MARK: Claude's window

    /// Once per normal window, when it's made: Claude's tools can move to any of them, so each reports its
    /// pages to automation and gets the banner, border and handoff card, the ⌘J bar and the Claude button,
    /// and hides instead of closing while Claude works in it. Incognito and Blank windows get none of it:
    /// the tools never work there.
    private func setUpForClaude(_ controller: BrowserWindowController) {
        guard let automation, let claudeTasks, let claudeCode, windows.isNormal(controller) else { return }
        controller.installAutomationBanner(automation)
        controller.claudeBubble.tasks = claudeTasks
        controller.claudeBubble.code = claudeCode
        controller.claudeButton.tasks = claudeTasks
        controller.claudeButton.open = { [weak self, weak controller] in
            guard let controller else { return }
            self?.claudeButtonClicked(in: controller)
        }
        controller.hidesInsteadOfClosing = { [weak automation, weak claudeTasks, weak claudeCode, weak controller] in
            guard let controller, automation?.host === controller else { return false }
            return claudeTasks?.isRunningAny == true || claudeCode?.isRunningAny == true
        }
    }

    /// The window Claude's tools work in, or the one they'd move to; `opening` one if none is left.
    private func claudeWindow(opening: WindowPresentation.Purpose? = nil) -> BrowserWindowController? {
        windows?.currentNormal(prefer: automation?.host as? BrowserWindowController, opening: opening)
    }

    /// Before a tool call that needs a window: the tools' window while it's open (the usual case, no
    /// lookup), else the frontmost normal window, else a new one behind the user's windows.
    private func ensureAutomationWindow() {
        guard let automation else { return }
        if let host = automation.host as? BrowserWindowController, !host.hasClosed, windows.isNormal(host) { return }
        if let next = claudeWindow(opening: .automation) { automation.attach(next) }
    }

    /// A normal window is closing, before its pages close. If it's the tools' window, they move to the frontmost
    /// normal window still open and take the pages Claude is using along, so those don't close and load again;
    /// with none left, they wait for the next tool call (which opens one) and those pages close with the window.
    private func normalWindowClosing(_ closing: BrowserWindowController) {
        guard !isTerminating, let automation, automation.host === closing, let next = claudeWindow() else { return }
        next.pool.takeOver(automation.tabsKeptLive, from: closing.pool)
        automation.attach(next)
    }

    var allowsJavaScriptFromAppleEvents: Bool { store?.state.allowsJavaScriptFromAppleEvents ?? false }

    /// View › Developer › Allow JavaScript from Apple Events (Arc's item, off by default).
    @objc func toggleJavaScriptFromAppleEvents(_ sender: Any?) {
        store.mutateWithoutUndo { $0.allowsJavaScriptFromAppleEvents.toggle() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The Dock icon brings back the window hidden while Claude tasks ran.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // The window hidden while Claude works, else the frontmost normal one, else a new one: never a closed one.
        if !hasVisibleWindows { WindowPresenter.show(windows?.currentNormal(opening: .user)?.window) }
        return true
    }

    /// Quitting has begun: nothing makes new pages (a close chain that the quit cut short).
    var isTerminating = false

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        claudeTasks?.stopAll()
        claudeTasks?.saveNow()
        claudeCode?.stopAll()
        windows?.applicationWillTerminate()
        saveSession()
        automation?.shutdown()
    }

    func saveSession() {
        // Before CEF closes the browsers (`willTerminate`): their history goes with them.
        for controller in allBrowserControllers where !controller.isIncognito { controller.pool.saveAllHistory() }
        Self.tabHistory.flush()
        store?.saveNow()
        history?.flush()
        DownloadsModel.shared.saveNow()
        BoostsModel.shared.flush()
    }

    /// The main window and every other one, once each.
    private var allBrowserControllers: [BrowserWindowController] {
        var all = windowController.map { [$0] } ?? []
        for controller in windows?.all ?? [] where !all.contains(where: { $0 === controller }) { all.append(controller) }
        return all
    }

    /// Tab history files of tabs closed for good, here or while Kite last ran.
    private func forgetClosedTabsHistory() {
        var kept = Set<UUID>()
        for controller in allBrowserControllers where !controller.isIncognito {
            let state = controller.store.state
            kept.formUnion(state.allTabIDs)
            kept.formUnion(state.recentlyClosed.map(\.tab.id))
        }
        Self.tabHistory.removeAll(except: kept)
    }

    /// Delete Browsing Data took history: no tab wakes or relaunches with its back/forward list.
    func forgetTabHistory() {
        for controller in allBrowserControllers { controller.pool.forgetSavedHistory() }
        Self.tabHistory.removeAll()
    }

    /// Kite → About Kite: AppKit's standard panel (WindowPresenter keeps a test-safe run's behind).
    @objc func showAbout(_ sender: Any?) { WindowPresenter.showAboutPanel() }

    // MARK: Settings

    /// Kite → Settings… (⌘,).
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// Chromium's Energy Saver (30fps on battery below 20%). On unless the user turns it off, as in Chrome.
    static let energySaverKey = "chromiumEnergySaver"
    static var energySaverSetting: Bool { UserDefaults.standard.object(forKey: energySaverKey) as? Bool ?? true }

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
        store.mutateWithoutUndo { $0.archiveAfter = intervals[sender.tag] }
        store.archiveStaleTabs()
    }

    // MARK: Quitting

    /// ⌘Q and Kite → Quit Kite. Only these ask first: quits from the Dock, scripts
    /// (scripts/install-app.sh) and logging out go straight to terminate.
    @objc func quitKite(_ sender: Any?) {
        guard let store, store.state.warnsBeforeQuitting else { return NSApp.terminate(sender) }
        // Nothing opens a window for itself while the user is asked (Claude's tools, a VPN sign-in).
        windows?.quitPending = true
        defer { windows?.quitPending = false }
        switch QuitDialog.run(over: NSApp.keyWindow ?? NSApp.mainWindow) {
        case .quit:
            NSApp.terminate(sender)
        case .quitAndDontAskAgain:
            store.mutateWithoutUndo { $0.warnsBeforeQuitting = false }
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
        windows?.quitPending = true
        guard QuitDialog.runDownloadsInProgress(over: NSApp.keyWindow ?? NSApp.mainWindow) else {
            windows?.quitPending = false
            return .terminateCancel
        }
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
        store.mutateWithoutUndo { $0.pageAppearance = appearance }
        applyPageAppearance()
    }

    private func applyPageAppearance() {
        NSApp.appearance = store.state.pageAppearance.appearanceName.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
    }

    /// Kite menu → Warn Before Quitting, until there's a Settings window (Arc has it in General).
    @objc func toggleQuitWarning(_ sender: Any?) {
        store.mutateWithoutUndo { $0.warnsBeforeQuitting.toggle() }
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
    private func claudeButtonClicked(in controller: BrowserWindowController) {
        guard !claudeTasks.isSetUp else { return controller.claudeBubble.toggle() }
        Task { @MainActor [weak controller] in
            if await claudeTasks.setUp() { controller?.claudeBubble.open() }
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
        if WindowPresenter.runModal(alert) == .alertSecondButtonReturn {
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
