import CryptoKit
import Foundation

/// Chrome's extension ids: the first 16 bytes of the SHA-256 of the public key, each
/// nibble written as a letter a–p.
public enum ChromeExtensionID {
    public static func fromPublicKey(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { byte in
            String([Character(UnicodeScalar(97 + (byte >> 4))), Character(UnicodeScalar(97 + (byte & 15)))])
        }.joined()
    }
}

/// An installed extension as Kite's extensions list shows it.
public struct InstalledExtension: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Chromium refuses to disable some (policy-installed) extensions.
    public var mayDisable: Bool
    /// The toolbar popup, e.g. `chrome-extension://<id>/popup.html`.
    public var popupURL: URL?
    /// The icon file on disk, closest to the size asked for.
    public var iconFile: URL?
    public var optionsURL: URL?

    public init(id: String, name: String, enabled: Bool, mayDisable: Bool = true, popupURL: URL? = nil,
                iconFile: URL? = nil, optionsURL: URL? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.mayDisable = mayDisable
        self.popupURL = popupURL
        self.iconFile = iconFile
        self.optionsURL = optionsURL
    }
}

/// Kite's own helper extension (Resources/KiteHelperExtension): it lists and manages
/// extensions through chrome.management, and never appears in the list itself.
public enum KiteHelperExtension {
    /// From the public key in its manifest.
    public static let id = "kaoomgmkpckaljldplcclhdahmmjnhlo"
    public static let pagePath = "manage.html"
}

/// What Kite needs from an extension's manifest.json.
public struct ExtensionManifest: Equatable, Sendable {
    /// `action.default_popup` (MV3) or `browser_action.default_popup` (MV2), relative to the extension.
    public var popupPath: String?
    /// Icon paths by pixel size: the toolbar icon (`action.default_icon`), else `icons`.
    public var icons: [Int: String]

    public init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: Self.strippingBOM(data)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let action = (object["action"] ?? object["browser_action"]) as? [String: Any]
        let popup = (action?["default_popup"] as? String)?.trimmingCharacters(in: .whitespaces)
        popupPath = popup?.isEmpty == false ? popup : nil
        icons = Self.icons(action?["default_icon"]) ?? Self.icons(object["icons"]) ?? [:]
    }

    /// The icon closest to `size` pixels, preferring larger ones (they scale down cleanly).
    public func iconPath(forSize size: Int) -> String? {
        let sizes = icons.keys.sorted()
        guard let best = sizes.first(where: { $0 >= size }) ?? sizes.last else { return nil }
        return icons[best]
    }

    private static func icons(_ value: Any?) -> [Int: String]? {
        if let path = value as? String { return [16: path] }
        guard let dictionary = value as? [String: Any] else { return nil }
        var icons: [Int: String] = [:]
        for (key, path) in dictionary {
            if let size = Int(key), let path = path as? String { icons[size] = path }
        }
        return icons.isEmpty ? nil : icons
    }

    private static func strippingBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }
}

public enum InstalledExtensions {
    /// Each extension's folder, from Chromium's Secure Preferences
    /// (`extensions.settings.<id>.path`: absolute for unpacked ones, else relative to
    /// the profile's Extensions folder, as `<id>/<version>`).
    public static func folders(securePreferences data: Data, extensionsDirectory: URL) -> [String: URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = (object["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { return [:] }
        var folders: [String: URL] = [:]
        for (id, value) in settings {
            guard ChromeWebStore.isExtensionID(id), let path = (value as? [String: Any])?["path"] as? String, !path.isEmpty else { continue }
            folders[id] = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : extensionsDirectory.appendingPathComponent(path, isDirectory: true)
        }
        return folders
    }

    /// The list Kite shows: the helper's chrome.management.getAll() result (JSON), with
    /// popups and icons from each manifest. Themes, apps and Kite's helper are left out.
    public static func list(managementJSON: Data, folders: [String: URL], iconSize: Int = 32,
                            readManifest: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> [InstalledExtension] {
        guard let entries = try? JSONSerialization.jsonObject(with: managementJSON) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> InstalledExtension? in
            guard let id = entry["id"] as? String, ChromeWebStore.isExtensionID(id), id != KiteHelperExtension.id,
                  entry["type"] as? String == "extension" else { return nil }
            var item = InstalledExtension(
                id: id,
                name: entry["name"] as? String ?? id,
                enabled: entry["enabled"] as? Bool ?? false,
                mayDisable: entry["mayDisable"] as? Bool ?? true,
                optionsURL: (entry["optionsUrl"] as? String).flatMap(URL.init(string:))
            )
            if let folder = folders[id], let data = readManifest(folder.appendingPathComponent("manifest.json")),
               let manifest = try? ExtensionManifest(data: data) {
                item.popupURL = manifest.popupPath.flatMap { URL(string: "chrome-extension://\(id)/\($0.hasPrefix("/") ? String($0.dropFirst()) : $0)") }
                item.iconFile = manifest.iconPath(forSize: iconSize).map { folder.appendingPathComponent($0) }
            }
            return item
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
