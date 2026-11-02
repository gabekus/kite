import Foundation

/// Quiet VPN sign-in: when a VPN client (OpenVPN Connect, Tunnelblick) reconnects with web
/// sign-in (SSO, SAML), it opens the sign-in page in the default browser. For a page on a
/// watched host, Kite loads it in a hidden page with the user's own cookies instead of a tab,
/// and closes it once the sign-in goes through. Only when the page needs the user (a password,
/// a code, an MFA prompt to approve) does it become a background tab, without taking focus.
///
/// The decisions live here so they can be tested; KiteMac's VPNSignInController drives the page.
public enum VPNSignIn {
    /// The hosts whose pages Kite handles quietly, as `watch` saved them. Empty by default:
    /// Kite never guesses which links are VPN sign-ins.
    public static let hostsKey = "vpnSignInHosts"

    /// How long a quiet sign-in gets before Kite shows it to the user.
    public static let timeout: TimeInterval = 45
    /// A page that stops on another site (the company login) with nothing to type for this
    /// long is waiting for the user: an Okta Verify push or number to match, a consent button.
    public static let idleOnOtherSite: TimeInterval = 10
    /// The page must stay put this long on the VPN's own site before it counts as done.
    public static let settle: TimeInterval = 1.5
    public static let pollInterval: TimeInterval = 0.5
    /// Hosts of links from other apps Kite remembers (in memory only) so `status` can show
    /// which one a VPN client opened.
    public static let recentLimit = 10

    public static func hosts(in defaults: UserDefaults) -> [String] {
        (defaults.stringArray(forKey: hostsKey) ?? []).compactMap(normalize)
    }

    public static func setHosts(_ hosts: [String], in defaults: UserDefaults) {
        var seen = Set<String>()
        let cleaned = hosts.compactMap(normalize).filter { seen.insert($0).inserted }
        if cleaned.isEmpty { defaults.removeObject(forKey: hostsKey) } else { defaults.set(cleaned, forKey: hostsKey) }
    }

