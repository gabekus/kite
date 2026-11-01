import AppKit
import KiteCore

extension Notification.Name {
    /// A window's Zap picker opened or closed; `object` is the window controller. The Boost
    /// editor's Zap button follows it.
    static let kiteZapPickerChanged = Notification.Name("KiteZapPickerChanged")
}

/// Zap: Arc opens its picker from the Boost editor's Zap tool, and the zaps are part of the
/// site's Boost. Never in incognito windows, which don't run Boosts.
extension BrowserWindowController {
    /// Opens the picker over the shown page; zaps go to the site's newest Boost (made by the
    /// first zap if the site has none).
    @objc func showZapPicker(_ sender: Any?) {
        showZapPicker(boostID: nil)
    }

    /// Opens the picker over the shown page for `boostID` (the Boost editor's Zap button).
    /// Beeps when the shown page isn't on the web or, given a Boost, isn't on its site.
    func showZapPicker(boostID: UUID?) {
        guard !isIncognito, let page = shownPage, let container = page.view.superview,
              let tab = store.state.selectedTab, let domain = BoostLibrary.domain(of: tab.url) else { return NSSound.beep() }
        if let boostID, BoostsModel.shared.library.boost(boostID)?.domain != domain { return NSSound.beep() }
        removeZapPickers()
        let picker = ZapPicker(page: page, boostID: boostID)
        picker.onClose = { [weak self] in self?.hideZapPicker() }
        container.addSubview(picker, positioned: .above, relativeTo: page.view)
        window?.makeFirstResponder(picker)
        NotificationCenter.default.post(name: .kiteZapPickerChanged, object: self)
    }

    /// Whether the picker is open in this window.
    var isShowingZapPicker: Bool { !zapPickers().isEmpty }

    /// Closes every picker in the window (the shown tab changed, or the user closed it).
    func hideZapPicker() {
        guard removeZapPickers() else { return }
        NotificationCenter.default.post(name: .kiteZapPickerChanged, object: self)
    }

    @discardableResult
    private func removeZapPickers() -> Bool {
        let pickers = zapPickers()
        for picker in pickers {
            picker.removeFromSuperview()
            BoostsModel.shared.applyZapsLive(to: picker.page)
        }
        return !pickers.isEmpty
    }

    private func zapPickers() -> [ZapPicker] {
        guard let root = window?.contentView else { return [] }
        var found: [ZapPicker] = []
        var pending = [root]
        while let view = pending.popLast() {
            for sub in view.subviews {
                if let picker = sub as? ZapPicker { found.append(picker) } else { pending.append(sub) }
            }
        }
        return found
    }
}
