import Foundation

/// Arc's Chrome Web Store extensions, for Extensions › Add Extensions from Arc…. Delete with
/// ArcImport.swift once Arc has shut down.
///
/// Arc keeps them as Chromium does: each profile's `User Data/<profile>/Extensions/<id>/<version>/`
/// holds the unpacked extension, and the profile's `Secure Preferences` (or `Preferences`) has
/// `extensions.settings.<id>`, where `disable_reasons` marks one the user turned off. Kite can't copy
/// them in (Chromium verifies store installs), so it adds each from the store, where Chrome asks.
public enum ArcExtensionsImport {
    public struct Extension: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The Web Store's update URL, which every store-installed extension's manifest carries.
    static let storeUpdateHost = "clients2.google.com"

    /// One extension folder's manifest, or nil when it isn't from the Web Store (Arc's own,
    /// unpacked or from elsewhere). `messages` is the default locale's `messages.json`, for a
    /// name like `__MSG_appName__`.
    public static func storeExtension(id: String, manifest: Data, messages: (String) -> Data?) -> Extension? {
        guard ChromeWebStore.isExtensionID(id),
              let object = try? JSONSerialization.jsonObject(with: ExtensionManifest.strippingBOM(manifest)) as? [String: Any],
              let update = (object["update_url"] as? String).flatMap(URL.init(string:)),
              update.host == storeUpdateHost
        else { return nil }
        var name = object["name"] as? String ?? id
        if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            // Message keys are case-insensitive. Without the message, the id beats the placeholder.
            let key = String(name.dropFirst(6).dropLast(2)).lowercased()
            let table = (object["default_locale"] as? String).flatMap(messages).flatMap {
                try? JSONSerialization.jsonObject(with: ExtensionManifest.strippingBOM($0)) as? [String: Any]
            }
            let entry = table?.first { $0.key.lowercased() == key }?.value as? [String: Any]
            name = entry?["message"] as? String ?? id
        }
        return Extension(id: id, name: name.isEmpty ? id : name)
    }

    /// Extensions the user turned off in Arc, from the profile's preferences files.
    public static func disabledIDs(preferences: [Data]) -> Set<String> {
        var result: Set<String> = []
        for data in preferences {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any]
            else { continue }
            for (id, raw) in settings {
                let reasons = (raw as? [String: Any])?["disable_reasons"]
                if let list = reasons as? [Any], !list.isEmpty { result.insert(id) }
                if let bits = reasons as? Int, bits != 0 { result.insert(id) }
            }
        }
        return result
    }
}

extension BrowserState {
    /// The Arc profile folders an import put in Kite profile `directory`: Arc's Default for
    /// Kite's, and each one `arcProfileMap` sends there.
    public func arcProfiles(inKiteProfile directory: String) -> [String] {
        var result = directory == Profile.defaultDirectory ? [Profile.defaultDirectory] : []
        guard let store = profiles.first(where: { $0.directory == directory })?.dataStoreID else { return result }
        result += arcProfileMap.filter { $0.value == store }.keys.sorted()
        return result
    }
}
