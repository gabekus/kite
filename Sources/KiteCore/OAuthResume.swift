import Foundation

/// OAuth sign-ins that lose their request on the way back from a login page.
///
/// `claude auth login` opens claude.ai's `/oauth/authorize?client_id=…&code_challenge=…&state=…`. In a
/// profile that isn't signed in to claude.ai, the page sends you to its login (with the request in
/// `returnTo`), then to Google or the company SSO, and comes back to `/oauth/authorize` without the
/// parameters: "Missing code_challenge parameter". Signed in, the same link works.
///
/// So, per tab: remember the last authorize request (path ending in `/authorize`, carrying a
/// `code_challenge`, or `client_id`, `redirect_uri` and `state`). When that tab comes back to the same
/// origin and path without them, within 10 minutes and after a sign-in page, load the remembered request
/// once. Anything else is left alone.
///
/// Only on Claude's own hosts (`resumableHosts`): the lost parameters are claude.ai's bug, and other
/// sites' OAuth flows, an IdP's `/oauth2/…` pages included, must never be replayed. A request read from a
/// login page's `returnTo` sends the user only where claude.ai's own login would have sent them, to its
/// authorize page, which still asks them to approve; it opens nothing a plain link couldn't.
///
/// The decisions live here so they can be tested; KiteMac's `OAuthResumeTracker` feeds it the URLs
/// each page reports, on both engines.
public struct OAuthResume: Sendable {
    /// How long a remembered request is kept.
    public static let window: TimeInterval = 10 * 60

    struct Pending: Sendable {
        var request: URL
        var since: Date
        /// The tab has been on a sign-in page since the request.
        var passedSignIn: Bool
    }

    private var pending: [UUID: Pending] = [:]
    /// Requests already loaded again, so a site that drops them a second time doesn't loop.
    private var resumed: [UUID: (request: URL, at: Date)] = [:]

    public init() {}

    /// Called with each URL a tab reports. Returns the request to load in that tab, at most once per request.
    public mutating func observe(_ url: URL?, tab: UUID, now: Date = Date()) -> URL? {
        if let entry = pending[tab], now.timeIntervalSince(entry.since) > Self.window { pending[tab] = nil }
        if let entry = resumed[tab], now.timeIntervalSince(entry.at) > Self.window { resumed[tab] = nil }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }

        if Self.isAuthorizeRequest(url) {
            remember(url, tab: tab, now: now, passedSignIn: false)
            return nil
        }
        // A login page that carries the request back (claude.ai/login?returnTo=/oauth/authorize?…).
        if Self.isSignInPage(url), let request = Self.returnedRequest(in: url) {
            remember(request, tab: tab, now: now, passedSignIn: true)
            return nil
        }
        guard var entry = pending[tab] else { return nil }
        if Self.sameEndpoint(url, entry.request) {
            guard entry.passedSignIn, Self.dropsParameters(url, of: entry.request) else { return nil }
            pending[tab] = nil
            resumed[tab] = (entry.request, now)
            return entry.request
        }
        if Self.isSignInPage(url) {
            entry.passedSignIn = true
            pending[tab] = entry
        } else if let redirect = Self.redirectURI(of: entry.request), Self.sameEndpoint(url, redirect) {
            // The sign-in finished: the request reached its redirect URI.
            pending[tab] = nil
        }
        return nil
    }

    public mutating func forget(tab: UUID) {
        pending[tab] = nil
        resumed[tab] = nil
    }

    private mutating func remember(_ request: URL, tab: UUID, now: Date, passedSignIn: Bool) {
        if resumed[tab]?.request == request { return }
        if var entry = pending[tab], entry.request == request {
            entry.passedSignIn = entry.passedSignIn || passedSignIn
            pending[tab] = entry
            return
        }
        pending[tab] = Pending(request: request, since: now, passedSignIn: passedSignIn)
    }

    // MARK: Recognizing the pages

    /// The hosts whose authorize requests Kite remembers, with their subdomains.
    static let resumableHosts = ["claude.ai", "claude.com"]

    static func isResumableHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return resumableHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A Claude OAuth authorize URL that still has its request.
    public static func isAuthorizeRequest(_ url: URL) -> Bool {
        guard isResumableHost(url), let path = normalizedPath(url), path.hasSuffix("/authorize") else { return false }
        let items = query(url)
        if items["code_challenge"] != nil { return true }
        return ["client_id", "redirect_uri", "state"].allSatisfy { items[$0] != nil }
    }

    /// The parameters whose loss breaks the request: the PKCE challenge, or the client's identity.
    static func keyParameters(of request: URL) -> [String] {
        query(request)["code_challenge"] != nil ? ["code_challenge"] : ["client_id", "redirect_uri", "state"]
    }

    /// `url` is the request's page without one of the parameters that make it a request.
    public static func dropsParameters(_ url: URL, of request: URL) -> Bool {
        let items = query(url)
        return keyParameters(of: request).contains { items[$0] == nil }
    }

    /// Identity providers' hosts, and words in a path that mean a login page.
    static let signInHosts = ["accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com",
                              "okta.com", "oktapreview.com", "auth0.com", "onelogin.com", "duosecurity.com",
                              "jumpcloud.com", "pingone.com", "login.salesforce.com"]
    static let signInPathWords = ["login", "signin", "sign-in", "sign_in", "logon", "sso", "saml", "oauth2", "openid",
                                  "magic-link", "magic_link", "verify", "mfa", "2fa"]

    /// A page on the way through a sign-in: an identity provider, or a login, SSO or verification path.
    public static func isSignInPage(_ url: URL) -> Bool {
        if let host = url.host()?.lowercased(), signInHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        guard let path = normalizedPath(url) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains { part in signInPathWords.contains(part) || part.hasPrefix("login") || part.hasPrefix("signin") }
    }

    /// Where login pages keep the page to go back to.
    static let returnParameters = ["returnTo", "return_to", "returnUrl", "return_url", "redirect", "redirect_to",
                                   "next", "continue", "callbackUrl"]

    /// The authorize request a login page will go back to, on the login page's own host.
    static func returnedRequest(in url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var candidates: [String] = []
        for name in returnParameters {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value { candidates.append(value) }
            // An unencoded returnTo swallows the rest of the query: `returnTo=/oauth/authorize?a=1&b=2`.
            if let raw = components.percentEncodedQuery.map({ "&" + $0 }), let range = raw.range(of: "&" + name + "=") {
                let rest = String(raw[range.upperBound...])
                candidates.append(rest.removingPercentEncoding ?? rest)
            }
        }
        // An unencoded returnTo shows up twice, cut short at its first `&` and whole. The short one can still
        // look like a request (`?code_challenge=…` alone), so keep the candidate with the most parameters.
        var best: URL?
        for candidate in candidates {
            guard let target = URL(string: candidate, relativeTo: url)?.absoluteURL,
                  target.host()?.lowercased() == url.host()?.lowercased(), isAuthorizeRequest(target) else { continue }
            if best.map({ query(target).count > query($0).count }) ?? true { best = target }
        }
        return best
    }

    static func redirectURI(of request: URL) -> URL? {
        query(request)["redirect_uri"].flatMap(URL.init(string:))
    }

    /// Same scheme, host, port and path (a trailing slash aside).
    static func sameEndpoint(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && a.port == b.port && normalizedPath(a) == normalizedPath(b)
    }

    static func normalizedPath(_ url: URL) -> String? {
        var path = url.path().lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// Non-empty query values by name (the first of each).
    static func query(_ url: URL) -> [String: String] {
        var items: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value, !value.isEmpty, items[item.name] == nil { items[item.name] = value }
        }
        return items
    }
}
