import AppKit
import KiteCore

/// Settings › Advanced › "Allow window dragging from the top of webpages", as Arc's
/// `WindowContentGrabber`: a press in a page's top band (`PageTopWindowDrag`) still goes to the
/// page, but if the pointer is the arrow cursor there (not over a link or text) and the press
/// then moves past 1pt, the window moves instead of the page seeing the drag.
@MainActor
final class PageTopWindowDragger {
    /// Where the armed press went down, in window points.
    private var press: NSPoint?

    /// The window hands its left-button events here before any view sees them.
    func install(in window: BrowserWindow) {
        window.mouseInterceptor = { [weak self, weak window] event in
            guard let self, let window else { return false }
            return self.handle(event, in: window)
        }
    }

    /// True when the event was the window drag's.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown:
            press = nil
            guard event.clickCount == 1, PageTopWindowDrag.isEnabled(), NSCursor.current == NSCursor.arrow,
                  isInBand(event.locationInWindow, of: window) else { return false }
            press = event.locationInWindow
            return false
        case .leftMouseDragged:
            guard let start = press else { return false }
            let p = event.locationInWindow
            guard PageTopWindowDrag.startsDrag(dx: Double(p.x - start.x), dy: Double(p.y - start.y)) else { return true }
            press = nil
            window.performDrag(with: event)
            return true
        default:
            press = nil
            return false
        }
    }

    /// Whether the point is on a page (not an overlay above it) in its card's top band.
    private func isInBand(_ point: NSPoint, of window: NSWindow) -> Bool {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
        var view: NSView? = hit
        while let candidate = view, !(candidate is ContentClipView) { view = candidate.superview }
        guard let clip = view as? ContentClipView, let page = clip.page, hit.isDescendant(of: page) else { return false }
        let p = clip.convert(point, from: nil)
        let fromTop = clip.isFlipped ? p.y : clip.bounds.height - p.y
        return PageTopWindowDrag.contains(x: Double(p.x), y: Double(fromTop), cardWidth: Double(clip.bounds.width),
                                          toolbarHeight: Double(clip.topInset))
    }
}
