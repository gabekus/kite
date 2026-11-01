import AppKit

extension BrowserWindowController {
    /// Window › View Media… (Arc: no shortcut): the Library's Media page.
    @objc func viewMedia(_ sender: Any?) {
        library.open(.media)
    }
}
