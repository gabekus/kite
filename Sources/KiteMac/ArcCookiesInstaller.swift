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

    /// Whether this run may bring sign-ins: a real profile that keeps its own cookies encrypted
    /// with the login keychain, or a test build reading a hand-made Arc folder (`isTest`). Never a
    /// test build reading the real Arc, whose sessions would land in a throwaway profile under
    /// Chromium's mock-keychain key.
    static var isAllowed: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil { return isTest }
        return environment["KITE_MOCK_KEYCHAIN"] != "1"
    }

    /// A test build with a hand-made Arc folder: the key comes from a file in it, never the keychain.
    static var isTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KITE_SUPPORT_PATH"] != nil && environment["KITE_ARC_DATA_PATH"] != nil
    }

    /// The key Arc encrypts cookies with: PBKDF2-SHA1 of its "Arc Safe Storage" keychain password.
    /// Reading it makes macOS ask the user, once. A test build (`isTest`) reads the password from
    /// `arc-safe-storage-test-password` in the Arc data folder instead.
    static func key(arcFolder: URL) throws -> Data {
        guard isAllowed else { throw Failure.noKey }
        var password: Data
        if isTest {
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
            // A buffer of Kite's own, so the wipe below clears it (best effort: the keychain's copy is freed, not cleared).
            password = data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
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
        password.resetBytes(in: 0..<password.count)
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

    /// One Arc profile's cookies that are still good, decrypted, and how many rows it had. The
    /// database can't be read (missing, or torn while Arc writes it): nil.
    static func read(profile: String, arcFolder: URL, key: Data, now: Date = Date()) -> (cookies: [ArcCookieImport.Cookie], rows: Int)? {
        var read = 0
        guard let cookies = readRows(profile: profile, arcFolder: arcFolder, key: key, now: now, count: &read) else { return nil }
        return (cookies, read)
    }

    private static func readRows(profile: String, arcFolder: URL, key: Data, now: Date, count read: inout Int) -> [ArcCookieImport.Cookie]? {
        let file = arcFolder.appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true).appendingPathComponent("Cookies")
        return try? BrowserHistoryImport.withCopy(file) { db -> [ArcCookieImport.Cookie] in
            var version = 0
            var meta: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &meta, nil) == SQLITE_OK,
               sqlite3_step(meta) == SQLITE_ROW, let text = sqlite3_column_text(meta, 0) {
                version = Int(String(cString: text)) ?? 0
            }
            sqlite3_finalize(meta)

            let sql = """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, priority,
                       source_scheme, source_port, top_frame_site_key
                FROM cookies
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadFailure.unknownSchema }
            defer { sqlite3_finalize(statement) }
            var cookies: [ArcCookieImport.Cookie] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
                let blob = sqlite3_column_blob(statement, 3)
                let encrypted = blob.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 3))) } ?? Data()
                var row = ArcCookieImport.Row(
                    host: text(0), name: text(1), value: text(2), encryptedValue: encrypted, path: text(4),
                    expiresUTC: sqlite3_column_int64(statement, 5),
                    isSecure: sqlite3_column_int(statement, 6) != 0, isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
                    sameSite: Int(sqlite3_column_int(statement, 8)), priority: Int(sqlite3_column_int(statement, 9))
                )
                row.sourceScheme = Int(sqlite3_column_int(statement, 10))
                row.sourcePort = Int(sqlite3_column_int(statement, 11))
                row.topFrameSiteKey = text(12)
                read += 1
                if let cookie = ArcCookieImport.cookie(from: row, databaseVersion: version, now: now,
                                                       decrypt: { decrypt($0, key: key) }, hostHash: sha256) {
                    cookies.append(cookie)
                }
            }
            return cookies
        }
    }

    enum ReadFailure: Error { case unknownSchema }

    static func sha256(_ text: String) -> Data {
        let data = Data(text.utf8)
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), out.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
        }
        return digest
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
