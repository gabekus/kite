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

    /// What a profile has, from its folder (`User Data/<profile>`): `available` can be added from
    /// the store; `unavailable` are Manifest V2, which Kite's Chromium no longer runs. Arc's own
    /// extensions live inside Arc.app, so they're never here.
    public struct Found: Equatable, Sendable {
        public var available: [Extension] = []
        public var unavailable: [Extension] = []

        public init() {}
    }

    /// Reads a profile folder: each `Extensions/<id>` folder's newest version with a manifest,
    /// leaving out ones the user turned off, ones the profile's settings don't list (left behind
    /// by an uninstall) and ones not from the store. Sorted by name.
    public static func read(profileFolder folder: URL) -> Found {
        let files = FileManager.default
        let settings = extensionSettings(preferences: ["Secure Preferences", "Preferences"].compactMap {
            try? Data(contentsOf: folder.appendingPathComponent($0))
        })
        let extensions = folder.appendingPathComponent("Extensions", isDirectory: true)
        var found = Found()
        for id in (try? files.contentsOfDirectory(atPath: extensions.path)) ?? [] {
            if let entry = settings[id] {
                if isTurnedOff(entry) { continue }
            } else if !settings.isEmpty {
                continue
            }
            let versions = ((try? files.contentsOfDirectory(atPath: extensions.appendingPathComponent(id).path)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in versions {
                let root = extensions.appendingPathComponent(id).appendingPathComponent(version, isDirectory: true)
                guard let manifest = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { continue }
                let item = storeExtension(id: id, manifest: manifest) { locale in
                    try? Data(contentsOf: root.appendingPathComponent("_locales/\(locale)/messages.json"))
                }
                if let item {
                    if item.manifestVersion < 3 { found.unavailable.append(item.extension) } else { found.available.append(item.extension) }
                }
                break
            }
        }
        let byName: (Extension, Extension) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        found.available.sort(by: byName)
        found.unavailable.sort(by: byName)
        return found
    }

    /// One extension folder's manifest, or nil when it isn't from the Web Store (unpacked or
    /// from elsewhere). `messages` gives a locale's `messages.json`, for a name like
    /// `__MSG_appName__`.
    static func storeExtension(id: String, manifest: Data, messages: (String) -> Data?) -> (extension: Extension, manifestVersion: Int)? {
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
        return (Extension(id: id, name: name.isEmpty ? id : name), object["manifest_version"] as? Int ?? 2)
    }

    /// `extensions.settings` by id; the first file listing an id wins, so pass Secure
    /// Preferences (the live one on the Mac) first.
    static func extensionSettings(preferences: [Data]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for data in preferences {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any]
            else { continue }
            for (id, raw) in settings where result[id] == nil {
                if let entry = raw as? [String: Any] { result[id] = entry }
            }
        }
        return result
    }

    /// Turned off by the user: Chromium's `disable_reasons` holds DISABLE_USER_ACTION (1), as a
    /// list of reasons or (older) a bit mask. Others, like a permissions increase (2), aren't the
    /// user's choice, so those still come over.
    static func isTurnedOff(_ entry: [String: Any]) -> Bool {
        if let list = entry["disable_reasons"] as? [Int] { return list.contains(1) }
        if let bits = entry["disable_reasons"] as? Int { return bits & 1 != 0 }
        return false
    }
}

extension BrowserState {
    /// The Arc profile folders whose extensions Kite profile `directory` is offered: Arc's
    /// Default for Kite's (imported or not), and each one an import put there (`arcProfileMap`).
    public func arcProfiles(inKiteProfile directory: String) -> [String] {
        var result = directory == Profile.defaultDirectory ? [Profile.defaultDirectory] : []
        guard let store = allProfiles.first(where: { $0.directory == directory })?.dataStoreID else { return result }
        result += arcProfileMap.filter { $0.value == store }.keys.sorted()
        return result
    }
}