    /// "https://VPN.example.com/saml?x" or "vpn.example.com." → "vpn.example.com". nil for nothing usable.
    public static func normalize(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: text)?.host(), text.contains("://") { text = host }
        text = String(text.split(separator: "/").first ?? "")
        if let colon = text.firstIndex(of: ":"), !text.hasPrefix("[") { text = String(text[..<colon]) }
        while text.hasSuffix(".") { text.removeLast() }
        while text.hasPrefix("*.") || text.hasPrefix(".") { text.removeFirst(text.hasPrefix("*.") ? 2 : 1) }
        guard !text.isEmpty, !text.contains(" "), text.contains(".") || text == "localhost" else { return nil }
        return text
    }

    /// A web link on a watched host or one of its subdomains.
    public static func matches(_ url: URL, hosts: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// What the hidden page shows on one look, as `probeScript` reports it.
    public struct Look: Equatable, Sendable {
        public var url: URL?
        public var isLoading: Bool
        public var probe: SignInHandoff.Probe?
        public var title: String?

        public init(url: URL?, isLoading: Bool, probe: SignInHandoff.Probe?, title: String? = nil) {
            self.url = url
            self.isLoading = isLoading
            self.probe = probe
            self.title = title
        }
    }

    /// What to do after a look.
    public enum Step: Equatable, Sendable {
        case wait
        /// The sign-in went through: close the hidden page.
        case done
        /// Show the page to the user, for this reason.
        case needsUser(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        /// A password, code, email or username field.
        case asksForInput = "it asks for a password, code or account"
        /// Stopped on another site with nothing to type: an MFA push or a button to press.
        case waitingOnOtherSite = "it's waiting on the sign-in page (an MFA prompt or a button)"
        case tookTooLong = "it didn't finish in time"
    }

    /// One sign-in in progress: where it started and how the page has moved since.
    public struct Run: Sendable {
        public let start: URL
        public let hosts: [String]
        public let startedAt: Date
        public private(set) var lastKey: String
        public private(set) var lastChange: Date
        /// The page went through another site (the company's login) on the way.
        public private(set) var leftVPNSite = false

        public init(start: URL, hosts: [String], now: Date = Date()) {
            self.start = start
            self.hosts = hosts
            startedAt = now
            lastKey = SignInHandoff.pageKey(start)
            lastChange = now
        }

        /// Takes in a look at the page and says what to do.
        public mutating func step(_ look: Look, now: Date = Date()) -> Step {
            let key = SignInHandoff.pageKey(look.url)
            if key != lastKey, look.url != nil {
                lastKey = key
                lastChange = now
            }
            let onVPNSite = look.url.map { VPNSignIn.matches($0, hosts: hosts) || VPNSignIn.isLoopback($0) } ?? false
            if look.url != nil, !onVPNSite { leftVPNSite = true }
            if look.probe?.looksLikeLogin == true, !look.isLoading { return .needsUser(.asksForInput) }
            if now.timeIntervalSince(startedAt) >= VPNSignIn.timeout { return .needsUser(.tookTooLong) }
            guard !look.isLoading, look.probe != nil else { return .wait }
            let still = now.timeIntervalSince(lastChange)
            if onVPNSite {
                // Back on the VPN's site after the company login, or moved on from the page it opened on.
                let moved = leftVPNSite || key != SignInHandoff.pageKey(start)
                return moved && still >= VPNSignIn.settle ? .done : .wait
            }
            return still >= VPNSignIn.idleOnOtherSite ? .needsUser(.waitingOnOtherSite) : .wait
        }
    }

    /// OpenVPN Connect and openvpn's web auth can finish on a local page of the client.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Reads the page's URL and `SignInHandoff.probeScript`'s field counts together. Values are never read.
    public static let probeScript = """
        JSON.stringify({ href: location.href, title: document.title, fields: JSON.parse(\(SignInHandoff.probeScript)) })
        """

    public static func look(fromProbe value: Any?, isLoading: Bool) -> Look {
        guard let json = value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return Look(url: nil, isLoading: isLoading, probe: nil)
        }
        let probe = (object["fields"] as? [String: Any]).flatMap { fields -> SignInHandoff.Probe? in
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
            return SignInHandoff.Probe(json: String(decoding: data, as: UTF8.self))
        }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Look(url: (object["href"] as? String).flatMap(URL.init(string:)), isLoading: isLoading, probe: probe, title: title)
    }

    /// How the last quiet sign-in ended, for `status` and `wait`.
    public struct Outcome: Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case running
            case signedIn
            /// Shown to the user as a background tab.
            case shown(Reason)
        }

        public var host: String
        public var startedAt: Date
        public var finishedAt: Date?
        public var result: Result

        public init(host: String, startedAt: Date, finishedAt: Date? = nil, result: Result) {
            self.host = host
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.result = result
        }

        public var summary: String {
            let seconds = finishedAt.map { String(format: " in %.1f s", $0.timeIntervalSince(startedAt)) } ?? ""
            switch result {
            case .running: return "A sign-in on \(host) is running (started \(Self.time(startedAt)))."
            case .signedIn: return "Signed in quietly on \(host)\(seconds), at \(Self.time(startedAt))."
            case .shown(let reason):
                return "The sign-in on \(host) (\(Self.time(startedAt))) was opened as a background tab because \(reason.rawValue)."
            }
        }

        static func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
    }

    /// The `vpn` tool's report.
    public static func statusReport(hosts: [String], recent: [String], last: Outcome?, isOn: Bool) -> String {
        var lines: [String] = []
        if hosts.isEmpty {
            lines.append("Kite isn't watching any VPN sign-in hosts, so every sign-in page opens as a normal tab.")
            lines.append("Add the host the VPN client opens with {\"action\":\"watch\",\"host\":\"vpn.example.com\"}.")
        } else {
            lines.append("Quiet VPN sign-in for: \(hosts.joined(separator: ", ")).")
        }
        if !isOn { lines.append("Kite's window isn't up yet, so links aren't being handled.") }
        if let last { lines.append("Last: \(last.summary)") }
        let unwatched = recent.filter { host in !hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
        if !unwatched.isEmpty {
            lines.append("Links other apps opened in Kite lately (newest first): \(unwatched.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// Adds `host` to the front of `recent`, without repeats.
    public static func remember(_ host: String, in recent: [String]) -> [String] {
        Array(([host] + recent.filter { $0 != host }).prefix(recentLimit))
    }
}
