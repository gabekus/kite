import AppKit
import KiteCore
import SwiftUI

/// Arc's tab switcher over one browser window: Tabs › Tab Switcher (forward) ⌃Tab and (backward) ⌃⇧Tab.
/// While ⌃ is held each press moves the highlight deeper through the recent tabs; letting go switches to
/// it. Esc closes without switching, ← → move, W closes the highlighted tab, and a click picks one. The
/// overlay shows 0.1 s after the first press (Arc's `presentationTimer`), so a quick ⌃Tab only goes back.
///
/// Keys reach it through `BrowserWindow.keyInterceptor` (sendEvent and performKeyEquivalent), where both
/// real keys and `ui input`'s synthetic ones pass; NSEvent local monitors never see the synthetic ones.
@MainActor
final class RecentTabSwitcherController {
    private unowned let owner: BrowserWindowController
    private(set) var switcher: RecentTabSwitcher?
    /// The modifiers of both switcher shortcuts: letting go of all of them commits (Arc's `eventMonitor`).
    private var holdMask: NSEvent.ModifierFlags = []
    private var presentationTimer: Timer?
    private var host: NSHostingView<RecentTabSwitcherView>?
    private let model = RecentTabSwitcherModel()
    /// Each tab's page as it last looked on screen, for the switcher's cards.
    private var snapshots: [UUID: NSImage] = [:]
    private var snapshotWork: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?

