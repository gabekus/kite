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
    /// The same for a Little Kite window.
    static var deliveringToLittle: (NSWindowController & NSMenuItemValidation)?

    /// A key `ui input` gave a background window's web page. WebKit answers later and, when the page
    /// doesn't use the key, sends the same event through the app to the menu bar; with Kite in the
    /// background its command would otherwise land in whichever window AppKit picks.
    final class PageKey {
        let event: NSEvent
        weak var browser: BrowserWindowController?
        weak var little: (NSWindowController & NSMenuItemValidation)?
        init(event: NSEvent, browser: BrowserWindowController?, little: (NSWindowController & NSMenuItemValidation)?) {
            self.event = event
            self.browser = browser
            self.little = little
        }
    }

    private static var pageKeys: [PageKey] = []

    static func handedToPage(_ event: NSEvent, browser: BrowserWindowController?, little: (NSWindowController & NSMenuItemValidation)?) {
        pageKeys = Array(pageKeys.suffix(7)) + [PageKey(event: event, browser: browser, little: little)]
    }

    /// The page key the app is handing to the menu bar right now, if any.
    private static var pageKeyBeingHandedBack: PageKey? {
        guard !pageKeys.isEmpty, let event = NSApp.currentEvent, event.type == .keyDown else { return nil }
        return pageKeys.last { $0.event === event }
    }

    /// A Little Kite window in front takes the commands it has (Back, Reload, Copy URL, Archive Tab
    /// closes it); the rest are off there rather than acting on the main window behind it.
    /// An installed web app's window in front does the same (WebAppWindowController).
    var little: (NSWindowController & NSMenuItemValidation)? {
        if Self.deliveringTo != nil { return nil }
        if let pageKey = Self.pageKeyBeingHandedBack { return pageKey.little }
        func auxiliary(_ window: NSWindow?) -> (NSWindowController & NSMenuItemValidation)? {
            let controller = window?.windowController
            if let little = controller as? LittleKiteWindowController { return little }
            return controller as? WebAppWindowController
        }
        return Self.deliveringToLittle ?? auxiliary(NSApp.keyWindow) ?? (NSApp.keyWindow == nil ? auxiliary(NSApp.mainWindow) : nil)
    }

    var current: BrowserWindowController? {
        Self.deliveringTo
            ?? Self.pageKeyBeingHandedBack?.browser
            ?? NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
            ?? fallback
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        if let little { return little.responds(to: selector) }
        return current?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let little { return little.responds(to: selector) ? little : nil }
        return current
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let little {
            guard let action = item.action else { return false }
            if [#selector(newWindow(_:)), #selector(newBlankWindow(_:)), #selector(newIncognitoWindow(_:)),
                #selector(newLittleKiteWindow(_:))].contains(action) { return true }
            return little.responds(to: action) && little.validateMenuItem(item)
        }
        return current?.validateMenuItem(item) ?? false
    }

    @objc func newWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openNewWindow()
    }

    @objc func newBlankWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openBlankWindow()
    }

    @objc func newIncognitoWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openIncognitoWindow()
    }

    @objc func newLittleKiteWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openLittleKiteWindow(url: nil)
    }
}
