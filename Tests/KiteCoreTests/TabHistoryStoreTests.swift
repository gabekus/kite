import Foundation
import Testing
@testable import KiteCore

@Suite struct TabHistoryStoreTests {
    let store = TabHistoryStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("TabHistoryStoreTests-\(UUID().uuidString)", isDirectory: true))
    let url = URL(string: "https://example.com/page")!
    let state = Data([1, 2, 3, 4])

    @Test func loadsWhatWasSavedForTheSameURLAndProfile() {
        let tab = UUID()
        store.save(state, tab: tab, url: url, profile: "Profile 1")
        #expect(store.load(tab: tab, url: url, profile: "Profile 1") == state)
        #expect(store.load(tab: UUID(), url: url, profile: "Profile 1") == nil)
    }

    /// A tab that moved on (or to another profile) since its last save loads its URL instead.
    @Test func ignoresAStateSavedAtAnotherURLOrProfile() {
        let tab = UUID()
        store.save(state, tab: tab, url: url, profile: nil)
        #expect(store.load(tab: tab, url: URL(string: "https://example.com/other")!, profile: nil) == nil)
        #expect(store.load(tab: tab, url: url, profile: "Profile 1") == nil)
        #expect(store.load(tab: tab, url: url, profile: nil) == state)
    }

    @Test func removesOneTabOrAllButTheTabsKept() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        for tab in [a, b, c] { store.save(state, tab: tab, url: url, profile: nil) }
        store.remove(tab: a)
        #expect(store.load(tab: a, url: url, profile: nil) == nil)
        store.removeAll(except: [b])
        #expect(store.load(tab: b, url: url, profile: nil) == state)
        #expect(store.load(tab: c, url: url, profile: nil) == nil)
        store.removeAll()
        store.flush()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) == [])
    }
}
