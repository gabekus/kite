import Foundation
import KiteCore
import Security

/// Calls TypeSafe's Jev. The key lives in the login Keychain (service `dev.gabek.Kite.typesafe`),
/// or `TYPESAFE_API_KEY` for test builds. No key, no client: everything Jev speeds up still
/// works without it.
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
        if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty { return JevClient(key: key) }
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
