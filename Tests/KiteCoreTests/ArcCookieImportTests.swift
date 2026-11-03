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
    private static func encrypt(_ plain: Data) -> Data { Data("v10".utf8) + Data(plain.reversed()) }

    @Test func decryptsAndDropsTheHostHashFromVersion24() {
        let hash = Data(repeating: 7, count: 32)
        let row = Self.row(encrypted: Self.encrypt(hash + Data("abc".utf8)))
        #expect(ArcCookieImport.cookie(from: row, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt)?.value == "abc")
        let old = Self.row(encrypted: Self.encrypt(Data("abc".utf8)))
        #expect(ArcCookieImport.cookie(from: old, databaseVersion: 23, now: Self.now, decrypt: Self.decrypt)?.value == "abc")
        // Too short for the hash: not a cookie Kite can trust.
        #expect(ArcCookieImport.cookie(from: old, databaseVersion: 24, now: Self.now, decrypt: Self.decrypt) == nil)
    }

    @Test func leavesOutWhatItCantUse() {
        // Expired.
        #expect(ArcCookieImport.cookie(from: Self.row(value: "x", expires: 1), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt) == nil)
        // Another scheme, a failed decryption, or not text.
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Data("v11abc".utf8)), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt) == nil)
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Self.encrypt(Data("abc".utf8))), databaseVersion: 23, now: Self.now) { _ in nil } == nil)
        #expect(ArcCookieImport.cookie(from: Self.row(encrypted: Self.encrypt(Data([0xFF, 0xFE]))), databaseVersion: 23, now: Self.now, decrypt: Self.decrypt) == nil)
        // A session cookie and a plain value come over as they are.
        #expect(ArcCookieImport.cookie(from: Self.row(value: "plain", expires: 0), databaseVersion: 24, now: Self.now, decrypt: Self.decrypt)?.value == "plain")
    }

    @Test func urlAndDomain() {
        let domain = ArcCookieImport.Cookie(row: Self.row(host: ".example.com"), value: "v")
        #expect(domain.url?.absoluteString == "https://example.com/")
        #expect(domain.domain == ".example.com")
        let host = ArcCookieImport.Cookie(row: Self.row(host: "app.example.com", secure: false), value: "v")
        #expect(host.url?.absoluteString == "http://app.example.com/")
        #expect(host.domain == nil)
    }

    @Test func chromeTimeIsFrom1601() {
        #expect(ArcCookieImport.chromeTime(Date(timeIntervalSince1970: 0)) == 11_644_473_600_000_000)
    }
}
