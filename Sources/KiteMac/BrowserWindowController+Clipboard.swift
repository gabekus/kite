import AppKit
import KiteCore

/// Arc's copy commands: ⇧⌘C copies the current tab's URL, ⌥⇧⌘C copies it as a Markdown link,
/// and ⌃⇧⌘C copies the page's selection as a quote with the link underneath.
extension BrowserWindowController {
    @objc func copyURL(_ sender: Any?) {
        guard let tab = store.state.selectedTab, let url = tab.url else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Both types, so apps that take a URL (Finder, Messages) get a link and text fields get the string.
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        showToast("Copied Current URL", shareURL: url)
    }

    @objc func copyURLAsMarkdown(_ sender: Any?) {
        guard let tab = store.state.selectedTab, let url = tab.url else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LinkFormat.markdown(title: tab.title, url: url), forType: .string)
        showToast("Copied as Markdown", shareURL: url)
    }

    @objc func copyURLAsQuote(_ sender: Any?) {
        guard let tab = store.state.selectedTab, let url = tab.url, let page = shownPage else {
            return NSSound.beep()
        }
        page.evaluateJavaScript("String(window.getSelection())") { [weak self] result in
            let selection = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = LinkFormat.quote(selection: selection, title: tab.title, url: url)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self?.showToast(selection.isEmpty ? "Nothing selected, copied link" : "Copied as Quote", shareURL: url)
        }
    }

    func showToast(_ message: String, shareURL: URL? = nil) {
        guard let root = window?.contentView else { return }
        let toast = root.subviews.lazy.compactMap { $0 as? ToastView }.first ?? {
            let toast = ToastView()
            toast.translatesAutoresizingMaskIntoConstraints = false
            // Above the page and the loading glow, at the content card's top-right corner like Arc's.
            let glow = root.subviews.first { $0 is GlowView }
            root.addSubview(toast, positioned: .above, relativeTo: glow ?? contentFrame)
            NSLayoutConstraint.activate([
                toast.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: ToastView.Metrics.top),
                toast.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor, constant: -ToastView.Metrics.trailing),
            ])
            return toast
        }()
        // In a split, Arc puts it at the focused pane's top-right corner instead.
        let pane = focusedPaneInsets
        for constraint in root.constraints where constraint.firstItem === toast {
            if constraint.firstAttribute == .top { constraint.constant = ToastView.Metrics.top + pane.top }
            if constraint.firstAttribute == .trailing { constraint.constant = -ToastView.Metrics.trailing - pane.trailing }
        }
        toast.show(message, shareURL: shareURL)
    }
}
