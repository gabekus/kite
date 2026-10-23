import AppKit
import KiteCore

/// Page commands from Arc's Edit, View and Developer menus: find, print, stop,
/// hard reload, view source, full screen.
extension BrowserWindowController {
    // MARK: Find

    private var findBar: FindBar? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? FindBar }.first
    }

    @objc func showFind(_ sender: Any?) {
        guard shownPage != nil else { return NSSound.beep() }
        let bar = findBar ?? makeFindBar()
        bar.isHidden = false
        bar.focus()
    }

    @objc func findNext(_ sender: Any?) { stepFind(forward: true) }
    @objc func findPrevious(_ sender: Any?) { stepFind(forward: false) }

    /// ⌘E: search for the page's selected text.
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let page = shownPage else { return NSSound.beep() }
        page.evaluateJavaScript("String(window.getSelection())") { [weak self] result in
            guard let self, let text = result as? String, !text.isEmpty else { return NSSound.beep() }
            let bar = findBar ?? makeFindBar()
            bar.isHidden = false
            bar.setQuery(text)
        }
    }

    /// Closes the find bar and clears highlights. Called when the shown tab changes too.
    func hideFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        shownPage?.stopFinding()
        shownPage?.focus()
    }

    private func stepFind(forward: Bool) {
        guard let bar = findBar, !bar.isHidden, !bar.query.isEmpty else { return showFind(nil) }
        bar.step(forward: forward)
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        bar.onSearch = { [weak self, weak bar] text, forward, findNext in
            guard let page = self?.shownPage else { return }
            if text.isEmpty { return page.stopFinding() }
            page.find(text, forward: forward, findNext: findNext) { bar?.show($0) }
        }
        bar.onClose = { [weak self] in self?.hideFindBar() }
        if let root = window?.contentView {
            // Above the page and the loading glow, pinned to the content card's
            // top-right corner like Arc's.
            bar.translatesAutoresizingMaskIntoConstraints = false
            let glow = root.subviews.first { $0 is GlowView }
            root.addSubview(bar, positioned: .above, relativeTo: glow ?? contentFrame)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: FindBar.Metrics.inset),
                bar.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor, constant: -FindBar.Metrics.inset),
            ])
        }
        return bar
    }

    // MARK: Page

    @objc func printPage(_ sender: Any?) {
        guard let page = shownPage else { return NSSound.beep() }
        page.printPage()
    }

    @objc func stopLoading(_ sender: Any?) {
        shownPage?.stopLoading()
    }

    /// Our own action rather than `toggleFullScreen:`, which macOS rebinds to fn-F.
    @objc func toggleFullScreenMode(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    @objc func forceReload(_ sender: Any?) {
        shownPage?.reloadIgnoringCache()
    }

    /// Chromium's view-source: page in a new tab, next to the page, like Arc.
    @objc func viewSource(_ sender: Any?) {
        guard pool.engine.supportsDevTools,
              let url = store.state.selectedTab?.url,
              let source = URL(string: "view-source:" + url.absoluteString)
        else { return NSSound.beep() }
        store.mutate { _ = $0.openTab(url: source) }
    }

    /// ⇧⌘V. Chromium's content view implements `pasteAndMatchStyle:`, AppKit text views `pasteAsPlainText:`.
    @objc func pasteMatchingStyle(_ sender: Any?) {
        if !NSApp.sendAction(Selector(("pasteAndMatchStyle:")), to: nil, from: sender) {
            NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: sender)
        }
    }
}
