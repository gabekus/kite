import Foundation

/// Arc's cookies (its sign-ins), for Import from Arc's "Sign-ins" option. Delete with
/// ArcImport.swift once Arc has shut down.
///
/// Arc keeps them as Chromium does on the Mac: each profile's `Cookies` SQLite database, a row
/// per cookie, with the value in `encrypted_value` as "v10" + AES-128-CBC ciphertext (key:
/// PBKDF2-SHA1 of the "Arc Safe Storage" keychain password, salt "saltysalt", 1003 rounds; IV: 16
/// spaces). From database version 24 the plaintext starts with the SHA-256 of the cookie's host,
/// 32 bytes. The shell reads the rows and does the crypto (CommonCrypto); this decides what
/// each row becomes.
public enum ArcCookieImport {
    /// One row of the `cookies` table.
    public struct Row: Equatable, Sendable {
        public var host: String
        public var name: String
        public var value: String
        public var encryptedValue: Data
        public var path: String
        /// Microseconds since 1601-01-01 UTC; 0 for a session cookie.
        public var expiresUTC: Int64
        public var isSecure: Bool
        public var isHTTPOnly: Bool
        /// Chromium's: -1 unspecified, 0 none, 1 lax, 2 strict.
        public var sameSite: Int
        /// Chromium's: 0 low, 1 medium, 2 high.
        public var priority: Int
        /// The scheme that set it: 0 unset, 1 non-secure, 2 secure.
        public var sourceScheme: Int = 0
        /// The port that set it; -1 when unknown.
        public var sourcePort: Int = -1
        /// The top-level site of a partitioned (CHIPS) cookie; empty for an ordinary one.
        public var topFrameSiteKey: String = ""

        public init(host: String, name: String, value: String = "", encryptedValue: Data = Data(), path: String,
                    expiresUTC: Int64, isSecure: Bool, isHTTPOnly: Bool, sameSite: Int, priority: Int) {
            self.host = host
            self.name = name
            self.value = value
            self.encryptedValue = encryptedValue
            self.path = path
            self.expiresUTC = expiresUTC
            self.isSecure = isSecure
            self.isHTTPOnly = isHTTPOnly
            self.sameSite = sameSite
            self.priority = priority
        }
    }

    /// A cookie ready to set in a Kite profile.
    public struct Cookie: Equatable, Sendable {
        public var row: Row
        public var value: String

        /// The URL to set it for, as the site that set it: a domain cookie's host without its
        /// leading dot, https unless a non-secure page set it, and its port when that wasn't the
        /// scheme's own (Chromium can bind cookies to scheme and port).
        public var url: URL? {
            let host = row.host.hasPrefix(".") ? String(row.host.dropFirst()) : row.host
            var components = URLComponents()
            let secure = row.isSecure || row.sourceScheme != 1
            components.scheme = secure ? "https" : "http"
            components.host = host
            if row.sourcePort > 0, row.sourcePort != (secure ? 443 : 80) { components.port = row.sourcePort }
            components.path = row.path.isEmpty ? "/" : row.path
            return components.url
        }

        /// A domain cookie (leading dot) goes to the host and its subdomains; a host cookie only to its host.
        public var domain: String? { row.host.hasPrefix(".") ? row.host : nil }
    }

    static let encryptedPrefix = Data("v10".utf8)
    /// The SHA-256 of the host that Chromium puts before the value from database version 24.
    static let hostHashLength = 32

    /// The cookie for `row`, or nil when it has expired by `now`, is partitioned (CEF can't set
    /// a partition, and unpartitioned it would follow the user across sites), can't be decrypted,
    /// or isn't text. `decrypt` takes the ciphertext after "v10" and gives the plaintext;
    /// `hostHash` is SHA-256, which the plaintext must start with from database version 24.
    public static func cookie(from row: Row, databaseVersion: Int, now: Date,
                              decrypt: (Data) -> Data?, hostHash: (String) -> Data) -> Cookie? {
        if row.expiresUTC != 0, row.expiresUTC <= chromeTime(now) { return nil }
        if !row.topFrameSiteKey.isEmpty { return nil }
        if row.encryptedValue.isEmpty { return Cookie(row: row, value: row.value) }
        guard row.encryptedValue.starts(with: encryptedPrefix),
              var plain = decrypt(row.encryptedValue.dropFirst(encryptedPrefix.count))
        else { return nil }
        if databaseVersion >= 24 {
            // Chromium checks it too: a wrong key that slips past the padding check gives garbage here.
            guard plain.count >= hostHashLength, plain.prefix(hostHashLength) == hostHash(row.host) else { return nil }
            plain = plain.dropFirst(hostHashLength)
        }
        guard let value = String(data: plain, encoding: .utf8) else { return nil }
        return Cookie(row: row, value: value)
    }

    /// Microseconds since 1601-01-01 UTC, Chromium's (and CEF's) time.
    public static func chromeTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }
}
