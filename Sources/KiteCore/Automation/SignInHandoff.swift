import Foundation

/// `sign_in`: Claude hands a login page to the user, the user signs in (with their password manager,
/// or by hand), and Claude carries on, signed in. The password goes from the password manager into
/// the page and never through Claude: the tool's result says only whether the user
/// signed in and where the tab ended up.
///
/// While the user signs in, Kite refuses Claude's other tools on that tab, so nothing
/// can read the filled fields. If the user cancels (or doesn't finish in time) with the
/// login form still up, Kite empties its password and code fields before Claude gets the
/// tab back.
public enum SignInHandoff {
    /// How long Kite waits for the user before handing the tab back unfinished.
    public static let timeout: TimeInterval = 300
    /// How often Kite looks at the page while waiting.
    public static let pollInterval: TimeInterval = 0.5
    /// Probes in a row that must agree the sign-in is done, so a page mid-redirect doesn't count.
    public static let settledProbes = 2

    /// What the page shows right now, as `probeScript` reports it.
    public struct Probe: Codable, Equatable, Sendable {
        /// Visible password fields.
        public var passwords: Int
        /// Visible one-time-code fields (autocomplete="one-time-code", or named like one).
        public var codes: Int
        /// Visible email or username fields: the first step of an email-first login.
        public var identities: Int

        public init(passwords: Int, codes: Int, identities: Int = 0) {
            self.passwords = passwords
            self.codes = codes
            self.identities = identities
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            passwords = try c.decode(Int.self, forKey: .passwords)
            codes = try c.decode(Int.self, forKey: .codes)
            identities = try c.decodeIfPresent(Int.self, forKey: .identities) ?? 0
        }

        /// The page still asks for a secret.
        public var asksForSecret: Bool { passwords > 0 || codes > 0 }

        /// The page still looks like a step of a login: it asks for a secret or an account.
        public var looksLikeLogin: Bool { asksForSecret || identities > 0 }

        public init?(json: String) {
            guard let probe = try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) else { return nil }
            self = probe
        }
    }

    /// How a handoff ended.
    public enum Outcome: Equatable, Sendable {
        /// The page left the login form (or the user pressed Done).
        case signedIn
        /// The user pressed Cancel.
        case cancelled
        /// Nobody finished within `timeout`.
        case timedOut
    }

    /// The sign-in looks done: the tab is back on the site it started on, at a different
    /// page, and that page asks for no password, code, email or username.
    ///
    /// Leaving the site never counts: "Continue with Google", Apple or a company login
    /// goes through another site's pages (an account picker, a passkey prompt) that ask
    /// for none of those, and only coming back to the starting site means it worked.
    /// Anything Kite can't tell, the user ends with Done.
    public static func isFinished(start: URL?, now: URL?, probe: Probe) -> Bool {
        guard !probe.looksLikeLogin, let start, let now else { return false }
        guard let startSite = site(start.host()), startSite == site(now.host()) else { return false }
        return pageKey(start) != pageKey(now)
    }

    /// A host's site, roughly its registrable domain: the last two labels, or three for
    /// two-letter country domains with a short second level ("shop.example.co.uk" → "example.co.uk").
    static func site(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let keep = labels.last!.count == 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Scheme, host and path: a fragment or query change on the same login page isn't leaving it.
    static func pageKey(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        return "\(components.scheme ?? "")://\(components.host ?? "")\(components.path)"
    }

    /// Counts visible password and one-time-code fields in the top frame. Values are never read.
    public static let probeScript = """
        (() => {
          const shown = (el) => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
          };
          const inputs = [...document.querySelectorAll('input')].filter((el) => !el.disabled && shown(el));
          const code = /one-time-code|otp|2fa|mfa|totp|verification/i;
          const identity = /username|email|login|account|identifier/i;
          return JSON.stringify({
            passwords: inputs.filter((el) => el.type === 'password').length,
            codes: inputs.filter((el) => el.type !== 'password' && el.type !== 'hidden'
              && code.test([el.autocomplete, el.name, el.id].join(' '))).length,
            identities: inputs.filter((el) => el.type === 'email' || (['text', ''].includes(el.type)
              && identity.test([el.autocomplete, el.name, el.id].join(' ')))).length,
          });
        })()
        """

    /// Empties every password and one-time-code field in the top frame and tells the page,
    /// so a cancelled sign-in leaves nothing behind for Claude to read.
    public static let clearScript = """
        (() => {
          const code = /one-time-code|otp|2fa|mfa|totp|verification/i;
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          let cleared = 0;
          for (const el of document.querySelectorAll('input')) {
            const secret = el.type === 'password' || code.test([el.autocomplete, el.name, el.id].join(' '));
            if (!secret || el.value === '') continue;
            setter.call(el, '');
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            cleared += 1;
          }
          return cleared;
        })()
        """

    /// The tool's result. Says nothing about which account or what was filled.
    public static func report(_ outcome: Outcome, tab: UUID, url: URL?, title: String) -> String {
        let place = "Tab \(tab.uuidString) is now at \(url?.absoluteString ?? "an unknown URL") (“\(title)”)."
        switch outcome {
        case .signedIn:
            return "The user signed in. \(place) Read the page to carry on."
        case .cancelled:
            return "The user cancelled the sign-in. \(place) Don't try to sign in yourself or ask for a password: "
                + "tell the user what you couldn't do without signing in."
        case .timedOut:
            return "The user didn't sign in within \(Int(timeout / 60)) minutes. \(place) Don't try to sign in yourself: "
                + "say that the task needs them to sign in, and stop."
        }
    }

    /// Why Claude can't use a tab while the user signs in on it.
    public static let busyMessage = "The user is signing in on this tab. Wait for sign_in to return before using it."
}
