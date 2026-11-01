import AppKit
import Combine
import KiteCore

/// Site Controls (Arc's Site Control Center): the popover from the sliders button in the
/// sidebar's address field and in the page toolbar. It gathers Kite's per-site switches in
/// one place: the site's Boosts, the ad blocker, Developer Mode, the default mail app, permissions
/// (Chromium only), clearing the site's cache or cookies, and the site's settings page.
extension BrowserWindowController {
    func toggleSiteControls(from view: NSView, overlap: CGFloat = 0) {
        SiteControlsPopover.toggle(makeSiteControls(anchor: view), from: view, overlap: overlap)
    }

    private func makeSiteControls(anchor: NSView) -> SiteControlsModel? {
        guard let url = store.state.selectedTab?.url, SiteControls.applies(to: url), shownPage != nil else { return nil }
        // Capture waits for the popover to go, so it isn't in the picture or over the overlay.
        let later = { (body: @escaping () -> Void) in DispatchQueue.main.async(execute: body) }
        var actions = SiteControlsModel.Actions(
            copyURL: { [weak self] in self?.copyURL(nil) },
            share: { view in NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY) },
            toggleAdblock: { [weak self] in self?.toggleAdblockForSite(nil) },
            clearCache: { [weak self] in self?.clearCacheAndRefresh(nil) },
            clearCookies: { [weak self] in self?.clearCookiesAndRefresh(nil) },
            setPermission: { [weak self] permission, value in self?.shownPage?.setSitePermission(permission, value, for: url) },
            removeMailHandler: { MailHandlers.shared.remove(host: url.host) },
            toggleDeveloperMode: { [weak self] in self?.store.mutate { $0.toggleDeveloperMode(for: url) } },
            openSiteSettings: { [weak self] in self?.openSiteSettings(for: url) },
            newBoost: { [weak self] in self?.newBoost(nil) },
            editBoost: { [weak self] id in self?.editSiteBoost(id) },
            setBoostEnabled: { id, enabled in BoostsModel.shared.setEnabled(id, enabled) },
            manageBoosts: { [weak self] in self?.viewBoosts(nil) }
        )
        actions.capture = { later { [weak self] in self?.capturePage(nil) } }
        actions.captureFullPage = { later { [weak self] in self?.captureFullPage(nil) } }
        actions.capturePortraitMode = { later { [weak self] in self?.capturePortraitMode(nil) } }
        #if canImport(CEFBridge)
        let extensions = isIncognito ? nil : extensionsSelection?.model
        if let extensions {
            addExtensionActions(to: &actions, model: extensions, anchor: anchor)
            extensions.refresh()
        }
        #endif
        let siteControls = SiteControlsModel(url: url, actions: actions) { [weak self] model in
            guard let self else { return }
            let url = model.url
            model.blocksAds = Adblocker.isAvailable ? store.state.blocksAds(on: url) : nil
            model.isMailHandler = MailHandlers.shared.isDefault(host: url.host) ? true : nil
            model.isInDeveloperMode = store.state.isInDeveloperMode(url)
            // Nil hides the Boost parts: incognito, no site, or Boosts off in Settings.
            model.boosts = isIncognito || !BoostsModel.shared.isOn || BoostLibrary.domain(of: url) == nil
                ? nil : BoostsModel.shared.library.boosts(for: url)
            if let page = shownPage, page.sitePermission(.camera, for: url) != nil {
                var values: [SitePermission: SitePermissionValue] = [:]
                for permission in SitePermission.allCases {
                    values[permission] = page.sitePermission(permission, for: url)
                }
                model.permissions = values
            } else {
                model.permissions = nil
            }
            model.captureEnabled = shownPage != nil
            #if canImport(CEFBridge)
            if let extensions = isIncognito ? nil : extensionsSelection?.model {
                // Arc lists its toolbar actions, which Chromium keeps for extensions that are on.
                model.extensions = extensions.extensions.filter(\.enabled)
                model.pinnedExtensionIDs = extensions.pinnedIDs
            } else {
                model.extensions = nil
            }
            #endif
        }
        #if canImport(CEFBridge)
        // The list arrives from Chromium after the popover opens; pins change from the tiles.
        if let extensions {
            siteControls.subscriptions.append(extensions.objectWillChange.sink { [weak siteControls] _ in
                DispatchQueue.main.async { siteControls?.refresh() }
            })
        }
        #endif
        return siteControls
    }

    #if canImport(CEFBridge)
    /// The Extensions section's actions, through the window's extensions model. Popups and the
    /// extensions popover hang from the button that opened Site Controls, which outlives it.
    private func addExtensionActions(to actions: inout SiteControlsModel.Actions, model: ExtensionsModel, anchor: NSView) {
        actions.openExtension = { [weak anchor] item in
            guard let anchor, let url = item.popupURL ?? item.optionsURL else { return }
            DispatchQueue.main.async { ExtensionPopover.show(url, engine: model.engine, relativeTo: anchor.bounds, of: anchor) }
        }
        actions.setExtensionPinned = { id, pinned in model.setPinned(id, pinned) }
        actions.setExtensionEnabled = { id, enabled in model.setEnabled(id, enabled) }
        actions.openExtensionOptions = { item in
            guard let options = item.optionsURL else { return }
            NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: options as NSURL)
        }
        actions.removeExtension = { id in model.remove(id) }
        actions.manageExtensions = { [weak anchor] in
            guard let anchor else { return }
            DispatchQueue.main.async { ExtensionsMenu.present(model: model, from: anchor) }
        }
        actions.addExtension = {
            guard let url = URL(string: "https://chromewebstore.google.com/") else { return }
            NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: url as NSURL)
        }
    }
    #endif

    /// A Boost row's edit button: the Boost in its editor, refreshing the current tab.
    private func editSiteBoost(_ id: UUID) {
        guard let tabID = store.state.selectedTab?.id else { return }
        BoostEditorWindowController.show(id, refresh: { [weak self] in self?.pool.loadedPage(tabID)?.reload() }, browser: self)
    }

    /// Site Controls' "All Site Settings…" (and its Settings header): the site's settings page in a
    /// new tab. Arc opens Chromium's site details page for the site (`arc://settings/content/
    /// siteDetails?site=<URL>`); Kite's is its own page, kite://site-settings.
    func openSiteSettings(for url: URL) {
        guard let page = InternalPage.siteSettingsURL(for: url) else { return NSSound.beep() }
        store.mutate { state in
            let id = state.openTab(url: page)
            state.update(tab: id) { $0.title = InternalPage.siteSettings.title }
        }
    }
}
