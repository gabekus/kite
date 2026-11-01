import Foundation

/// A web mail app that handles mailto: links, the way Arc does it: Arc 1.171 has no list of mail
/// services. A site (Gmail, Outlook, Fastmail…) calls `navigator.registerProtocolHandler("mailto",
/// "https://…?…=%s")`, Arc asks "Make <site> your default mail app?", and once allowed a mailto:
/// link loads that URL with the whole mailto: URL, percent-encoded, in place of `%s`
/// (docs/arc-visual-spec.md, "mailto: handling").
public struct MailHandler: Codable, Equatable, Hashable, Sendable {
    /// The handler's absolute http(s) URL, still holding its `%s`.
    public var template: String

    public init(template: String) {
        self.template = template
    }

    /// The handler's site, for the prompt and Site Controls.
    public var host: String? { URL(string: template.replacingOccurrences(of: "%s", with: ""))?.host }

    /// What `navigator.registerProtocolHandler(scheme, url)` from a page at `pageURL` registers, or nil when
    /// HTML's checks reject it: only the mailto scheme (Arc's prompt has no other case), a secure
    /// page, a URL holding `%s` that resolves (against the page) to http(s) on the page's own origin.
    public static func registration(scheme: String, url: String, pageURL: URL) -> MailHandler? {
        guard scheme.lowercased() == "mailto", isSecureContext(pageURL), url.contains("%s") else { return nil }
        // Foundation would percent-encode a bare `%s`; hold its place with plain letters while parsing.
        let placeholder = "kitemailtoplaceholder"
        guard !url.contains(placeholder),
              let resolved = URL(string: url.replacingOccurrences(of: "%s", with: placeholder), relativeTo: pageURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
              origin(of: resolved) == origin(of: pageURL)
        else { return nil }
        return MailHandler(template: resolved.absoluteString.replacingOccurrences(of: placeholder, with: "%s"))
    }

    /// The page a mailto: link opens: Chromium's ProtocolHandler::TranslateUrl puts the link's
    /// whole URL, query-escaped, in place of the first `%s`.
    public func translate(_ mailto: URL) -> URL? {
        guard Self.isMailto(mailto), let range = template.range(of: "%s") else { return nil }
        let spec = template.replacingCharacters(in: range, with: Self.escapeQueryParamValue(mailto.absoluteString))
        return URL(string: Self.encodingStrayPercents(spec))
    }

    /// Foundation re-encodes every `%` in a string holding one that starts no escape (a second `%s`),
    /// which would double-encode the link; encode just the stray ones.
    static func encodingStrayPercents(_ spec: String) -> String {
        let bytes = Array(spec.utf8)
        func isHex(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
        var out: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            out.append(byte)
            if byte == UInt8(ascii: "%"), !(index + 2 < bytes.count && isHex(bytes[index + 1]) && isHex(bytes[index + 2])) {
                out += Array("25".utf8)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func isMailto(_ url: URL) -> Bool { url.scheme?.lowercased() == "mailto" }

    /// Chromium's base::EscapeQueryParamValue(text, use_plus: true): everything but letters, digits
    /// and `!'()*-._~` is percent-encoded, and a space becomes `+`.
    public static func escapeQueryParamValue(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "!"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// registerProtocolHandler is [SecureContext]: https, or http on the loopback host.
    static func isSecureContext(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}

/// The profile's mail handler: the one allowed (Arc's prompt makes it *the* default mail app)
/// and the ones refused, which never ask again, as Chromium remembers ignored handlers.
public struct MailHandlerSettings: Codable, Equatable, Sendable {
    public var handler: MailHandler?
    public var blocked: [MailHandler]

    public init(handler: MailHandler? = nil, blocked: [MailHandler] = []) {
        self.handler = handler
        self.blocked = blocked
    }

    /// A site asks again on every visit; only a new, unrefused handler is worth a prompt.
    public func asks(for handler: MailHandler) -> Bool {
        handler != self.handler && !blocked.contains(handler)
    }

    public mutating func allow(_ handler: MailHandler) {
        self.handler = handler
        blocked.removeAll { $0 == handler }
    }

    public mutating func block(_ handler: MailHandler) {
        if self.handler == handler { self.handler = nil }
        if !blocked.contains(handler) { blocked.append(handler) }
    }

    /// Whether `host` is the default mail app (Site Controls shows the row then).
    public func isDefault(host: String?) -> Bool {
        guard let host, let current = handler?.host else { return false }
        return current.caseInsensitiveCompare(host) == .orderedSame
    }

    /// Site Controls → Default Mail App off: mailto: links go back to the system's mail app.
    public mutating func remove(host: String?) {
        if isDefault(host: host) { handler = nil }
    }

    /// Where a mailto: link goes: the handler's page, or nil for the system's mail app.
    public func destination(for url: URL) -> URL? {
        handler?.translate(url)
    }
}
