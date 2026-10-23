import AppKit
#if canImport(CEFBridge)
import CEFBridge
#endif

/// SPIKE: installs an extension without leaving the page you're on. The store page
/// loads in a browser that's never shown or listed as a tab; its own Add flow runs
/// there, and Chrome's own dialog asks for confirmation over the page you're on.
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
    private var observer: NSObjectProtocol?

    init(extensionID: String, engine: WebEngine, source: WebPage, onFinish: @escaping () -> Void) {
        self.extensionID = extensionID
        self.source = source
        self.onFinish = onFinish
        page = engine.makePage(url: URL(string: "https://chromewebstore.google.com/detail/\(extensionID)"), restoring: nil)
        // In the window but hidden: Chrome parents its dialog to the page's window.
        if let content = NSApp.mainWindow?.contentView {
            page.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            page.view.isHidden = true
            content.addSubview(page.view, positioned: .below, relativeTo: nil)
        }
        page.onEvent = { [weak self] event in
            guard let self, case let .navigationState(isLoading, _, _) = event, !isLoading, !self.started else { return }
            self.started = true
            NSLog("KiteSpike: background store page loaded; starting the Add flow for %@", extensionID)
            self.page.evaluateJavaScript(WebStoreScript.startAddScript) { _ in }
        }
        #if canImport(CEFBridge)
        observer = NotificationCenter.default.addObserver(forName: .KCExtensionInstallDialogDidClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dialogClosedAt = Date() }
        }
        #endif
        // Installed: the extension's folder exists. Cancelled: the dialog closed and the
        // store offers "Add to Kite" again. Gives up after two minutes either way.
        let deadline = Date().addingTimeInterval(120)
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.installedIDs().contains(extensionID) { return self.finish(installed: true) }
                if Date() > deadline { return self.finish(installed: false) }
                guard let closed = self.dialogClosedAt, Date().timeIntervalSince(closed) > 1.5 else { return }
                self.page.evaluateJavaScript(Self.offersAddScript) { result in
                    if (result as? Bool) == true, !Self.installedIDs().contains(extensionID) { self.finish(installed: false) }
                }
            }
        }
        source.evaluateJavaScript(Self.label(extensionID, "Adding\u{2026}", disabled: true)) { _ in }
    }

    private func finish(installed: Bool) {
        guard !finished else { return }
        finished = true
        NSLog("KiteSpike: background install of %@ %@", extensionID, installed ? "finished" : "ended without installing")
        poll?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        source?.evaluateJavaScript(Self.label(extensionID, installed ? "Added" : "Add to Kite", disabled: installed)) { _ in }
        page.onEvent = nil
        page.close()
        onFinish()
    }

    private static let offersAddScript =
        "[...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Add to Kite' && !b.disabled)"

    /// Relabels Kite's buttons for one extension on a Google results page.
    static func label(_ extensionID: String, _ text: String, disabled: Bool) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        document.querySelectorAll('.kite-add[data-id="\(extensionID)"]').forEach((b) => {
          b.textContent = \(quoted)[0];
          b.disabled = \(disabled);
        });
        """
    }

    /// Extension ids installed in this Chromium profile.
    static func installedIDs() -> [String] {
        let directory = AppDelegate.supportDirectory.appendingPathComponent("Chromium/Default/Extensions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
    }
}
