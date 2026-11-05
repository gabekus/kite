import AppKit
import KiteCore

/// Runs `SidebarTestHook` (`KITE_TEST_ICON_PICKER`, `KITE_TEST_NEW_SPACE` and its `_NAME` and `_THEME`) once, in the
/// main window, a second after it's up. Test-safe runs only: on a real profile `start` reads nothing and does nothing.
///
/// It goes through the paths a click takes, minus the click: the picker through `requestIconPicker` (the space menu's
/// Change Space Icon…), the page through `beginNewSpace` (+ › New Space), the name through the page's field binding
/// (`typedName`, read as the page appears) and the theme editor from Choose a Theme's own row (`opensThemeEditor`,
/// read as the row is laid out). Nothing is pressed, typed, activated or fronted. It writes `KITE_TEST_SIDEBAR: ready`
/// once the state is up (the popover shown), or `failed` and why.
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
                guard let controller else { return }
                run(hook, in: controller)
            }
        }
    }

    private static func run(_ hook: SidebarTestHook, in controller: BrowserWindowController) {
        let store = controller.store
        switch hook {
        case .iconPicker(let name):
            guard let id = SidebarTestHook.space(named: name, in: store.state) else {
                return log(hook.failedLine("no one space has that name"))
            }
            store.requestIconPicker(space: id)
            waitFor(hook, until: Date().addingTimeInterval(SidebarTestHook.readyTimeout)) { SpaceIconPicker.isShown }
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
            waitFor(hook, until: Date().addingTimeInterval(SidebarTestHook.readyTimeout)) {
                store.spaceCreation?.spaceID == draft && pendingName == nil && (preset == nil || ThemeEditor.isShown)
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

    private static func waitFor(_ hook: SidebarTestHook, until deadline: Date, _ ready: @escaping @MainActor () -> Bool) {
        if ready() { return log(hook.readyLine) }
        guard Date() < deadline else { return log(hook.failedLine("not up in \(Int(SidebarTestHook.readyTimeout)) s")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            MainActor.assumeIsolated { waitFor(hook, until: deadline, ready) }
        }
    }

    /// One `KITE_TEST_SIDEBAR:` line on stderr, which the capture script waits for and lists in NOTES.md.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
