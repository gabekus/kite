import AppKit
import KiteCore

/// The browser windows beyond the first: File › New Window (⌘N) and Blank Window (⌃⌘N), as in Arc.
///
/// Arc's windows come in kinds (`bigBrowserWindow`, `standaloneBrowserWindow`,
/// `bigIncognitoBrowserWindow`, `littleBrowserWindow`) with sidebar contexts `global`,
/// `standalone` and `incognito`. A new window uses the global sidebar: the same spaces, pinned
/// tabs, favourites and tabs as every normal window, with its own space and tab selected. A blank
/// window gets a standalone sidebar of its own ("Explore" tabs). Both come back on relaunch while
/// "When opening Kite, restore windows from previous session" is on, as in Arc.
@MainActor
final class BrowserWindows {
    private let main: BrowserStore
    private let mainController: BrowserWindowController
    private let engine: WebEngine
    private let adblocker: Adblocker
    private let history: HistoryStore
    /// Each normal or Blank window as it's made (the main one excepted).
    var didMakeController: ((BrowserWindowController) -> Void)?
    /// A normal window is closing (the main one too), before its pages close: what followed it moves to
    /// `currentNormal` and can take the pages it's using along (`PagePool.takeOver`).
    var normalWindowClosing: ((BrowserWindowController) -> Void)?
    /// A quit is being asked about or under way: nothing opens a window for itself meanwhile.
    var quitPending = false
    private let fileURL: URL
    let link = WindowLink()
    /// The normal windows' pages: a tab selected in two of them has one page, shown in the window
    /// that put it on screen last, and a placeholder in the other.
    let sharedPages = SharedPages()
    private(set) var controllers: [BrowserWindowController] = []
    private var kinds: [ObjectIdentifier: SavedWindow.Kind] = [:]
    /// Each window's will-close observer, removed when it fires.
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var saveTask: Task<Void, Never>?
    /// The kind of change the waiting save is for; nil when none is waiting.
    private var pendingSave = PendingSave()
    /// While the app quits, windows closing don't drop out of the saved list.
    private var isTerminating = false
    /// windows.json couldn't be read or kept aside: saving would overwrite (or delete) the only copy.
    private var savesBlocked = false

    typealias SavedWindow = SavedWindows.Window

    init(main: BrowserStore, mainController: BrowserWindowController, engine: WebEngine, adblocker: Adblocker,
         history: HistoryStore, fileURL: URL) {
        self.main = main
        self.mainController = mainController
        self.engine = engine
        self.adblocker = adblocker
        self.history = history
        self.fileURL = fileURL
        link.add(main)
        mainController.pool.join(sharedPages)
        mainController.willClose = { [weak self] controller in self?.normalWindowClosing?(controller) }
    }

    /// ⌘N: a normal window on the front window's space, with the command bar open for its first page,
    /// or showing `url` (the page menu's Open Link in New Window).
    @discardableResult
    func openNewWindow(url: URL? = nil) -> BrowserWindowController {
        let front = frontStore()
        let state = (front ?? main).state.newWindowState(on: (front ?? main).state.selectedSpaceID)
        let controller = makeNormal(state, frame: nil)
        if let url { controller.store.mutateWithoutUndo { _ = $0.openTab(url: url) } } else { controller.newTab(nil) }
        return controller
    }

    /// The normal window to work in for something that has no window of its own (Claude's tools, links from
    /// other apps, the Dock icon, pages web apps and Little Kite hand over): `prefer` while it's open, else the
    /// frontmost open normal window. With none, `opening` makes one for that purpose (never while quitting);
    /// nil otherwise. `visibleOnly` skips a window hidden while Claude works in it.
    func currentNormal(prefer: BrowserWindowController? = nil, visibleOnly: Bool = false,
                       opening: WindowPresentation.Purpose? = nil) -> BrowserWindowController? {
        let normal = Self.frontToBack(normalControllers)
        let candidates = normal.map {
            AutomationWindowChoice.Window(id: ObjectIdentifier($0), isNormal: true, isOpen: !$0.hasClosed,
                                          isVisible: $0.window?.isVisible == true || $0.window?.isMiniaturized == true)
        }
        let preferred = prefer.flatMap { p in normal.contains { $0 === p } ? ObjectIdentifier(p) : nil }
        switch AutomationWindowChoice.pick(current: preferred, windows: candidates, visibleOnly: visibleOnly) {
        case .keep:
            return prefer
        case .use(let id):
            return normal.first { ObjectIdentifier($0) == id }
        case .openNew:
            guard let opening, !isTerminating, !quitPending else { return nil }
            return makeNormal(main.state.newWindowState(on: main.state.selectedSpaceID), frame: nil, purpose: opening)
        }
    }

    /// The main window and the ⌘N windows (not Blank, incognito or Little Kite), in the order they were made.
    private var normalControllers: [BrowserWindowController] {
        [mainController] + controllers.filter { kinds[ObjectIdentifier($0)] == .normal }
    }

    /// The main window or a ⌘N window: one Claude's tools can work in.
    func isNormal(_ controller: BrowserWindowController) -> Bool {
        controller === mainController || (controllers.contains { $0 === controller } && kinds[ObjectIdentifier(controller)] == .normal)
    }

