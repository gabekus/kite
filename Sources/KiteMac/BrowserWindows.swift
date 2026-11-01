import AppKit
import KiteCore

/// The browser windows beyond the first: File › New Window (⌘N) and Blank Window (⌃⌘N), as in Arc.
///
/// Arc's windows come in kinds (`bigBrowserWindow`, `standaloneBrowserWindow`,
/// `bigIncognitoBrowserWindow`, `littleBrowserWindow`) with sidebar contexts `global`,
/// `standalone` and `incognito`. A new window uses the global sidebar: the same spaces, pinned
/// tabs, favourites and tabs as every normal window, with its own space and tab selected. A blank
/// window gets a standalone sidebar of its own ("Explore" tabs). Both come back on relaunch, as
/// Arc restores windows ("When opening Arc, restore windows from previous session").
@MainActor
final class BrowserWindows {
    private let main: BrowserStore
    private let mainController: BrowserWindowController
    private let engine: WebEngine
    private let adblocker: Adblocker
    private let history: HistoryStore
    private let fileURL: URL
    let link = WindowLink()
    private(set) var controllers: [BrowserWindowController] = []
    private var kinds: [ObjectIdentifier: SavedWindow.Kind] = [:]
    private var saveTask: Task<Void, Never>?
    /// While the app quits, windows closing don't drop out of the saved list.
    private var isTerminating = false

    struct SavedWindow: Codable {
        enum Kind: String, Codable { case normal, blank }
        var kind: Kind
        /// x, y, width, height in screen points.
        var frame: [Double]
        /// A normal window's selection in the shared sidebar.
        var selection: WindowSelection?
        /// A blank window's own tabs.
        var state: BrowserState?
    }

    private struct File: Codable {
        var version = 1
        var windows: [SavedWindow]
    }

    init(main: BrowserStore, mainController: BrowserWindowController, engine: WebEngine, adblocker: Adblocker,
         history: HistoryStore, fileURL: URL) {
        self.main = main
        self.mainController = mainController
        self.engine = engine
        self.adblocker = adblocker
        self.history = history
        self.fileURL = fileURL
        link.add(main)
    }

    /// ⌘N: a normal window on the front window's space, with the command bar open for its first page,
    /// or showing `url` (the page menu's Open Link in New Window).
    @discardableResult
    func openNewWindow(url: URL? = nil) -> BrowserWindowController {
        let front = frontStore()
        let state = (front ?? main).state.newWindowState(on: (front ?? main).state.selectedSpaceID)
        let controller = makeNormal(state, frame: nil)
        if let url { controller.store.mutate { _ = $0.openTab(url: url) } } else { controller.newTab(nil) }
        return controller
    }

    /// ⌃⌘N: a window with its own sidebar, outside the spaces, opening on the command bar.
    func openBlankWindow() {
        let controller = makeBlank(nil, frame: nil)
        controller.newTab(nil)
    }

    /// Reopens the windows saved at the last quit.
    func restore() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
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
        if !UIDiagnostics.enabledByEnvironment { mainController.window?.makeKeyAndOrderFront(nil) }
    }

    /// The extra windows' controllers, for code that looks a window up (extension dialogs).
    var all: [BrowserWindowController] { controllers }

    func applicationWillTerminate() {
        isTerminating = true
        saveNow()
    }

    // MARK: Private

    private func frontStore() -> BrowserStore? {
        let front = NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
        guard let front, !front.isIncognito, kinds[ObjectIdentifier(front)] != .blank else { return nil }
        return front.store
    }

    private func makeNormal(_ state: BrowserState, frame: NSRect?) -> BrowserWindowController {
        let store = BrowserStore.linked(state, to: link)
        return show(store, kind: .normal, frame: frame)
    }

    private func makeBlank(_ state: BrowserState?, frame: NSRect?) -> BrowserWindowController {
        show(.blank(state), kind: .blank, frame: frame)
    }

    private func show(_ store: BrowserStore, kind: SavedWindow.Kind, frame: NSRect?) -> BrowserWindowController {
        store.history = history
        store.didChangeState = { [weak self] in self?.scheduleSave() }
        let controller = BrowserWindowController(store: store, engine: engine, adblocker: adblocker, autosaveName: nil)
        controllers.append(controller)
        kinds[ObjectIdentifier(controller)] = kind
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let controller, !self.isTerminating else { return }
                self.controllers.removeAll { $0 === controller }
                self.kinds[ObjectIdentifier(controller)] = nil
                self.link.remove(controller.store)
                self.saveNow()
            }
        }
        // Offset from the window in front so the two don't stack exactly. Read it before
        // showWindow, which makes the new window main.
        let front = NSApp.mainWindow ?? mainController.window
        controller.showWindow(nil)
        if let frame {
            controller.window?.setFrame(frame, display: false)
        } else if let front, front !== controller.window {
            controller.window?.setFrame(front.frame, display: false)
            controller.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        if UIDiagnostics.enabledByEnvironment { controller.window?.orderBack(nil) }
        scheduleSave()
        return controller
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
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
                let data = try JSONEncoder().encode(File(windows: windows))
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("Kite: couldn't save windows: \(error)")
        }
    }
}
