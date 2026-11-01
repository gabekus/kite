import AppKit
import ObjectiveC
import KiteCore

/// Keeps an open page's Boost styles and zaps current without a reload, as Arc does: when a
/// Boost's CSS, font, text case, size or colours change, or a zap is added or removed, or a Boost
/// is turned on, off or deleted, the page's Boost styles are replaced live. New documents get
/// them from the Boost script at document start. A Boost's JavaScript runs again only on a
/// reload. Engines attach this only to pages that run Boosts, so incognito pages never get it.
@MainActor
final class LiveBoosts: NSObject {
    private weak var page: WebPage?
    private nonisolated(unsafe) static var key: UInt8 = 0

    private init(page: WebPage) {
        self.page = page
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(zapsChanged), name: .kiteZapsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stylesChanged(_:)), name: .kiteBoostStylesChanged, object: nil)
    }

    @objc private func zapsChanged() {
        if let page { BoostsModel.shared.applyZapsLive(to: page) }
    }

    @objc private func stylesChanged(_ notification: Notification) {
        guard let page, let domains = notification.userInfo?["domains"] as? Set<String> else { return }
        BoostsModel.shared.applyStylesLive(to: page, domains: domains)
    }

    /// Lives as long as `owner` (the page).
    static func attach(to page: WebPage, owner: NSObject) {
        objc_setAssociatedObject(owner, &key, LiveBoosts(page: page), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
