import AppKit
import KiteCore

/// Arc's Split View Controls Menu: the menu behind each pane's split button (`SplitPaneMenu` in KiteCore).
extension BrowserWindowController {
    func installSplitPaneMenu() {
        splitPanes.onPaneMenu = { [weak self] id, button in self?.showSplitPaneMenu(for: id, from: button) }
    }

    /// Focuses the pane, then pops the menu up at the pointer, as Arc does (`popUpMenuPositioningItem:atLocation:inView:`
    /// with the mouse location). Under KITE_TEST_CONTEXT_MENU the menu is logged (and an item picked) instead.
    private func showSplitPaneMenu(for id: UUID, from button: NSView) {
        guard store.state.split(containing: id) != nil else { return }
        if store.state.selectedSpace.selectedTabID != id { store.mutate { $0.select(tab: id) } }
        let entries = store.state.splitPaneMenu(for: id)
        guard !entries.isEmpty else { return }

        let menu = NSMenu(title: "Split View Controls Menu")
        menu.autoenablesItems = false
        for entry in entries {
            guard let title = entry.item.title else {
                menu.addItem(.separator())
                continue
            }
            let item = SplitPaneMenuAction(title: title) { [weak self] in self?.runSplitPaneMenuItem(entry.item, pane: id) }
            item.isEnabled = entry.enabled
            item.image = NSImage(systemSymbolName: Self.symbol(for: entry.item), accessibilityDescription: nil)
            menu.addItem(item)
        }

        if PageContextMenuItems.testMode != nil {
            let pick = PageContextMenuItems.logForTest(menu.items.map { ($0.isSeparatorItem ? nil : $0.title, $0.isEnabled) })
            if let pick { menu.performActionForItem(at: pick) }
            return
        }
        let held = button as? SplitPaneMenuButton
        held?.isMenuOpen = true
        let point: NSPoint = window.map { splitPanes.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? NSPoint(x: button.frame.minX, y: button.frame.maxY)
        menu.popUp(positioning: nil, at: point, in: splitPanes)
        held?.isMenuOpen = false
    }

    private func runSplitPaneMenuItem(_ item: SplitPaneMenuItem, pane id: UUID) {
        switch item {
        case .move(let side):
            store.mutate { $0.moveSplitPane(id, toward: side) }
        case .add(let side):
            // The Add commands work on the focused pane, which opening the menu made this one.
            if store.state.selectedSpace.selectedTabID != id { store.mutate { $0.select(tab: id) } }
            switch side {
            case .leading: addLeftSplit(nil)
            case .trailing: addRightSplit(nil)
            case .top: addTopSplit(nil)
            case .bottom: addBottomSplit(nil)
            }
        case .separate:
            store.mutate { $0.separateFromSplit(tab: id) }
        case .convert(.vertical):
            convertToVerticalSplitView(nil)
        case .convert(.horizontal):
            convertToHorizontalSplitView(nil)
        case .separator:
            break
        }
    }

    /// SF Symbols standing in for Arc's `icon-split-move-*`, `icon-split-add-*`, `icon-separate-from-split` and
    /// `icon-split-vertical/horizontal` (Arc's own art isn't copied).
    private static func symbol(for item: SplitPaneMenuItem) -> String {
        switch item {
        case .move(.leading): "arrow.left"
        case .move(.trailing): "arrow.right"
        case .move(.top): "arrow.up"
        case .move(.bottom): "arrow.down"
        case .add(.leading): "rectangle.lefthalf.inset.filled"
        case .add(.trailing): "rectangle.righthalf.inset.filled"
        case .add(.top): "rectangle.tophalf.inset.filled"
        case .add(.bottom): "rectangle.bottomhalf.inset.filled"
        case .separate: "scissors"
        case .convert(.vertical): "rectangle.split.1x2"
        case .convert(.horizontal): "rectangle.split.2x1"
        case .separator: ""
        }
    }
}

/// A menu item that runs a closure.
private final class SplitPaneMenuAction: NSMenuItem {
    private let body: () -> Void

    init(title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { body() }
}