    /// `controllers` front to back: those on screen by their order there, then the rest (hidden while Claude
    /// works) in the order given.
    static func frontToBack(_ controllers: [BrowserWindowController]) -> [BrowserWindowController] {
        let screen = NSApp.orderedWindows.compactMap { window in controllers.firstIndex { $0.window === window } }
        return AutomationWindowChoice.frontToBack(Array(controllers.indices), screenOrder: screen).map { controllers[$0] }
    }

    /// ⌃⌘N: a window with its own sidebar, outside the spaces, opening on the command bar.
    func openBlankWindow() {
        let controller = makeBlank(nil, frame: nil)
        controller.newTab(nil)
    }

    /// Reopens the windows saved at the last quit, when Settings › Advanced › "When opening Kite,
    /// restore windows from previous session" is on. Off, Kite opens with its main window only, as
    /// Arc opens one window (the sidebar's spaces and tabs come back either way).
    func restore() {
        guard WindowRestore.isEnabled() else { return }
        // Window by window: one that doesn't decode is dropped alone, and the file is kept aside first.
        let loaded = SavedWindows.load(from: fileURL)
        if loaded.stuck {
            savesBlocked = true
            NSLog("Kite: windows.json can't be read or kept aside; not saving windows this run")
        }
        guard let file = loaded.file else { return }
        if file.dropped > 0 { NSLog("Kite: left out \(file.dropped) unreadable window(s) from windows.json; a copy is kept beside it") }
        for saved in file.windows {
            let frame = saved.frame.count == 4 ? NSRect(x: saved.frame[0], y: saved.frame[1], width: saved.frame[2], height: saved.frame[3]) : nil
            switch saved.kind {
            case .normal:
                var state = main.state
                if let selection = saved.selection { state.select(selection) }
                _ = makeNormal(state, frame: frame)
            case .blank:
                _ = makeBlank(saved.state, frame: frame)
            }
        }
        // Behind the main window: it was the one in front when the app started. A diagnostics
        // run keeps every window behind the user's.
        WindowPresenter.show(mainController.window)
    }

    /// The extra windows' controllers, for code that looks a window up (extension dialogs).
    var all: [BrowserWindowController] { controllers }

    func applicationWillTerminate() {
        isTerminating = true
        saveNow()
    }

    // MARK: Private

    /// The key (or main) window if it's a normal one, else the frontmost normal window.
    private func frontStore() -> BrowserStore? {
        let front = NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
        return currentNormal(prefer: front)?.store
    }

    private func makeNormal(_ state: BrowserState, frame: NSRect?, purpose: WindowPresentation.Purpose = .user) -> BrowserWindowController {
        let store = BrowserStore.linked(state, to: link)
        return show(store, kind: .normal, frame: frame, sharedPages: sharedPages, purpose: purpose)
    }

    private func makeBlank(_ state: BrowserState?, frame: NSRect?) -> BrowserWindowController {
        show(.blank(state), kind: .blank, frame: frame, sharedPages: nil)
    }

    private func show(_ store: BrowserStore, kind: SavedWindow.Kind, frame: NSRect?, sharedPages: SharedPages?,
                      purpose: WindowPresentation.Purpose = .user) -> BrowserWindowController {
        store.historyRoot = history
        store.didChangeState = { [weak self] delay in self?.scheduleSave(delay) }
        let controller = BrowserWindowController(store: store, engine: engine, adblocker: adblocker, autosaveName: nil,
                                                 sharedPages: sharedPages)
        controllers.append(controller)
        let key = ObjectIdentifier(controller)
        kinds[key] = kind
        if kind == .normal { controller.willClose = { [weak self] controller in self?.normalWindowClosing?(controller) } }
        didMakeController?(controller)
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.closeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(token) }
                guard let controller, !self.isTerminating else { return }
                self.controllers.removeAll { $0 === controller }
                self.kinds[ObjectIdentifier(controller)] = nil
                self.link.remove(controller.store)
                self.saveNow()
            }
        }
        // Offset from the window in front so the two don't stack exactly. Read it before
        // showWindow, which makes the new window main.
        let front = NSApp.mainWindow ?? mainController.window
        // A window Kite opens for itself (Claude's) goes in behind the key window and never becomes key or main.
        if purpose == .automation { WindowPresenter.showInBackground(controller.window) } else { WindowPresenter.show(controller) }
        if let frame {
            controller.window?.setFrame(frame, display: false)
        } else if let front, front !== controller.window {
            controller.window?.setFrame(front.frame, display: false)
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        scheduleSave()
        return controller
    }

    /// Debounced like the session (SessionSaveDelay): a page's ticking title doesn't keep pushing it back.
    private func scheduleSave(_ delay: SessionSaveDelay = .soon) {
        guard let seconds = pendingSave.arm(delay) else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        pendingSave.saved()
        guard !savesBlocked else { return }
        let windows = controllers.compactMap { controller -> SavedWindow? in
            guard let kind = kinds[ObjectIdentifier(controller)], let window = controller.window else { return nil }
            let f = window.frame
            return SavedWindow(
                kind: kind,
                frame: [f.minX, f.minY, f.width, f.height],
                selection: kind == .normal ? controller.store.state.selection : nil,
                state: kind == .blank ? controller.store.state : nil
            )
        }
        do {
            if windows.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let data = try JSONEncoder().encode(SavedWindows(windows: windows))
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("Kite: couldn't save windows: \(error)")
        }
    }
}
