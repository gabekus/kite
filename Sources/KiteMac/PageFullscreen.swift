import AppKit

/// A page in HTML fullscreen (a video's full screen button, `requestFullscreen`). Chromium (Alloy) only
/// lays the element out to fill the page's view, so the window does the rest, as Chrome does: the page's
/// view leaves its pane for a black cover over the whole window, and the window goes full screen unless
/// it already is. `end` puts everything back.
@MainActor
final class PageFullscreen {
    let tab: UUID?
    let page: WebPage
    private weak var window: NSWindow?
    private let cover = PageFullscreenView()
    private weak var home: NSView?
    /// The view the page sat just below in its pane, to go back under.
    private weak var above: NSView?
    private let frame: NSRect
    private let autoresizingMask: NSView.AutoresizingMask
    /// The window went full screen for the page, so it leaves full screen with it.
    private(set) var tookWindowFullScreen = false

    /// Nil when the page isn't in `window`.
    init?(page: WebPage, tab: UUID? = nil, in window: NSWindow) {
        let view = page.view
        guard let content = window.contentView, let home = view.superview, view.window === window else { return nil }
        self.tab = tab
        self.page = page
        self.window = window
        self.home = home
        let siblings = home.subviews
        if let index = siblings.firstIndex(of: view), index + 1 < siblings.count { above = siblings[index + 1] }
        frame = view.frame
        autoresizingMask = view.autoresizingMask

        cover.frame = content.bounds
        cover.autoresizingMask = [.width, .height]
        content.addSubview(cover)
        view.removeFromSuperview()
        view.frame = cover.bounds
        view.autoresizingMask = [.width, .height]
        cover.addSubview(view)
        page.focus()
        if !window.styleMask.contains(.fullScreen) {
            tookWindowFullScreen = true
            window.toggleFullScreen(nil)
        }
    }

    /// The person left the window's full screen (the green button, ⌃⌘F) while the page was in it.
    func windowLeftFullScreen() {
        tookWindowFullScreen = false
    }

    /// Puts the page back in its pane, and takes the window out of full screen if it went in for the page.
    /// `restore` false: the pane is going away anyway (another tab is coming), so the view just leaves the cover.
    func end(restore: Bool = true) {
        let view = page.view
        if view.superview === cover {
            view.removeFromSuperview()
            if restore, let home {
                view.frame = frame
                view.autoresizingMask = autoresizingMask
                if let above, above.superview === home {
                    home.addSubview(view, positioned: .below, relativeTo: above)
                } else {
                    home.addSubview(view)
                }
            }
        }
        cover.removeFromSuperview()
        if tookWindowFullScreen, let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        tookWindowFullScreen = false
        if restore { page.focus() }
    }
}

/// Black behind the fullscreen page, above everything else in the window (some of the window's views are
/// raised by z-position) and taking every click.
final class PageFullscreenView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.zPosition = 10_000
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }
}
