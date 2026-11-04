import AppKit
import KiteCore

/// The one way Kite shows a window or panel, activates itself, or runs a modal (WindowPresentation decides).
///
/// On a test-safe run (`KITE_DIAGNOSTICS=1` on a `KITE_SUPPORT_PATH` profile) nothing comes to the front, becomes key
/// or activates Kite: windows go behind the other apps' at normal level, where `kite ui` still reads and drives them,
/// and modals are skipped with a `KITE_TEST_MODAL:` line on stderr. A real profile behaves as before.
@MainActor
enum WindowPresenter {
    static var testSafe: Bool { UIDiagnostics.enabledByEnvironment }

    /// makeKeyAndOrderFront, plus NSApp.activate when `activate`.
    static func show(_ window: NSWindow?, activate: Bool = false) {
        guard let window else { return }
        apply(.decide(testSafe: testSafe, key: true, activate: activate, level: window.level.rawValue,
                      hasParent: window.parent != nil), to: window)
    }

    /// The controller's showWindow, plus NSApp.activate when `activate`.
    static func show(_ controller: NSWindowController, activate: Bool = false) {
        guard testSafe else {
            controller.showWindow(nil)
            if activate { activateApp() }
            return
        }
        show(controller.window)
    }

    /// orderFront, without making the window key.
    static func orderFront(_ window: NSWindow?) {
        guard let window else { return }
        apply(.decide(testSafe: testSafe, key: false, level: window.level.rawValue, hasParent: window.parent != nil),
              to: window)
    }

    static func activateApp() {
        if testSafe { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func apply(_ presentation: WindowPresentation, to window: NSWindow) {
        if let level = presentation.level {
            (window as? NSPanel)?.isFloatingPanel = false
            window.level = NSWindow.Level(rawValue: level)
        }
        switch presentation.order {
        case .keyAndFront: window.makeKeyAndOrderFront(nil)
        case .front: window.orderFront(nil)
        case .aboveParent:
            if let parent = window.parent { window.order(.above, relativeTo: parent.windowNumber) } else { window.orderBack(nil) }
        case .behind: window.orderBack(nil)
        }
        if presentation.activates { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Modals

    /// NSAlert's runModal. A test-safe run logs the alert and answers `.abort`, which no caller treats as a button.
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !WindowPresentation.runsModals(testSafe: testSafe) else { return alert.runModal() }
        let buttons = alert.buttons.map(\.title).joined(separator: ", ")
        logSkipped("alert: \(alert.messageText) | \(alert.informativeText) | [\(buttons)]")
        return .abort
    }

    /// An open or save panel's runModal. A test-safe run logs it and answers `.cancel`.
    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard !WindowPresentation.runsModals(testSafe: testSafe) else { return panel.runModal() }
        logSkipped("\(panel is NSOpenPanel ? "open" : "save") panel: \(panel.message)")
        return .cancel
    }

    /// Logs a modal a test-safe run didn't show.
    static func logSkipped(_ description: String) {
        FileHandle.standardError.write(Data("KITE_TEST_MODAL: \(description)\n".utf8))
    }

    // MARK: About

    private static weak var aboutPanel: NSWindow?

    /// Kite › About Kite: AppKit's standard About panel. AppKit makes the panel and orders it front in one call, so a
    /// test-safe run moves it to the back (normal level, not key) in the same main-thread turn, before it draws;
    /// later opens reorder the same panel without asking AppKit again.
    static func showAboutPanel() {
        guard testSafe else { return NSApp.orderFrontStandardAboutPanel(nil) }
        if let aboutPanel { return show(aboutPanel) }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        guard let panel = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible }) else { return }
        aboutPanel = panel
        show(panel)
    }
}
