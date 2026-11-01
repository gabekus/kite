import AppKit
import KiteCore

/// Site Controls (Arc's Site Control Center): the popover from the sliders button in the
/// sidebar's address field and in the page toolbar. It gathers Kite's per-site switches in
/// one place: the ad blocker, the default mail app, permissions (Chromium only), and clearing
/// the site's cache or cookies.
extension BrowserWindowController {
    func toggleSiteControls(from view: NSView, overlap: CGFloat = 0) {
        SiteControlsPopover.toggle(makeSiteControls(), from: view, overlap: overlap)
    }

    private func makeSiteControls() -> SiteControlsModel? {
        guard let url = store.state.selectedTab?.url, SiteControls.applies(to: url), shownPage != nil else { return nil }
        let actions = SiteControlsModel.Actions(
            copyURL: { [weak self] in self?.copyURL(nil) },
            share: { view in NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY) },
            toggleAdblock: { [weak self] in self?.toggleAdblockForSite(nil) },
            clearCache: { [weak self] in self?.clearCacheAndRefresh(nil) },
            clearCookies: { [weak self] in self?.clearCookiesAndRefresh(nil) },
            setPermission: { [weak self] permission, value in self?.shownPage?.setSitePermission(permission, value, for: url) },
            removeMailHandler: { MailHandlers.shared.remove(host: url.host) }
        )
        return SiteControlsModel(url: url, actions: actions) { [weak self] model in
            guard let self else { return }
            let url = model.url
            model.blocksAds = Adblocker.isAvailable ? store.state.blocksAds(on: url) : nil
            model.isMailHandler = MailHandlers.shared.isDefault(host: url.host) ? true : nil
            if let page = shownPage, page.sitePermission(.camera, for: url) != nil {
                var values: [SitePermission: SitePermissionValue] = [:]
                for permission in SitePermission.allCases {
                    values[permission] = page.sitePermission(permission, for: url)
                }
                model.permissions = values
            } else {
                model.permissions = nil
            }
        }
    }
}
