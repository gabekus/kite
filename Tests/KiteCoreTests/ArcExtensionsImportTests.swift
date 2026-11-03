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
        let item = ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "Dark Reader", "update_url": Self.store])) { _ in nil }
        #expect(item == .init(id: Self.id, name: "Dark Reader"))
        // Arc's own, unpacked or from elsewhere: not from the store.
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "X"])) { _ in nil } == nil)
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: Self.manifest(["name": "X", "update_url": "https://example.com/u"])) { _ in nil } == nil)
        #expect(ArcExtensionsImport.storeExtension(id: "not-an-id", manifest: Self.manifest(["name": "X", "update_url": Self.store])) { _ in nil } == nil)
    }

    @Test func namesFromTheDefaultLocale() {
        let manifest = Self.manifest(["name": "__MSG_appName__", "default_locale": "en", "update_url": Self.store])
        // With a byte order mark, as some extensions ship, and a key in another case.
        let messages = Data([0xEF, 0xBB, 0xBF]) + (try! JSONSerialization.data(withJSONObject: ["APPNAME": ["message": "Grammarly"]]))
        let item = ArcExtensionsImport.storeExtension(id: Self.id, manifest: manifest) { $0 == "en" ? messages : nil }
        #expect(item?.name == "Grammarly")
        // No messages file: the id rather than the placeholder.
        #expect(ArcExtensionsImport.storeExtension(id: Self.id, manifest: manifest) { _ in nil }?.name == Self.id)
    }

    @Test func turnedOffInArc() throws {
        let secure = try JSONSerialization.data(withJSONObject: ["extensions": ["settings": [
            "a": ["disable_reasons": [1]], "b": ["disable_reasons": []], "c": ["state": 1],
        ]]])
        let older = try JSONSerialization.data(withJSONObject: ["extensions": ["settings": ["d": ["disable_reasons": 8192]]]])
        #expect(ArcExtensionsImport.disabledIDs(preferences: [secure, older, Data("x".utf8)]) == ["a", "d"])
    }

    @Test func arcProfilesInAKiteProfile() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let work = try state.createProfile(named: "Work")
        state.arcProfileMap = ["Profile 3": work.dataStoreID, "Profile 4": work.dataStoreID, "Profile 5": UUID()]
        #expect(state.arcProfiles(inKiteProfile: work.directory) == ["Profile 3", "Profile 4"])
        #expect(state.arcProfiles(inKiteProfile: Profile.defaultDirectory) == ["Default"])
        #expect(state.arcProfiles(inKiteProfile: "Profile 9").isEmpty)
    }
}
