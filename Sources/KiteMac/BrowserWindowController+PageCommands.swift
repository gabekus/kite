import AppKit
import KiteCore

/// Page commands from Arc's Edit, View and Developer menus: find, print, stop,
/// hard reload, view source, full screen.
extension BrowserWindowController {
    // MARK: Find

    private var findBar: FindBar? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? FindBar }.first
    }

    private var askPanel: AskOnPagePanel? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? AskOnPagePanel }.first
    }

    @objc func showFind(_ sender: Any?) {
        guard shownPage != nil else { return NSSound.beep() }
        let bar = findBar ?? makeFindBar()
        // Arc's find field takes ⌘F itself (CommandFTextField.onCommandF): typed in the field during
        // a conversation it goes back to plain find (`onShouldResetToFindInPage`). From the page it
        // only focuses the field, so a conversation brought back with its tab isn't lost.
        if !bar.isHidden, bar.inConversation, bar.fieldHasFocus {
            askPanel?.reset()
            bar.clearQuery()
        }
        bar.askEnabled = AskOnPage.isEnabled(in: .standard)
        bar.updatePlaceholder()
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
        askPanel?.reset()
        bar.clearQuery()
        shownPage?.stopFinding()
        shownPage?.focus()
    }

    /// The shown tab is changing: a conversation stays with its tab (Arc keeps `askInPageState`
    /// per window content); otherwise the bar closes as before.
    func findBarLeavesTab(_ tab: UUID?) {
        guard let bar = findBar, !bar.isHidden else { return }
        guard let tab, let panel = askPanel, panel.inConversation else { return hideFindBar() }
        askConversations.keep(panel, for: tab)
        panel.removeFromSuperview()
        attach(AskOnPagePanel(), to: bar)
        bar.isHidden = true
        bar.clearQuery()
        shownPage?.stopFinding()
    }

    /// Back on a tab that had a conversation: the bar and its answers come back, the field reading
    /// "Ask a question…". The page keeps the keyboard; ⌘F goes to the field.
    func restoreAskConversation(_ tab: UUID) {
        guard let panel = askConversations.take(for: tab) else { return }
        guard shownPage != nil, AskOnPage.isEnabled(in: .standard) else { return panel.reset() }
        let bar = findBar ?? makeFindBar()
        askPanel?.removeFromSuperview()
        attach(panel, to: bar)
        bar.askEnabled = true
        bar.updatePlaceholder()
        bar.isHidden = false
    }

    /// Closed tabs take their conversations (and any answer still coming) with them.
    func pruneAskConversations(live: Set<UUID>) {
        for panel in askConversations.prune(keeping: live) { panel.reset() }
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
        bar.onAsk = { [weak self, weak bar] question in
            guard let self, let bar else { return }
            askOnPage(question, bar: bar)
        }
        if let root = window?.contentView {
            // Above the page and the loading glow, pinned to the content card's
            // top-right corner like Arc's.
            bar.translatesAutoresizingMaskIntoConstraints = false
            let glow = root.subviews.first { $0 is GlowView }
            root.addSubview(bar, positioned: .above, relativeTo: glow ?? contentFrame)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: FindBar.Metrics.inset),
                bar.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor, constant: -FindBar.Metrics.inset),
                // In a card narrower than the bar, it narrows rather than spilling over the sidebar.
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: contentFrame.leadingAnchor, constant: FindBar.Metrics.inset),
            ])
            attach(AskOnPagePanel(), to: bar)
        }
        return bar
    }

    /// Ask on Page's answers, under the bar and as wide as it.
    private func attach(_ panel: AskOnPagePanel, to bar: FindBar) {
        guard let root = window?.contentView else { return }
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel, positioned: .above, relativeTo: bar)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: AskOnPagePanel.Metrics.gap),
            panel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: contentFrame.bottomAnchor, constant: -FindBar.Metrics.inset),
        ])
        panel.onFindQuote = { [weak self, weak bar] quote, found in
            guard let page = self?.shownPage else { return found(false) }
            page.find(quote, forward: true, findNext: false) { result in
                let hit = (result.matches ?? (result.found ? 1 : 0)) > 0
                if hit { bar?.show(result) }
                found(hit)
            }
        }
        bar.askPanel = panel
    }

    /// Ask on Page: sends the question with the page's text to Kite's built-in Claude.
    private func askOnPage(_ question: String, bar: FindBar) {
        // One question at a time: Return waits while an answer is coming.
        guard let page = shownPage, let panel = bar.askPanel, !panel.claude.isAsking,
              panel.exchanges.last.map({ $0.answer != nil || $0.failed }) ?? true else { return NSSound.beep() }
        let history = panel.exchanges
        let index = panel.begin(question)
        bar.clearQuery()
        bar.updatePlaceholder()
        page.stopFinding()
        let tab = store.state.selectedTab
        let url = tab?.url, title = tab?.displayTitle
        page.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak panel] result in
            guard let panel else { return }
            guard let raw = result as? String else {
                return panel.answer(AskOnPage.unreadablePageMessage, at: index)
            }
            let text = AskOnPage.pageText(raw)
            let prompt = AskOnPage.prompt(question: question, history: history, url: url, title: title, page: text)
            panel.claude.ask(prompt) { [weak panel] answer in
                panel?.answer(answer, at: index, longPage: text.wasTruncated ? text.fractionRead : nil)
            }
        }
    }

    // MARK: Page

    /// File › Print ⌘P: the macOS print sheet, with a page preview, on this window.
    @objc func printPage(_ sender: Any?) {
        guard let window, let page = shownPage, window.attachedSheet == nil else { return NSSound.beep() }
        let tab = store.state.selectedTab
        page.makePrintOperation { [weak self, weak window, weak page] operation in
            // The tab may have changed, or another sheet opened, while Chromium made the PDF.
            guard let self, let window, let page, page === self.shownPage, window.attachedSheet == nil else { return }
            guard let operation else { return NSSound.beep() }
            operation.jobTitle = PagePrint.jobTitle(title: tab?.title ?? "", url: tab?.url)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.printPanel.options.formUnion([.showsPreview, .showsCopies, .showsPageRange,
                                                    .showsPaperSize, .showsOrientation, .showsScaling])
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
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
