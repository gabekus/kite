import Foundation

/// What the reload button does on a site in Developer Mode. Arc's `DeveloperTabReloadSetting`
/// (in `BrowserNavigationButtonsFeature`) has these two cases, stored as `devModeReloadState`.
public enum DeveloperTabReloadSetting: String, Hashable, Codable, CaseIterable, Sendable {
    case reload
    /// Reload ignoring the cache (Arc's "Refresh (Ignore Cache)").
    case forceReload
}

extension BrowserState {
    /// The key Developer Mode is stored under: the URL's host, lowercased, without the port,
    /// so every port on localhost shares one switch. Nil for pages without a host.
    static func developerModeHost(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    public func isInDeveloperMode(_ url: URL?) -> Bool {
        Self.developerModeHost(for: url).map(developerModeEnabledForHosts.contains) ?? false
    }

    /// View › Developer › Turn on / Turn off Developer Mode for this site.
    public mutating func toggleDeveloperMode(for url: URL?) {
        guard let host = Self.developerModeHost(for: url) else { return }
        if developerModeEnabledForHosts.contains(host) {
            developerModeEnabledForHosts.remove(host)
        } else {
            developerModeEnabledForHosts.insert(host)
        }
    }

    /// The menu item's title, which flips like Arc's.
    public func developerModeMenuTitle(for url: URL?) -> String {
        isInDeveloperMode(url) ? "Turn off Developer Mode for this site" : "Turn on Developer Mode for this site"
    }

    /// What the reload button does for this page: always a plain reload outside Developer Mode.
    public func reloadSetting(for url: URL?) -> DeveloperTabReloadSetting {
        isInDeveloperMode(url) ? devModeReloadState : .reload
    }
}
