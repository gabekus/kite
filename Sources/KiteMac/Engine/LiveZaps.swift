import AppKit
import ObjectiveC
import KiteCore

/// Keeps an open page's zaps current: when a zap is added or removed, or a Boost is turned on,
/// off or deleted, the page's zap style is replaced without a reload. New documents get their
/// zaps from the Boost script at document start. Engines attach it only to pages that run
/// Boosts, so incognito pages never get zaps.
@MainActor
final class LiveZaps: NSObject {
    private weak var page: WebPage?
    private nonisolated(unsafe) static var key: UInt8 = 0

    private init(page: WebPage) {
        self.page = page
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(zapsChanged), name: .kiteZapsChanged, object: nil)
    }

    @objc private func zapsChanged() {
        if let page { BoostsModel.shared.applyZapsLive(to: page) }
    }

    /// Lives as long as `owner` (the page).
    static func attach(to page: WebPage, owner: NSObject) {
        objc_setAssociatedObject(owner, &key, LiveZaps(page: page), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
