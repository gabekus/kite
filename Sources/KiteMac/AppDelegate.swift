import AppKit
import KiteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Chosen in main.swift before the app finishes launching.
    var engine: WebEngine!

    private var store: BrowserStore!
    private var windowController: BrowserWindowController!
    private var archiveTimer: Timer?
    private var automation: AutomationController!

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

        automation = AutomationController(store: store, supportDirectory: Self.supportDirectory)
        automation.host = windowController
        windowController.installAutomationBanner(automation)
        automation.start()
        NSApp.activate(ignoringOtherApps: true)

        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.archiveStaleTabs(olderThan: Self.archiveAfter) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        automation?.shutdown()
    }

    func saveSession() {
        store?.saveNow()
    }

    // MARK: Claude

    @objc func toggleClaudeControl(_ sender: Any?) {
        let enable = !automation.isEnabled
        automation.setEnabled(enable)
        guard enable, automation.isEnabled else { return }
        let alert = NSAlert()
        alert.messageText = "Claude can now control Kite"
        alert.informativeText = """
            To connect Claude Code, run:

            \(automation.claudeCodeCommand)

            Kite asks you before Claude submits a form, sends, posts, pays, buys or deletes anything, and shows \
            when Claude is controlling a tab. Turn this off in the Kite menu at any time.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Command")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(automation.claudeCodeCommand, forType: .string)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleClaudeControl(_:)) {
            item.state = automation?.isEnabled == true ? .on : .off
            return automation != nil
        }
        return true
    }
}
