#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The window's tabs as extensions see them (ExtensionTabsBridge): every live tab in
/// every space, in sidebar order, with the selected one active.
extension BrowserWindowController: ExtensionTabsHost {
    var extensionTabs: [ExtensionTab] {
        let state = store.state
        let selected = state.selectedTab?.id
        var seen = Set<UUID>()
        var tabs: [ExtensionTab] = []
        let pinned = Set(state.favorites.map(\.id) + state.spaces.flatMap { $0.pinned.map(\.id) })
        for tab in state.favorites + state.spaces.flatMap(\.allTabs) where seen.insert(tab.id).inserted {
            guard let page = pool.loadedPage(tab.id) as? ChromiumPage else { continue }
            tabs.append(ExtensionTab(
                id: tab.id, page: page, active: tab.id == selected, pinned: pinned.contains(tab.id),
                profile: pool.engine(forTab: tab.id).profileDirectory
            ))
        }
        return tabs
    }

    var extensionWindowBounds: CGRect {
        guard let window else { return .zero }
        let screenTop = (window.screen ?? NSScreen.screens.first)?.frame.maxY ?? window.frame.maxY
        return CGRect(x: window.frame.minX, y: screenTop - window.frame.maxY, width: window.frame.width, height: window.frame.height)
    }

    var extensionWindowIsFocused: Bool { NSApp.isActive && window?.isKeyWindow == true }

    var extensionWindowIsFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func openTabForExtension(url: URL?, active: Bool) -> ChromiumPage? {
        let id = store.mutate { $0.openTab(url: url, select: active) }
        guard let tab = store.state.tab(id) else { return nil }
        // A background tab loads now, as in Chrome, so the extension gets a working tab.
        return pool.page(for: tab) as? ChromiumPage
    }

    func activateTabForExtension(_ id: UUID) {
        store.mutate { $0.select(tab: id) }
    }
}
#endif

#if canImport(CEFBridge)
extension BrowserWindowController {
    /// ⇧⌘X: the password manager's popup over the top right of the page, for the selected tab.
    @objc func showPasswordManager(_ sender: Any?) {
        if !openPasswordManager() { NSSound.beep() }
    }

    /// The password manager's popup over the top right of the page. False when it can't open here.
    @discardableResult
    func openPasswordManager() -> Bool {
        guard !isIncognito else { return false }
        let bounds = contentFrame.bounds
        let anchor = NSRect(x: bounds.maxX - 40, y: contentFrame.isFlipped ? bounds.minY : bounds.maxY - 1, width: 1, height: 1)
        return PasswordManagerIntegration.showPopup(engine: pool.currentEngine, relativeTo: anchor, of: contentFrame)
    }

    /// For Claude's sign_in: whether the password manager can fill in this window.
    var canOpenPasswordManager: Bool { !isIncognito && PasswordManagerIntegration.isExtensionInstalled(in: pool.currentEngine) }

    /// For Claude's sign_in banner: the password manager's name, or nil without one.
    var passwordManagerName: String? {
        let manager = PasswordManagerIntegration.current
        return manager == .none ? nil : manager.name
    }
}
#else
import AppKit

extension BrowserWindowController {
    /// WebKit-only builds (no CEF) have no extensions, so ⇧⌘X has nothing to open.
    /// The File menu still names this action; validateMenuItem keeps it disabled.
    @objc func showPasswordManager(_ sender: Any?) { NSSound.beep() }

    var canOpenPasswordManager: Bool { false }
    var passwordManagerName: String? { nil }
    func openPasswordManager() -> Bool { false }
}
#endif

extension BrowserWindowController {
    /// Follows the current space's profile: pages left in another profile reload, and the
    /// extensions shown are the profile's own.
    func syncProfile() {
        pool.discardPagesInWrongProfile()
        let engine = pool.currentEngine
        guard engine.profileDirectory != shownProfileDirectory else { return }
        shownProfileDirectory = engine.profileDirectory
        #if canImport(CEFBridge)
        if engine is ChromiumEngine { extensionsSelection?.show(ExtensionsModel.shared(engine: engine)) }
        #endif
        onProfileChange?(engine)
    }
}
