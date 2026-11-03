import Foundation
import Testing
@testable import KiteCore

/// Tests/Fixtures/keybindings-v1.json is the shortcuts file Kite for Windows (windows/) shares
/// with the Mac. Both test suites load it, so a change that breaks the other app fails here.
@Suite struct KeyBindingsFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/keybindings-v1.json")

    func load() throws -> KeyBindings {
        try JSONDecoder().decode(KeyBindings.self, from: Data(contentsOf: Self.fixture))
    }

    @Test func decodesTheSharedFixture() throws {
        let bindings = try load()
        #expect(bindings.userOverrides.map(\.action) == ["archiveTab", "reloadPage", "printPage", "developerTools", "viewSource", "nextSpace"])
        let archive = try #require(bindings.override(for: "archiveTab"))
        #expect(archive.shortcut == KeyShortcut("w", [.shift, .command]))
        #expect(archive.source == .arc)
        #expect(bindings.override(for: "reloadPage")?.shortcut?.modifiers == [.option, .command])
        #expect(bindings.priority(for: "reloadPage") == .overrideWebView)
        // No shortcut: the command has none.
        #expect(bindings.override(for: "printPage")?.shortcut == nil)
        #expect(bindings.priority(for: "developerTools") == .low)
        // A single-character key is lowercased; a priority this build doesn't know keeps the default.
        #expect(bindings.override(for: "nextSpace")?.shortcut == KeyShortcut("s", [.shift, .command]))
        #expect(bindings.priority(for: "nextSpace") == KeyShortcutPriority.defaultPriority(for: "nextSpace"))
    }

    @Test func roundTrips() throws {
        let bindings = try load()
        let again = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(bindings))
        #expect(again == bindings)
    }
}
