import Foundation

/// The Chrome Web Store: extension ids and the pages Kite installs from.
public enum ChromeWebStore {
    public static let host = "chromewebstore.google.com"

    /// Chrome's 32-letter ids, written with the letters a–p.
    public static func isExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The store page for an extension.
    public static func detailURL(for id: String) -> URL? {
        isExtensionID(id) ? URL(string: "https://\(host)/detail/\(id)") : nil
    }

    public static func isStorePage(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == host
    }

    /// The id in `https://chromewebstore.google.com/detail/[slug/]<id>`.
    public static func extensionID(fromDetailURL url: URL) -> String? {
        guard isStorePage(url) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.first == "detail", (2...3).contains(parts.count), let id = parts.last, isExtensionID(id) else { return nil }
        return id
    }
}

/// Google's search results pages, where Kite adds "Add to Kite" to store results.
public enum GoogleSearch {
    /// `https://google.<tld>/search` or `https://www.google.<tld>/search`, such as google.co.uk.
    public static func isResultsPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.path == "/search", let host = url.host?.lowercased() else { return false }
        var labels = host.split(separator: ".")
        if labels.first == "www" { labels.removeFirst() }
        guard labels.first == "google", labels.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return false }
        // google.de, or a country domain under co/com: google.co.uk, google.com.au.
        // Not any three labels: google.netlify.app is anyone's.
        switch labels.count {
        case 2: return labels[1].count >= 2
        case 3: return ["co", "com"].contains(labels[1]) && labels[2].count == 2
        default: return false
        }
    }
}

/// The packaged extension (.crx) a store install downloads. It isn't the user's file,
/// so it belongs in a temporary folder, not in Downloads or the downloads list.
public enum ExtensionPackage {
    public static let mimeType = "application/x-chrome-extension"

    public static func isDownload(mimeType: String, suggestedName: String, url: URL?) -> Bool {
        if mimeType.lowercased() == Self.mimeType { return true }
        guard suggestedName.lowercased().hasSuffix(".crx"), url?.scheme == "https",
              let host = url?.host?.lowercased() else { return false }
        return ["clients2.google.com", "clients2.googleusercontent.com"].contains(host) || host.hasSuffix(".gvt1.com")
    }
}
