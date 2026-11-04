import AppKit
import KiteCore

/// The one way Kite shows a window or panel, activates itself, runs a modal, or hands something to another app
/// (WindowPresentation decides; WindowPresenterGuardTests fails on a direct call anywhere else).
///
/// On a test-safe run (`KITE_DIAGNOSTICS=1` on a `KITE_SUPPORT_PATH` profile) nothing comes to the front, becomes key
/// or activates Kite or another app: windows go at normal level just above Kite's frontmost window, behind the other
/// apps', where `kite ui` still reads and drives them. Modals and app launches are skipped with a `KITE_TEST_MODAL:`
/// line on stderr. A real profile behaves as before.
@MainActor
enum WindowPresenter {
    nonisolated static let testSafe = WindowPresentation.isTestSafe(environment: ProcessInfo.processInfo.environment)

    /// makeKeyAndOrderFront, plus NSApp.activate when `activate`.
    static func show(_ window: NSWindow?, activate: Bool = false) {
        guard let window else { return }
        apply(decide(for: window, key: true, activate: activate), to: window)
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

    /// orderFront, without making the window key. `anchor` is the window a popover hangs from when it has no parent.
    static func orderFront(_ window: NSWindow?, anchor: NSWindow? = nil) {
        guard let window else { return }
        apply(decide(for: window, key: false, anchor: anchor), to: window, anchor: anchor)
    }

    /// makeKey on a child panel that's already ordered with its parent (Little Kite's Open In menu): a test-safe run
    /// only makes it key, which can't take the keyboard from another app while Kite isn't active.
    static func makeKey(childPanel panel: NSWindow) {
        if testSafe { panel.makeKey() } else { panel.makeKeyAndOrderFront(nil) }
    }

    /// A window Kite opens for itself (Claude's): in below the key window, never key or main, on any profile.
    static func showInBackground(_ window: NSWindow?) {
        guard let window else { return }
        apply(.background(testSafe: testSafe, level: window.level.rawValue), to: window)
    }

    static func activateApp() {
        if testSafe { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A dock bounce. A test-safe run doesn't ask for attention.
    static func requestAttention() {
        guard !testSafe else { return logSkipped("dock attention request") }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static func decide(for window: NSWindow, key: Bool, activate: Bool = false, anchor: NSWindow? = nil) -> WindowPresentation {
        .decide(testSafe: testSafe, key: key, activate: activate, level: window.level.rawValue,
                hasParent: (window.parent ?? anchor) != nil, isVisible: window.isVisible,
                kiteHasFrontWindow: kiteFrontWindow(excluding: window) != nil)
    }

    /// Kite's frontmost visible normal-level window other than `window`.
    private static func kiteFrontWindow(excluding window: NSWindow) -> NSWindow? {
        guard testSafe else { return nil }
        return NSApp.orderedWindows.first { $0 !== window && $0.isVisible && $0.level == .normal && $0.parent == nil }
    }

    private static func apply(_ presentation: WindowPresentation, to window: NSWindow, anchor: NSWindow? = nil) {
        if let level = presentation.level {
            (window as? NSPanel)?.isFloatingPanel = false
            window.level = NSWindow.Level(rawValue: level)
        }
        switch presentation.order {
        case .keyAndFront: window.makeKeyAndOrderFront(nil)
        case .front: window.orderFront(nil)
        case .aboveParent:
            if let parent = window.parent ?? anchor { window.order(.above, relativeTo: parent.windowNumber) } else { window.orderBack(nil) }
        case .aboveKite:
            if let front = kiteFrontWindow(excluding: window) { window.order(.above, relativeTo: front.windowNumber) }
        case .keep: break
        case .behind: window.orderBack(nil)
        case .belowKey:
            if let key = NSApp.keyWindow, key !== window { window.order(.below, relativeTo: key.windowNumber) } else { window.orderBack(nil) }
        }
        if presentation.activates { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Levels

    /// The level each window asked for (Stay On Top, the Essential Keyboard Shortcuts window), kept on a test-safe
    /// run where the window itself stays at normal level.
    private static let requestedLevels = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

    /// Sets a window's level. A test-safe run keeps the window at normal level and remembers the level it asked for.
    static func setLevel(_ level: NSWindow.Level, of window: NSWindow) {
        requestedLevels.setObject(NSNumber(value: level.rawValue), forKey: window)
        guard !testSafe || level.rawValue <= WindowPresentation.normalLevel else { return }
        window.level = level
    }

    /// The level the window asked for, which a test-safe run doesn't apply.
    static func level(of window: NSWindow) -> NSWindow.Level {
        requestedLevels.object(forKey: window).map { NSWindow.Level(rawValue: $0.intValue) } ?? window.level
    }

    // MARK: Modals

    /// NSAlert's runModal. A test-safe run logs the alert and answers `.abort`, which no caller treats as a button.
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !WindowPresentation.runsModals(testSafe: testSafe) else { return alert.runModal() }
        let buttons = alert.buttons.map(\.title).joined(separator: ", ")
        logSkipped("alert: \(alert.messageText) | \(alert.informativeText) | [\(buttons)]")
        return SkippedModal.alert.proceeds ? .alertFirstButtonReturn : .abort
    }

    /// An open or save panel's runModal. A test-safe run logs it and answers `.cancel`.
    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard !WindowPresentation.runsModals(testSafe: testSafe) else { return panel.runModal() }
        logSkipped("\(panel is NSOpenPanel ? "open" : "save") panel: \(panel.message)")
        return SkippedModal.openOrSavePanel.proceeds ? .OK : .cancel
    }

    /// An open or save panel's modeless begin. A test-safe run logs it and completes with `.cancel`.
    static func begin(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard !WindowPresentation.runsModals(testSafe: testSafe) else {
            return panel.begin { response in MainActor.assumeIsolated { completion(response) } }
        }
        completion(runModal(panel))
    }

    /// A window of Kite's own run as an app-modal session (the quit dialogs). Never on a test-safe run: those
    /// callers answer `SkippedModal` first.
    static func runModal(window: NSWindow) {
        guard !testSafe else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    /// NSApp.presentError with no window to put a sheet on.
    static func presentError(_ error: Error) {
        _ = runModal(NSAlert(error: error))
    }

    /// Logs a modal or app launch a test-safe run didn't show.
    nonisolated static func logSkipped(_ description: String) {
        FileHandle.standardError.write(Data("KITE_TEST_MODAL: \(description)\n".utf8))
    }

    // MARK: Other apps

    /// NSWorkspace's open: another app comes to the front. A test-safe run logs the URL's scheme (or "file") and
    /// returns false.
    @discardableResult
    nonisolated static func open(_ url: URL) -> Bool {
        guard !testSafe else {
            logSkipped("open \(url.isFileURL ? "file \(url.lastPathComponent)" : "\(url.scheme ?? "?"): URL")")
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// NSWorkspace's open with a given app.
    nonisolated static func open(_ urls: [URL], withApplicationAt app: URL) {
        guard !testSafe else { return logSkipped("open \(urls.count) file(s) in \(app.lastPathComponent)") }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// NSWorkspace's openApplication.
    nonisolated static func openApplication(at app: URL) {
        guard !testSafe else { return logSkipped("launch \(app.lastPathComponent)") }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Show in Finder, which brings Finder to the front.
    nonisolated static func revealInFinder(_ urls: [URL]) {
        guard !testSafe else { return logSkipped("reveal \(urls.count) item(s) in Finder") }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: About

    private static weak var aboutPanel: NSWindow?

    /// Kite › About Kite: AppKit's standard About panel. AppKit makes the panel and orders it front in one call, so a
    /// test-safe run moves it behind (normal level, not key) in the same main-thread turn, before it draws; later
    /// opens reorder the same panel without asking AppKit again.
    static func showAboutPanel() {
        guard testSafe else { return NSApp.orderFrontStandardAboutPanel(nil) }
        if let aboutPanel { return show(aboutPanel) }
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        let visible = NSApp.orderedWindows.filter(\.isVisible) + NSApp.windows.filter { $0.isVisible && !NSApp.orderedWindows.contains($0) }
        let byID = Dictionary(visible.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        let appeared = visible.map(ObjectIdentifier.init).filter { !before.contains($0) }
        let classMatches = visible.filter(isAboutPanel).map(ObjectIdentifier.init)
        switch AboutPanelLookup.decide(appeared: appeared, classMatches: classMatches) {
        case .found(let id):
            guard let panel = byID[id] else { return }
            aboutPanel = panel
            // AppKit has just put it in front: above Kite's front window, or at the back when Kite shows nothing else.
            if kiteFrontWindow(excluding: panel) == nil { panel.orderBack(nil) } else { show(panel) }
        case .orderBehind(let ids):
            logSkipped("About panel not identified; sent \(ids.count) new window(s) to the back")
            for id in ids { byID[id]?.orderBack(nil) }
        }
    }

    /// AppKit's About panel, by its private classes (the panel's, its controller's or its delegate's).
    private static func isAboutPanel(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let objects: [AnyObject?] = [window, window.windowController, window.delegate, window.contentViewController]
        return objects.contains { $0.map { NSStringFromClass(type(of: $0)).contains("About") } ?? false }
    }
}
