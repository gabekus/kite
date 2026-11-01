import Foundation

/// Kite's Chromium sends `Origin: null` on requests from extension service workers and
/// pages, where Chrome sends `Origin: chrome-extension://<id>`. Some servers turn that
/// away: 1Password's (CloudFront) answer 503, so its extension couldn't load its account
/// from the 1Password app or reach its own services, and its popup sat on the logo.
/// Kite sets the header itself (DevTools Network.setExtraHTTPHeaders) for extension
/// workers (ExtensionTabsBridge) and pages (ChromiumPage).
enum ExtensionOrigin {
    /// `chrome-extension://<id>` for a URL inside an extension, else nil.
    static func origin(of url: String) -> String? {
        guard let url = URL(string: url) else { return nil }
        return origin(of: url)
    }

    static func origin(of url: URL) -> String? {
        guard url.scheme == "chrome-extension", let host = url.host, !host.isEmpty else { return nil }
        return "chrome-extension://\(host)"
    }
}
