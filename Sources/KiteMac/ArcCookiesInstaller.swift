#if canImport(CEFBridge)
import CEFBridge
import CommonCrypto
import Foundation
import KiteCore
import Security
import SQLite3

// Import from Arc's "Sign-ins": Arc's cookies, decrypted with Arc's key from the login keychain
// and set in the Kite profile each Arc profile went to. Delete with ArcImportController.swift
// once Arc has shut down.

enum ArcCookiesInstaller {
    enum Failure: Error, Equatable {
        /// The keychain had no "Arc Safe Storage" item, or the user didn't allow Kite to read it.
        case noKey
    }

    /// The key Arc encrypts cookies with: PBKDF2-SHA1 of its "Arc Safe Storage" keychain password.
    /// Reading it makes macOS ask the user, once. A test build (`KITE_TEST_IMPORT` with
    /// `KITE_ARC_DATA_PATH`) reads the password from `arc-safe-storage-test-password` in that
    /// folder instead and never touches the keychain.
    static func key(arcFolder: URL) throws -> Data {
        let password: Data
        if BrowserImportController.testMode != nil {
            guard let test = try? Data(contentsOf: arcFolder.appendingPathComponent("arc-safe-storage-test-password")) else {
                throw Failure.noKey
            }
            password = test
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Arc Safe Storage",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
                throw Failure.noKey
            }
            password = data
        }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.noKey }
        return key
    }

    /// AES-128-CBC with Chromium's IV of 16 spaces.
    static func decrypt(_ ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, ciphertext.count, outBytes.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// One Arc profile's cookies that are still good, decrypted.
    static func read(profile: String, arcFolder: URL, key: Data, now: Date = Date()) -> [ArcCookieImport.Cookie] {
        let file = arcFolder.appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true).appendingPathComponent("Cookies")
        return (try? BrowserHistoryImport.withCopy(file) { db -> [ArcCookieImport.Cookie] in
            var version = 0
            var meta: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &meta, nil) == SQLITE_OK,
               sqlite3_step(meta) == SQLITE_ROW, let text = sqlite3_column_text(meta, 0) {
                version = Int(String(cString: text)) ?? 0
            }
            sqlite3_finalize(meta)

            let sql = """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, priority
                FROM cookies
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var cookies: [ArcCookieImport.Cookie] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
                let blob = sqlite3_column_blob(statement, 3)
                let encrypted = blob.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 3))) } ?? Data()
                let row = ArcCookieImport.Row(
                    host: text(0), name: text(1), value: text(2), encryptedValue: encrypted, path: text(4),
                    expiresUTC: sqlite3_column_int64(statement, 5),
                    isSecure: sqlite3_column_int(statement, 6) != 0, isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
                    sameSite: Int(sqlite3_column_int(statement, 8)), priority: Int(sqlite3_column_int(statement, 9))
                )
                if let cookie = ArcCookieImport.cookie(from: row, databaseVersion: version, now: now, decrypt: { decrypt($0, key: key) }) {
                    cookies.append(cookie)
                }
            }
            return cookies
        }) ?? []
    }

    /// Sets `cookies` in Kite profile `directory`; `completion` gets how many went in.
    @MainActor
    static func set(_ cookies: [ArcCookieImport.Cookie], inProfile directory: String, completion: @escaping (Int) -> Void) {
        let items: [[String: Any]] = cookies.compactMap { cookie in
            guard let url = cookie.url else { return nil }
            var item: [String: Any] = [
                "url": url, "name": cookie.row.name, "value": cookie.value, "path": cookie.row.path,
                "secure": cookie.row.isSecure, "httpOnly": cookie.row.isHTTPOnly, "expires": cookie.row.expiresUTC,
                // Chromium's stored values to CEF's: same-site -1…2 is 0…3, priority 0…2 is -1…1.
                "sameSite": cookie.row.sameSite + 1, "priority": cookie.row.priority - 1,
            ]
            if let domain = cookie.domain { item["domain"] = domain }
            return item
        }
        KCRequestContext(profileDirectory: directory).setCookies(items) { completion($0) }
    }
}
#endif
