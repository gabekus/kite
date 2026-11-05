import AppKit
import KiteCore

/// Runs `SidebarTestHook` (`KITE_TEST_ICON_PICKER`, `KITE_TEST_NEW_SPACE` and its `_NAME` and `_THEME`) once, in the
/// main window, a second after it's up. Test-safe runs only: on a real profile `start` reads nothing and does nothing.
///
/// It goes through the paths a click takes, minus the click: the picker through `requestIconPicker` (the space menu's
/// Change Space Icon…), the page through `beginNewSpace` (+ › New Space), the name through the page's field binding
/// (`typedName`, read as the page appears) and the theme editor from Choose a Theme's own row (`opensThemeEditor`,
/// read as the row is laid out). Nothing is pressed, typed, activated or fronted. It writes `KITE_TEST_SIDEBAR: ready`
/// once the state is up (the popover shown), with whether Kite is active and where the popover went, or `failed` and
/// why. After that it keeps watching, and writes `changed` if the state goes or Kite becomes active.
@MainActor
enum SidebarTestHookRunner {
    /// The page's field takes this name as it appears (SpaceCreationView), for the draft it was set for.
    private static var pendingName: (space: UUID, name: String)?
    /// Choose a Theme's row opens the theme editor as it's laid out, for this draft.
    private static var pendingThemeEditor: UUID?
    private static let pollInterval: Double = 0.2

    static func start(in controller: BrowserWindowController,
                      environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard WindowPresenter.testSafe else { return }
        guard let hook = SidebarTestHook.from(environment: environment, testSafe: true) else {
            if let line = SidebarTestHook.refusedLine(environment) { log(line) }
            return
        }
        log(hook.armedLine)
        // Once the window and its sidebar have laid out (the capture script's own settle is longer).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak controller] in
            MainActor.assumeIsolated {
                guard let controller, controller.window != nil else {
                    return log(hook.failedLine("the main window went before the hook ran"))
                }
                run(hook, in: controller)
            }
        }
    }

    private static func run(_ hook: SidebarTestHook, in controller: BrowserWindowController) {
        let store = controller.store
        let main = controller.window
        switch hook {
        case .iconPicker(let name):
            guard let id = SidebarTestHook.space(named: name, in: store.state) else {
                return log(hook.failedLine("no one space has that name"))
            }
            store.requestIconPicker(space: id)
            watch(hook, main: main, until: Date().addingTimeInterval(SidebarTestHook.readyTimeout)) {
                SpaceIconPicker.current.map { .some($0) }
            }
        case .newSpace(let name, let preset):
            store.beginNewSpace()
            guard let draft = store.spaceCreation?.spaceID else { return log(hook.failedLine("New Space opened no page")) }
            if let name { pendingName = (draft, name) }
            if let preset, let current = store.state.spaces.first(where: { $0.id == draft })?.theme {
                // The swatch's pick (ThemeEditor.presets): the preset, the intensity kept, the colour chosen.
                store.mutate { $0.setTheme(SidebarTestHook.theme(current, picking: preset), forSpace: draft) }
                store.spaceThemeChosen()
                pendingThemeEditor = draft
            }
            watch(hook, main: main, until: Date().addingTimeInterval(SidebarTestHook.readyTimeout)) {
                // Up: the draft's page, its name taken, and the theme editor when there's a preset.
                guard store.spaceCreation?.spaceID == draft, pendingName == nil else { return nil }
                guard preset != nil else { return .some(nil) }
                return ThemeEditor.current.map { .some($0) }
            }
        }
    }

    /// The page's field's starting text, once, for `space`'s page (SpaceCreationView.onAppear).
    static func typedName(for space: UUID) -> String? {
        guard let pending = pendingName, pending.space == space else { return nil }
        pendingName = nil
        return pending.name
    }

    /// Whether Choose a Theme's row opens the theme editor for `space` now, once.
    static func opensThemeEditor(for space: UUID) -> Bool {
        guard pendingThemeEditor == space else { return false }
        pendingThemeEditor = nil
        return true
    }

    /// Polls `up` (nil: the state isn't up; `.some(popover)`: it is, with its popover if it has one) until it's up
    /// or the deadline passes, then writes the ready line, and keeps polling for as long as Kite runs: the first time
    /// the state goes or Kite is active, it writes the changed line and stops.
    private static func watch(_ hook: SidebarTestHook, main: NSWindow?, until deadline: Date,
                              _ up: @escaping @MainActor () -> NSPopover??) {
        if let popover = up() {
            let shown = SidebarTestHook.Shown(appActive: NSApp.isActive, popover: popover.map { facts($0, main: main) })
            log(hook.readyLine(shown))
            return stayUp(hook, up)
        }
        guard Date() < deadline else { return log(hook.failedLine("not up in \(Int(SidebarTestHook.readyTimeout)) s")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            MainActor.assumeIsolated { watch(hook, main: main, until: deadline, up) }
        }
    }

    private static func stayUp(_ hook: SidebarTestHook, _ up: @escaping @MainActor () -> NSPopover??) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            MainActor.assumeIsolated {
                if NSApp.isActive { return log(hook.changedLine("Kite is the active app")) }
                if up() == nil { return log(hook.changedLine("the state went (a popover closed or the page ended)")) }
                stayUp(hook, up)
            }
        }
    }

    /// Where a popover went: its window, key or not, its level, and whether its parent is the main window.
    private static func facts(_ popover: NSPopover, main: NSWindow?) -> SidebarTestHook.Shown.Popover {
        let window = popover.contentViewController?.view.window
        return .init(key: window?.isKeyWindow ?? false, level: window.map { Int($0.level.rawValue) } ?? 0,
                     parentIsMainWindow: main != nil && window?.parent === main)
    }

    /// One `KITE_TEST_SIDEBAR:` line on stderr, which the capture script waits for and lists in NOTES.md.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
