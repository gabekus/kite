import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

/// Installs a Chrome Web Store extension without leaving the page you're on: the
/// store page loads in a browser that's never shown or listed as a tab, its own Add
/// flow runs there, and Chrome's dialog asks over your page (KCExtensionWindows.mm).
/// The Google result's button follows along: Adding…, then Added or Add to Kite.
@MainActor
final class BackgroundExtensionInstall {
    let extensionID: String
    private let page: WebPage
    private weak var source: WebPage?
    private let onFinish: () -> Void
    private var started = false
    private var dialogClosedAt: Date?
    private var finished = false
    private var poll: Timer?
    private var dialogObserver: NSObjectProtocol?

    /// Gives up (and relabels the button) if nothing happened in this long.
    private static let timeout: TimeInterval = 120

    init(extensionID: String, storeURL: URL, engine: WebEngine, source: WebPage?, onFinish: @escaping () -> Void) {
        self.extensionID = extensionID
        self.source = source
        self.onFinish = onFinish
        page = engine.makePage(url: storeURL, restoring: nil)
        // In the window but hidden: Chrome needs a window to parent its dialog to.
        if let content = NSApp.mainWindow?.contentView {
            page.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            page.view.isHidden = true
            content.addSubview(page.view, positioned: .below, relativeTo: nil)
        }
        page.onEvent = { [weak self] event in
            guard let self, case let .navigationState(isLoading, _, _) = event, !isLoading, !self.started else { return }
            self.started = true
            self.page.evaluateJavaScript(WebStoreScript.startAddScript) { _ in }
        }
        #if canImport(CEFBridge)
        dialogObserver = NotificationCenter.default.addObserver(
            forName: .KCExtensionInstallDialogDidClose, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dialogClosedAt = Date() }
        }
        #endif
        let deadline = Date().addingTimeInterval(Self.timeout)
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(deadline: deadline) }
        }
        relabel("Adding\u{2026}", disabled: true)
    }

    /// Installed once the extension's folder exists; cancelled once the dialog has
    /// closed and the store offers Add again.
    private func check(deadline: Date) {
        if Self.installedIDs().contains(extensionID) { return finish(installed: true) }
        if Date() > deadline { return finish(installed: false) }
        guard let closed = dialogClosedAt, Date().timeIntervalSince(closed) > 1.5 else { return }
        page.evaluateJavaScript(WebStoreScript.offersAddScript) { [weak self] result in
            guard let self, (result as? Bool) == true, !Self.installedIDs().contains(self.extensionID) else { return }
            self.finish(installed: false)
        }
    }

    private func finish(installed: Bool) {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        if let dialogObserver { NotificationCenter.default.removeObserver(dialogObserver) }
        relabel(installed ? "Added" : "Add to Kite", disabled: installed)
        page.onEvent = nil
        page.close()
        onFinish()
    }

    private func relabel(_ text: String, disabled: Bool) {
        guard let script = GoogleResultsScript.label(extensionID, text, disabled: disabled) else { return }
        source?.evaluateJavaScript(script) { _ in }
    }

    /// Extension ids installed in Kite's Chromium profile.
    static func installedIDs() -> Set<String> {
        let directory = AppDelegate.supportDirectory.appendingPathComponent("Chromium/Default/Extensions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter(ChromeWebStore.isExtensionID))
    }
}
