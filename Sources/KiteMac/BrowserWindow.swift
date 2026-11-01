import AppKit

/// The browser window. It offers scroll events to `scrollInterceptor` before any view sees them, so a
/// two-finger swipe over the sidebar can page spaces even though the tab list is a scroll view too.
final class BrowserWindow: NSWindow {
    /// Returns true when it took the event.
    var scrollInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, scrollInterceptor?(event) == true { return }
        super.sendEvent(event)
    }
}
