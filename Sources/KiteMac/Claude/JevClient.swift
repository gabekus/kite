import Foundation
import KiteCore
import Security

/// Calls TypeSafe's Jev. The key lives in the login Keychain (service `dev.gabek.Kite.typesafe`),
/// or `TYPESAFE_API_KEY` for test builds. No key, no client: everything Jev speeds up still
/// works without it.
///
/// Only a team-signed Kite on a real profile reads the Keychain. The item trusts Kite by its
/// designated requirement and team ID, which stay the same across Developer ID updates, so
/// that Kite is asked at most once. An ad-hoc build gets a new code identity every time it's
/// compiled, and macOS shows each one a "Kite wants to use…" password prompt that looks just
/// like the installed app's; "Always Allow" only trusts that one build.
final class JevClient: Sendable {
    static let keychainService = "dev.gabek.Kite.typesafe"
    static let keychainAccount = "api-key"

    private let key: String
    /// Jev answers in well under a second; past this it's quicker to carry on without it.
    let timeout: TimeInterval

    init(key: String, timeout: TimeInterval = 1.5) {
        self.key = key
        self.timeout = timeout
    }

    static func fromKeychain() -> JevClient? {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["TYPESAFE_API_KEY"], !key.isEmpty { return JevClient(key: key) }
        guard environment["KITE_SUPPORT_PATH"] == nil, signingTeamID() != nil else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return JevClient(key: key)
    }

    /// The team ID Kite is signed with, or nil for ad-hoc and self-signed builds.
    static func signingTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func ask(state: String, questions: [String: Jev.Question]) async throws -> Jev.Answers {
        var request = URLRequest(url: Jev.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Jev.requestBody(state: state, questions: questions)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Jev.BadResponse(description: "Jev returned HTTP \(http.statusCode).")
        }
        return try Jev.answers(from: data)
    }
}
