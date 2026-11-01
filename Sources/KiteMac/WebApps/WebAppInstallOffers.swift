import AppKit
import KiteCore
import Observation

/// Which tabs show Chrome's install icon in the address field: after each page load Kite reads the
/// page's manifest link, fetches the manifest and applies Chrome's installability rules
/// (WebAppInstallability.isPromotable), hiding the icon for apps already installed, as Chrome does
/// (PwaInstallPageActionController::UpdateVisibility, chrome/browser/ui/web_applications/pwa_install_page_action.cc).
@MainActor
@Observable
final class WebAppInstallOffers {
    static let shared = WebAppInstallOffers()

    struct Offer: Equatable {
        /// The manifest's name (else short_name), for the tooltip "Install <name>".
        let name: String
        let documentURL: URL
        let appID: String
    }

    private(set) var offers: [UUID: Offer] = [:]
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    /// Answers whether an app id is installed (WebAppsController).
    @ObservationIgnored var isInstalled: (String) -> Bool = { _ in false }

    func offer(for tab: UUID?) -> Offer? { tab.flatMap { offers[$0] } }

    /// The tab's page finished loading: checks it again.
    func check(tab: UUID, page: WebPage) {
        let generation = (generations[tab] ?? 0) + 1
        generations[tab] = generation
        page.evaluateJavaScript(WebApps.pageInfoScript) { [weak self] result in
            guard let self else { return }
            guard let info = WebAppPageInfo.decode(result), info.manifestURL != nil, let documentURL = info.documentURL,
                  WebApps.isWeb(documentURL) else { return self.set(nil, for: tab, generation: generation) }
            Task { @MainActor in
                let manifest = await WebAppsController.fetchManifest(info)
                guard let manifest, WebAppInstallability.isPromotable(manifest),
                      !self.isInstalled(WebApps.appID(for: manifest.id)),
                      let name = manifest.name ?? manifest.shortName
                else { return self.set(nil, for: tab, generation: generation) }
                self.set(Offer(name: name, documentURL: documentURL, appID: WebApps.appID(for: manifest.id)), for: tab, generation: generation)
            }
        }
    }

    func clear(tab: UUID) {
        generations[tab] = (generations[tab] ?? 0) + 1
        if offers[tab] != nil { offers[tab] = nil }
    }

    /// Once an app is installed its icon goes from every tab (pages loaded later check again).
    func removeOffers(appID: String) {
        for (id, offer) in offers where offer.appID == appID { offers[id] = nil }
    }

    private func set(_ offer: Offer?, for tab: UUID, generation: Int) {
        guard generations[tab] == generation, offers[tab] != offer else { return }
        offers[tab] = offer
    }
}
