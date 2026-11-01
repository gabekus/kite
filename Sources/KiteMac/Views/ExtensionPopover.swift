#if canImport(CEFBridge)
import AppKit
import CEFBridge
import KiteCore

/// An extension's toolbar popup (chrome-extension://<id>/<default_popup>) in a Kite
/// popover. Chromium can't show it in Kite's tabs ("Browser window has no toolbar"), so
/// Kite loads the popup page itself and sizes the popover to the page, within Chrome's
/// popup limits.
@MainActor
final class ExtensionPopover: NSObject, NSPopoverDelegate {
    /// Chrome's limits for extension popups.
    static let minimumSize = NSSize(width: 25, height: 25)
    static let maximumSize = NSSize(width: 800, height: 600)

    private let popover = NSPopover()
    private let page: WebPage
    private var sizePolls = 0
    private var observers: [NSObjectProtocol] = []
    private static var shown: ExtensionPopover?

    enum NewTab {
        case url(URL)
        /// A page the popup opened itself (window.open), to keep as the tab's page.
        case page(WebPage)
    }

    /// Opens a tab for the popup's links; set by the app for the main window.
    static var openTab: ((NewTab) -> Void)?

    /// Shows `url` anchored to `rect` in `view`, closing any other extension popup.
    @discardableResult
    static func show(_ url: URL, engine: WebEngine, relativeTo rect: NSRect, of view: NSView) -> ExtensionPopover {
        shown?.popover.close()
        let popover = ExtensionPopover(url: url, engine: engine)
        popover.anchor = (rect, view)
        shown = popover
        // Shown once the page has loaded and been measured, or after a moment at most.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestWait) { [weak popover] in popover?.present() }
        return popover
    }

    /// The longest a click waits for the popup before it appears anyway.
    static let longestWait: TimeInterval = 0.8
    private var anchor: (rect: NSRect, view: NSView)?
    private var presented = false

    /// Puts the popover on screen with the page hidden, and reveals the page once
    /// Chromium has painted it: before its first frame a page is a blank white
    /// rectangle, which flashed for a moment on every open.
    private func present() {
        guard !presented, let anchor, anchor.view.window != nil, Self.shown === self else { return }
        presented = true
        page.view.alphaValue = 0
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: Self.belowEdge(of: anchor.view))
        let painted = "new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))"
        page.evaluateJavaScript(painted) { [weak self] _ in self?.page.view.alphaValue = 1 }
        // In case the page never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.page.view.alphaValue = 1 }
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
        // A permission prompt the popup asked for (Bitwarden's "Unlock with biometrics")
        // belongs to the popup's page: clicking it mustn't close the popup and so cancel it,
        // and the popup mustn't cover it. The popup steps aside until it's answered.
        for (name, prompting) in [(Notification.Name.KCExtensionInstallDialogDidOpen, true),
                                  (.KCExtensionInstallDialogDidClose, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPrompting(prompting) }
            })
        }
        page.onEvent = { [weak self] event in
            switch event {
            case let .navigationState(isLoading, _, _) where !isLoading: self?.fitToPage()
            case .closeRequested: self?.popover.close()
            // Links and window.open in the popup ("Add account", "Open 1Password") open as a
            // tab in front, and the popup closes, as in Chrome.
            case let .openInNewTab(url, _):
                Self.openTab?(.url(url))
                self?.popover.close()
            case let .popup(page):
                Self.openTab?(.page(page))
                self?.popover.close()
            default: break
            }
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
            self.present()
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

    private func setPrompting(_ prompting: Bool) {
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return }
        popover.behavior = prompting ? .applicationDefined : .transient
        if prompting { window.orderOut(nil) } else { window.orderFront(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        page.onEvent = nil
        page.close()
        if Self.shown === self { Self.shown = nil }
    }
}
#endif
