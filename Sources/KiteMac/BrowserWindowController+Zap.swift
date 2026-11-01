import AppKit
import KiteCore

/// Zap: Arc opens its picker from the Boost editor's Zap tool. Until Kite's Boost editor
/// exists, `showZapPicker` is the entry point it will call.
extension BrowserWindowController {
    /// Opens the picker over the shown page.
    @objc func showZapPicker(_ sender: Any?) {
        guard let page = shownPage, let container = page.view.superview else { return NSSound.beep() }
        hideZapPicker()
        let picker = ZapPicker(page: page)
        picker.onClose = { [weak self] in self?.hideZapPicker() }
        container.addSubview(picker, positioned: .above, relativeTo: page.view)
        window?.makeFirstResponder(picker)
    }

    /// Closes every picker in the window (the shown tab changed, or the user closed it).
    func hideZapPicker() {
        guard let root = window?.contentView else { return }
        var pending = [root]
        while let view = pending.popLast() {
            for sub in view.subviews {
                if let picker = sub as? ZapPicker {
                    picker.removeFromSuperview()
                    ZapsModel.shared.applyLive(to: picker.page)
                } else {
                    pending.append(sub)
                }
            }
        }
    }
}
