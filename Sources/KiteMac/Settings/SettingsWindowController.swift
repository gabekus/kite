import AppKit
import SwiftUI

/// ⌘, Settings, laid out like Arc 1.169's (measured on the Mac, see SettingsMetrics): a
/// preference-style toolbar of eight panes, the window titled after the pane, and the window
/// resizing to each pane's height. Not resizable; minimise and zoom are disabled, as in Arc.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let model = SettingsModel()
    private var selected: SettingsPane = .general

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: SettingsMetrics.width, height: 400)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KiteSettings")
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "KiteSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: SettingsPane? = nil) {
        guard let window else { return }
        select(pane ?? selected, animate: window.isVisible)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func select(_ pane: SettingsPane, animate: Bool) {
        guard let window else { return }
        selected = pane
        window.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        window.title = pane.title
        model.refresh()
        let host = NSHostingView(rootView: pane.view(model: model))
        host.sizingOptions = []
        let height = pane.contentHeight
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: height))
        // Keep the top edge where it is, as macOS settings windows do.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.contentView = host
        window.setFrame(frame, display: true, animate: animate)
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else { return }
        select(pane, animate: true)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { $0.toolbarIdentifier == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.toolbarLabel
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }
}
