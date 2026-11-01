import AppKit

/// The browser window. It offers scroll events to `scrollInterceptor` before any view sees them, so a
/// two-finger swipe over the sidebar can page spaces even though the tab list is a scroll view too.
final class BrowserWindow: NSWindow {
    /// Returns true when it took the event.
    var scrollInterceptor: ((NSEvent) -> Bool)?
    /// Offered left-button presses, drags and releases first (`PageTopWindowDragger`); true when it took one.
    var mouseInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, scrollInterceptor?(event) == true { return }
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type), mouseInterceptor?(event) == true { return }
        super.sendEvent(event)
    }

    /// Before the web view can claim a shortcut for its page: Prefer Kite shortcuts run here (Settings › Shortcuts).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        ShortcutPriorityRouter.shared.takeBeforePage(event, in: self) || super.performKeyEquivalent(with: event)
    }
}
