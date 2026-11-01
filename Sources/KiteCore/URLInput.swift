import Foundation

public enum SearchEngine: String, Hashable, Codable, CaseIterable, Sendable {
    case google
    case duckDuckGo
    case kagi
    case bing

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .bing: "Bing"
        }
    }

    private var template: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .kagi: "https://kagi.com/search?q="
        case .bing: "https://www.bing.com/search?q="
        }
    }

    public func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: URLInput.unreserved) ?? query
        return URL(string: template + encoded)!
    }
}

/// Turns whatever was typed into the command bar into a URL to load.
public enum URLInput {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let knownSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "view-source", "mailto"]

    public static func resolve(_ input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = explicitURL(text) { return url }
        if let url = hostLikeURL(text) { return url }
        return engine.searchURL(for: text)
    }

    /// What was typed as a URL, or nil when it would be a search (Arc's "Enter a URL…" fields).
    public static func url(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicitURL(text) ?? hostLikeURL(text)
    }

    public static func looksLikeURL(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicitURL(text) != nil || hostLikeURL(text) != nil
    }

    private static func explicitURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), knownSchemes.contains(scheme) else {
            return nil
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(), !host.isEmpty else { return nil }
        }
        return url
    }

    private static func hostLikeURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let hostAndPort = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let parts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first?.lowercased(), !host.isEmpty else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return nil }
        }

        let scheme: String
        if host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host) {
            scheme = "http"
        } else if isDomain(host) {
            scheme = "https"
        } else {
            return nil
        }
        return URL(string: "\(scheme)://\(text)")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }

    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last else { return false }
        let labelsOK = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let tldOK = (tld.count >= 2 && tld.allSatisfy(\.isLetter)) || tld.hasPrefix("xn--")
        return labelsOK && tldOK
    }
}
