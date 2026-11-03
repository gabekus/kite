import Foundation
import Testing
@testable import KiteCore

@Suite struct ArcExtensionsImportTests {
    private static let store = "https://clients2.google.com/service/update2/crx"
    private static let id = String(repeating: "a", count: 32)

    private static func manifest(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    @Test func readsStoreExtensionsOnly() {
        let item = ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "Dark Reader", "update_url": Self.store, "manifest_version": 3])) { _ in nil }
        #expect(item?.extension == .init(id: Self.id, name: "Dark Reader"))
        #expect(item?.manifestVersion == 3)
        // Unpacked or from elsewhere: not from the store.
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "X"])) { _ in nil } == nil)
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "X", "update_url": "https://example.com/u"])) { _ in nil } == nil)
        #expect(ArcExtensionsImport.storeExtension(id: "not-an-id", manifest: Self.manifest(["name": "X", "update_url": Self.store])) { _ in nil } == nil)
    }

    @Test func namesFromTheDefaultLocale() {
        let manifest = Self.manifest(["name": "__MSG_appName__", "default_locale": "en", "update_url": Self.store])
        // With a byte order mark, as some extensions ship, and a key in another case.
        let messages = Data([0xEF, 0xBB, 0xBF]) + (try! JSONSerialization.data(withJSONObject: ["APPNAME": ["message": "Grammarly"]]))
        let item = ArcExtensionsImport.storeExtension(id: Self.id, manifest: manifest) { $0 == "en" ? messages : nil }
        #expect(item?.extension.name == "Grammarly")
        // No messages file: the id rather than the placeholder.
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: manifest) { _ in nil }?.extension.name == Self.id)
    }

    @Test func onlyTheUsersOwnChoiceTurnsOneOff() {
        #expect(ArcExtensionsImport.isTurnedOff(["disable_reasons": [1]]))
        #expect(ArcExtensionsImport.isTurnedOff(["disable_reasons": 8193]))
        // A permissions increase isn't the user's choice.
        #expect(!ArcExtensionsImport.isTurnedOff(["disable_reasons": [2]]))
        #expect(!ArcExtensionsImport.isTurnedOff(["disable_reasons": []]))
        #expect(!ArcExtensionsImport.isTurnedOff(["state": 1]))
    }

    @Test func securePreferencesWin() throws {
        let secure = try JSONSerialization.data(withJSONObject: ["extensions": ["settings": ["a": ["disable_reasons": []]]]])
        let stale = try JSONSerialization.data(withJSONObject: ["extensions": ["settings": ["a": ["disable_reasons": [1]], "b": [:]]]])
        let settings = ArcExtensionsImport.extensionSettings(preferences: [secure, stale, Data("x".utf8)])
        #expect(settings.keys.sorted() == ["a", "b"])
        #expect(!ArcExtensionsImport.isTurnedOff(settings["a"]!))
    }

    @Test func readsAProfileFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arc-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ id: String, _ version: String, _ fields: [String: Any]?) throws {
            let dir = folder.appendingPathComponent("Extensions/\(id)/\(version)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let fields { try Self.manifest(fields).write(to: dir.appendingPathComponent("manifest.json")) }
        }
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let c = String(repeating: "c", count: 32), d = String(repeating: "d", count: 32), e = String(repeating: "e", count: 32)
        // The newest version folder by number (1.10 after 1.9), skipping one with no manifest.
        try write(a, "1.9.0_0", ["name": "Old", "update_url": Self.store, "manifest_version": 3])
        try write(a, "1.10.0_0", ["name": "Zeta", "update_url": Self.store, "manifest_version": 3])
        try write(a, "2.0.0_0", nil)
        try write(b, "1_0", ["name": "Off", "update_url": Self.store, "manifest_version": 3])
        try write(c, "1_0", ["name": "uBlock", "update_url": Self.store, "manifest_version": 2])
        try write(d, "1_0", ["name": "Alpha", "update_url": Self.store, "manifest_version": 3])
        // Left behind by an uninstall: not in the settings.
        try write(e, "1_0", ["name": "Gone", "update_url": Self.store, "manifest_version": 3])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Extensions/Temp"), withIntermediateDirectories: true)
        let settings: [String: Any] = ["extensions": ["settings": [a: [:], b: ["disable_reasons": [1]], c: [:], d: ["disable_reasons": [2]]]]]
        try JSONSerialization.data(withJSONObject: settings).write(to: folder.appendingPathComponent("Secure Preferences"))

        let found = ArcExtensionsImport.read(profileFolder: folder)
        #expect(found.available.map(\.name) == ["Alpha", "Zeta"])
        #expect(found.unavailable.map(\.name) == ["uBlock"])
    }

    @Test func arcProfilesInAKiteProfile() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let work = try state.createProfile(named: "Work")
        state.arcProfileMap = ["Profile 3": work.dataStoreID, "Profile 4": work.dataStoreID, "Profile 5": UUID(),
                               "Profile 6": Profile.default.dataStoreID]
        #expect(state.arcProfiles(inKiteProfile: work.directory) == ["Profile 3", "Profile 4"])
        // An Arc profile an import put in Kite's Default comes with Arc's Default.
        #expect(state.arcProfiles(inKiteProfile: Profile.defaultDirectory) == ["Default", "Profile 6"])
        #expect(state.arcProfiles(inKiteProfile: "Profile 9").isEmpty)
    }
}
