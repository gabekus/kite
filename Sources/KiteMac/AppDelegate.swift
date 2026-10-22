import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Chosen in main.swift before the app finishes launching.
    var engine: WebEngine!

    private var store: BrowserStore!
    private var windowController: BrowserWindowController!
    private var archiveTimer: Timer?

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
        NSApp.mainMenu = MainMenu.build(target: windowController)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs(olderThan: Self.archiveAfter) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
    }

    func saveSession() {
        store?.saveNow()
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleEnergySaver(_:)) else { return true }
        #if canImport(CEFBridge)
        item.state = KCRuntime.energySaverEnabled ? .on : .off
        return KCRuntime.isInitialized
        #else
        return false
        #endif
    }
}