    init(owner: BrowserWindowController) {
        self.owner = owner
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Arc's `appDidResignActive`: the switcher closes without switching.
            MainActor.assumeIsolated { self?.dismiss(commit: false) }
        }
    }

    var isActive: Bool { switcher != nil }
    var isPresented: Bool { host != nil }

    // MARK: Commands

    /// ⌃Tab (forward) or ⌃⇧Tab (backward).
    func cycle(forward: Bool) {
        if switcher != nil {
            switcher?.cycle(forward: forward)
            updateView()
            return
        }
        guard let started = RecentTabSwitcher(state: owner.store.state, forward: forward) else { return }
        holdMask = Self.shortcutModifiers()
        // Held: the hardware state for real keys, the last modifier change the window saw for synthetic ones.
        let held = NSEvent.modifierFlags.union((owner.window as? BrowserWindow)?.heldModifiers ?? [])
        guard !holdMask.isEmpty, !held.isDisjoint(with: holdMask) else {
            // Nothing held (the menu bar, the command bar, a tap too short to see): just switch.
            select(started.focusedID)
            return
        }
        switcher = started
        captureShownPage()
        presentationTimer = Timer.scheduledTimer(withTimeInterval: RecentTabSwitcher.presentationDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
    }

    /// Every key while the switcher is open goes here first. Returns true when it took the event.
    func intercept(_ event: NSEvent) -> Bool {
        guard switcher != nil else {
            // ⌃Tab is the browser's, never the page's (WebKit would take it for moving focus).
            guard event.type == .keyDown else { return false }
            if Self.matches(event, id: "cycleNextTab") { cycle(forward: true); return true }
            if Self.matches(event, id: "cyclePreviousTab") { cycle(forward: false); return true }
            return false
        }
        switch event.type {
        case .flagsChanged:
            if event.modifierFlags.isDisjoint(with: holdMask) { dismiss(commit: true) }
            return false
        case .keyDown:
            if Self.matches(event, id: "cycleNextTab") {
                cycle(forward: true)
            } else if Self.matches(event, id: "cyclePreviousTab") {
                cycle(forward: false)
            } else {
                switch event.keyCode {
                case 53: dismiss(commit: false) // Esc
                case 123: cycle(forward: false) // ←
                case 124: cycle(forward: true) // →
                case 13: closeFocused() // W
                default: break
                }
            }
            // Arc's monitor swallows every other key while the switcher is up.
            return true
        case .keyUp:
            return true
        default:
            return false
        }
    }

    /// Tabs closed or moved elsewhere leave the switcher; the store changed.
    func storeChanged() {
        guard var current = switcher else { return }
        let live = Set(owner.store.state.sidebarTabs(in: owner.store.state.selectedSpaceIndex).map(\.id))
        if current.keep(live) {
            if current != switcher { switcher = current; updateView() }
        } else {
            dismiss(commit: false)
        }
    }

    /// The shown tab changed: once it has been on screen a moment, keep a picture of it for the switcher.
    func shownTabChanged() {
        snapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.captureShownPage() }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func dismiss(commit: Bool) {
        guard let current = switcher else { return }
        presentationTimer?.invalidate()
        presentationTimer = nil
        switcher = nil
        host?.removeFromSuperview()
        host = nil
        if commit { select(current.focusedID) }
    }

    // MARK: Private

    private func select(_ id: UUID) {
        owner.store.mutate { $0.select(tab: id) }
    }

    private func closeFocused() {
        guard let id = switcher?.focusedID else { return }
        owner.close(tab: id)
        if switcher?.remove(id) == false { return dismiss(commit: false) }
        updateView()
    }

    private func present() {
        presentationTimer = nil
        guard switcher != nil, host == nil, let root = owner.window?.contentView else { return }
        updateView()
        let view = NSHostingView(rootView: RecentTabSwitcherView(model: model))
        view.identifier = NSUserInterfaceItemIdentifier("RecentTabSwitcher")
        view.setAccessibilityLabel(RecentTabSwitcher.title)
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.zPosition = 30
        root.addSubview(view)
        host = view
    }

    private func updateView() {
        guard let switcher else { return }
        let state = owner.store.state
        let theme = state.selectedSpace.theme
        model.isDark = !theme.prefersDarkForeground
        model.cardAspect = Self.aspect(of: owner.webAreaInWindow.size)
        model.items = switcher.items.compactMap { id in
            state.tab(id).map { tab in
                RecentTabSwitcherModel.Item(id: id, tab: tab, title: tab.displayTitle, snapshot: snapshots[id])
            }
        }
        model.focusedID = switcher.focusedID
        model.onPick = { [weak self] id in
            self?.switcher?.focus(id)
            self?.dismiss(commit: true)
        }
    }

    private func captureShownPage() {
        guard let id = owner.store.state.selectedTab?.id, let page = owner.shownPage,
              page.view.window != nil, page.view.bounds.width > 0 else { return }
        page.captureImage(area: page.view.bounds) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, let data, let image = NSImage(data: data) else { return }
                self.snapshots[id] = Self.thumbnail(image)
                self.pruneSnapshots()
                if self.switcher != nil { self.updateView() }
            }
        }
    }

    private func pruneSnapshots() {
        let live = owner.store.state.allTabIDs
        snapshots = snapshots.filter { live.contains($0.key) }
    }

    /// Kept small: two pixels per point of the card's width.
    private static func thumbnail(_ image: NSImage) -> NSImage {
        let width = RecentTabSwitcherView.Metrics.cardWidth * 2
        guard image.size.width > width else { return image }
        let size = NSSize(width: width, height: (image.size.height * width / image.size.width).rounded())
        let small = NSImage(size: size)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        return small
    }

    private static func aspect(of size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 10.0 / 16.0 }
        return min(max(size.height / size.width, 0.4), 1.2)
    }

    /// The menu item for a switcher command, wherever the shortcut overrides put it.
    private static func menuItem(_ id: String) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == id { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    private static func shortcutModifiers() -> NSEvent.ModifierFlags {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option]
        return ["cycleNextTab", "cyclePreviousTab"].compactMap(menuItem).reduce(into: []) { mask, item in
            if !item.keyEquivalent.isEmpty { mask.formUnion(item.keyEquivalentModifierMask.intersection(relevant)) }
        }
    }

    /// Whether `event` is the shortcut of the menu item `id` (same key, same ⌘⌃⌥⇧).
    private static func matches(_ event: NSEvent, id: String) -> Bool {
        guard let item = menuItem(id), !item.keyEquivalent.isEmpty else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        var mask = item.keyEquivalentModifierMask.intersection(modifiers)
        var key = item.keyEquivalent
        if key != key.lowercased() { mask.insert(.shift); key = key.lowercased() }
        // ⇧Tab types a back-tab character; Arc's backward item uses it as its key.
        let pressed = event.charactersIgnoringModifiers?.lowercased()
        let sameKey = pressed == key || (key == "\u{19}" && pressed == "\t") || (key == "\t" && pressed == "\u{19}")
        return sameKey && event.modifierFlags.intersection(modifiers) == mask
    }
}

@MainActor
final class RecentTabSwitcherModel: ObservableObject {
    struct Item: Identifiable {
        let id: UUID
        let tab: BrowserTab
        let title: String
        let snapshot: NSImage?
    }

    @Published var items: [Item] = []
    @Published var focusedID: UUID?
    @Published var isDark = true
    @Published var cardAspect: CGFloat = 10.0 / 16.0
    var onPick: (UUID) -> Void = { _ in }
}
