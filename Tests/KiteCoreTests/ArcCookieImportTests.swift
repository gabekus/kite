import Foundation
import Testing
@testable import KiteCore

@Suite struct ArcCookieImportTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let later = ArcCookieImport.chromeTime(now) + 1_000_000

    private static func row(host: String = ".example.com", value: String = "", encrypted: Data = Data(), expires: Int64 = later,
                            secure: Bool = true) -> ArcCookieImport.Row {
        .init(host: host, name: "sid", value: value, encryptedValue: encrypted, path: "/", expiresUTC: expires,
              isSecure: secure, isHTTPOnly: true, sameSite: 1, priority: 1)
    }

    /// Stands in for AES: the "ciphertext" is the plaintext reversed.
    private static func decrypt(_ data: Data) -> Data? { Data(data.reversed()) }
    /// Stands in for SHA-256: 32 bytes from the host.
    private static func hash(_ host: String) -> Data { Data((host + String(repeating: "#", count: 32)).utf8.prefix(32)) }
    private static func encrypt(_ plain: Data) -> Data { Data("v10".utf8) + Data(plain.reversed()) }

    @Test func decryptsAndDropsTheHostHashFromVersion24() {
        let row = Self.row(encrypted: Self.encrypt(Self.hash(".example.com") + Data("abc".utf8)))
        #expect(ArcCookieImport.cookie(from: row, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash)?.value == "abc")
        // Another host's hash: a wrong key or a tampered row.
        let wrong = Self.row(encrypted: Self.encrypt(Self.hash("other.com") + Data("abc".utf8)))
        #expect(ArcCookieImport.cookie(from: wrong, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
        let old = Self.row(encrypted: Self.encrypt(Data("abc".utf8)))
        #expect(ArcCookieImport.cookie(from: old, databaseVersion: 23, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash)?.value == "abc")
        // Too short for the hash: not a cookie Kite can trust.
        #expect(ArcCookieImport.cookie(from: old, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
    }

    @Test func leavesOutWhatItCantUse() {
        // Expired.
        #expect(ArcCookieImport.cookie(from: Self.row(value: "x", expires: 1), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
        // Another scheme, a failed decryption, or not text.
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Data("v11abc".utf8)), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Self.encrypt(Data("abc".utf8))), databaseVersion: 23, now: Self.now, decrypt: { _ in nil }, hostHash: Self.hash) == nil)
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Self.encrypt(Data([0xFF, 0xFE]))), databaseVersion: 23, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
        // A session cookie and a plain value come over as they are.
        #expect(ArcCookieImport.cookie(from: Self.row(value: "plain", expires: 0), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash)?.value == "plain")
    }

    @Test func partitionedCookiesStayBehind() {
        var row = Self.row(value: "x")
        row.topFrameSiteKey = "https://a.com"
        #expect(ArcCookieImport.cookie(from: row, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt, hostHash: Self.hash) == nil)
    }

    @Test func setForTheSchemeAndPortThatSetIt() {
        // Not Secure, but set by an https page.
        var row = Self.row(host: "app.example.com", secure: false)
        row.sourceScheme = 2
        row.sourcePort = 443
        #expect(ArcCookieImport.Cookie(row: row, value: "v").url?.absoluteString == "https://app.example.com/")
        row.sourceScheme = 1
        row.sourcePort = 8080
        #expect(ArcCookieImport.Cookie(row: row, value: "v").url?.absoluteString == "http://app.example.com:8080/")
    }

    @Test func urlAndDomain() {
        let domain = ArcCookieImport.Cookie(row: Self.row(host: ".example.com"), value: "v")
        #expect(domain.url?.absoluteString == "https://example.com/")
        #expect(domain.domain == ".example.com")
        var plain = Self.row(host: "app.example.com", secure: false)
        plain.sourceScheme = 1
        let host = ArcCookieImport.Cookie(row: plain, value: "v")
        #expect(host.url?.absoluteString == "http://app.example.com/")
        #expect(host.domain == nil)
    }

    @Test func chromeTimeIsFrom1601() {
        #expect(ArcCookieImport.chromeTime(Date(timeIntervalSince1970: 0)) == 11_644_473_600_000_000)
    }
}
