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
        showToast("Copied URL")
    }

    @objc func copyURLAsMarkdown(_ sender: Any?) {
        guard let tab = store.state.selectedTab, let url = tab.url else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LinkFormat.markdown(title: tab.title, url: url), forType: .string)
        showToast("Copied as Markdown")
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
            self?.showToast(selection.isEmpty ? "Nothing selected, copied link" : "Copied as Quote")
        }
    }

    func showToast(_ message: String) {
        guard let root = window?.contentView else { return }
        let toast = root.subviews.lazy.compactMap { $0 as? ToastView }.first ?? {
            let toast = ToastView()
            toast.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(toast)
            NSLayoutConstraint.activate([
                toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            ])
            return toast
        }()
        toast.show(message)
    }
}
