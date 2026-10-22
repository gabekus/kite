import AppKit
import KiteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Chosen in main.swift before the app finishes launching.
    var engine: WebEngine!

    private var store: BrowserStore!
    private var windowController: BrowserWindowController!
    private var incognitoControllers: [BrowserWindowController] = []
    /// Routes menu commands to whichever browser window is in front.
    private var menuRouter: MenuRouter!
    private var archiveTimer: Timer?
    /// Links opened before launch finished (Kite as the default browser).
    private var pendingURLs: [URL] = []

    /// Unpinned tabs idle this long get archived, like Arc's default.
    private static let archiveAfter: TimeInterval = 12 * 60 * 60

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kite", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = BrowserStore(session: SessionStore(fileURL: Self.supportDirectory.appendingPathComponent("session.json")))
        store.archiveStaleTabs(olderThan: Self.archiveAfter)

        windowController = BrowserWindowController(store: store, engine: engine)
        menuRouter = MenuRouter(fallback: windowController)
        NSApp.mainMenu = MainMenu.build(target: menuRouter)
        // Registered after the menu bar is set so AppKit adds Help search and the window list.
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        open(pendingURLs)
        pendingURLs = []

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs(olderThan: Self.archiveAfter) }
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
        let controller = BrowserWindowController(store: .incognito(), engine: engine.makeEphemeral(), incognito: true)
        incognitoControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated { self?.incognitoControllers.removeAll { $0 === controller } }
        }
        controller.showWindow(nil)
        // Offset from the window in front so the two don't stack exactly (after showWindow, which centers).
        if let front = NSApp.mainWindow ?? windowController.window, front !== controller.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        controller.newTab(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
    }

    func saveSession() {
        store?.saveNow()
    }
}
