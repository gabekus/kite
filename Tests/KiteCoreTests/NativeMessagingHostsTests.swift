import Foundation
import Testing
@testable import KiteCore

@Suite struct NativeMessagingHostsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kite-nmh-\(UUID().uuidString)")
    var chrome: URL { root.appendingPathComponent("chrome") }
    var arc: URL { root.appendingPathComponent("arc") }
    var kite: URL { root.appendingPathComponent("kite") }

    func manifest(_ name: String, path: String = "/Applications/App.app/host") -> Data {
        Data(#"{"name":"\#(name)","path":"\#(path)","type":"stdio","allowed_origins":[]}"#.utf8)
    }

    func put(_ data: Data, _ name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    func read(_ name: String) -> Data? { try? Data(contentsOf: kite.appendingPathComponent(name)) }

    @Test func copiesManifestsAndTheEarlierFolderWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put(manifest("com.1password.1password"), "com.1password.1password.json", in: chrome)
        try put(manifest("com.1password.1password", path: "/arc"), "com.1password.1password.json", in: arc)
        try put(manifest("com.granola.app"), "com.granola.app.json", in: arc)
        try put(Data("not json".utf8), "broken.json", in: arc)
        try put(Data("{}".utf8), "notes.txt", in: arc)

        let provided = NativeMessagingHosts.sync(from: [chrome, arc, root.appendingPathComponent("missing")], into: kite)
        #expect(provided == ["com.1password.1password.json", "com.granola.app.json"])
        #expect(read("com.1password.1password.json") == manifest("com.1password.1password"))
        #expect(read("broken.json") == nil)
    }

    @Test func updatesAndRemovesOnlyItsOwnCopies() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put(manifest("a"), "a.json", in: chrome)
        try put(manifest("b"), "b.json", in: chrome)
        try put(manifest("mine", path: "/mine"), "mine.json", in: kite)
        NativeMessagingHosts.sync(from: [chrome], into: kite)

        try put(manifest("a", path: "/new"), "a.json", in: chrome)
        try FileManager.default.removeItem(at: chrome.appendingPathComponent("b.json"))
        try put(manifest("mine"), "mine.json", in: chrome)
        let provided = NativeMessagingHosts.sync(from: [chrome], into: kite)

        #expect(provided == ["a.json"])
        #expect(read("a.json") == manifest("a", path: "/new"))
        #expect(read("b.json") == nil)
        // Someone else's manifest is never replaced or removed.
        #expect(read("mine.json") == manifest("mine", path: "/mine"))
    }

    @Test func adoptsAnIdenticalCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put(manifest("a"), "a.json", in: chrome)
        try put(manifest("a"), "a.json", in: kite)
        #expect(NativeMessagingHosts.sync(from: [chrome], into: kite) == ["a.json"])
        try FileManager.default.removeItem(at: chrome.appendingPathComponent("a.json"))
        NativeMessagingHosts.sync(from: [chrome], into: kite)
        #expect(read("a.json") == nil)
    }
}
