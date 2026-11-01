#if canImport(CEFBridge)
import AppKit
import KiteCore

/// An extension's toolbar popup (chrome-extension://<id>/<default_popup>) in a Kite
/// popover. Chromium can't show it in Kite's tabs ("Browser window has no toolbar"), so
/// Kite loads the popup page itself and sizes the popover to the page, within Chrome's
/// popup limits.
///
/// Extensions don't see Kite's tabs yet (Alloy-style browsers aren't in Chromium's tab
/// model), so popups that act on the current tab can't find it.
@MainActor
final class ExtensionPopover: NSObject, NSPopoverDelegate {
    /// Chrome's limits for extension popups.
    static let minimumSize = NSSize(width: 25, height: 25)
    static let maximumSize = NSSize(width: 800, height: 600)

    private let popover = NSPopover()
    private let page: WebPage
    private var sizePolls = 0
    private static var shown: ExtensionPopover?

    /// Shows `url` anchored to `rect` in `view`, closing any other extension popup.
    @discardableResult
    static func show(_ url: URL, engine: WebEngine, relativeTo rect: NSRect, of view: NSView) -> ExtensionPopover {
        shown?.popover.close()
        let popover = ExtensionPopover(url: url, engine: engine)
        popover.popover.show(relativeTo: rect, of: view, preferredEdge: belowEdge(of: view))
        shown = popover
        return popover
    }

    private init(url: URL, engine: WebEngine) {
        page = engine.makePage(url: url, restoring: nil)
        super.init()
        let controller = NSViewController()
        controller.view = page.view
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 120)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        page.onEvent = { [weak self] event in
            if case let .navigationState(isLoading, _, _) = event, !isLoading { self?.fitToPage() }
            if case .closeRequested = event { self?.popover.close() }
        }
    }

    /// Popups size themselves after they load (often after an async render), so measure a
    /// few times.
    private func fitToPage() {
        let measure = "JSON.stringify([document.documentElement.scrollWidth, document.documentElement.scrollHeight])"
        page.evaluateJavaScript(measure) { [weak self] result in
            guard let self, let json = (result as? String)?.data(using: .utf8),
                  let size = try? JSONSerialization.jsonObject(with: json) as? [Double], size.count == 2 else { return }
            self.popover.contentSize = Self.clamped(NSSize(width: size[0], height: size[1]))
            self.sizePolls += 1
            if self.sizePolls < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(self.sizePolls)) { [weak self] in self?.fitToPage() }
            }
        }
    }

    /// The rect's bottom edge, so the popover hangs below its anchor.
    static func belowEdge(of view: NSView) -> NSRectEdge {
        view.isFlipped ? .maxY : .minY
    }

    static func clamped(_ size: NSSize) -> NSSize {
        NSSize(width: min(max(size.width, minimumSize.width), maximumSize.width),
               height: min(max(size.height, minimumSize.height), maximumSize.height))
    }

    func popoverDidClose(_ notification: Notification) {
        page.onEvent = nil
        page.close()
        if Self.shown === self { Self.shown = nil }
    }
}
#endif
