import AppKit

/// The menu bar's target. Forwards each command to the browser window in front
/// (key, else main), so the same menu drives the normal and incognito windows.
/// With a DevTools or panel window key, the main browser window still answers.
@MainActor
final class MenuRouter: NSObject, NSMenuItemValidation {
    private weak var fallback: BrowserWindowController?

    init(fallback: BrowserWindowController) {
        self.fallback = fallback
    }

    /// While `ui input` delivers a key to a background window, menu commands go to that window.
    static var deliveringTo: BrowserWindowController?

    var current: BrowserWindowController? {
        Self.deliveringTo
            ?? NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
            ?? fallback
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (current?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        current
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        current?.validateMenuItem(item) ?? false
    }

    @objc func newIncognitoWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openIncognitoWindow()
    }
}
