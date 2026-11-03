import Foundation
import Testing
@testable import KiteCore

/// Tests/Fixtures/session-v1.json is the session format Kite for Windows (windows/) shares
/// with the Mac. Both test suites load it, so a change that breaks the other app fails here.
@Suite struct SessionFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/session-v1.json")

    func load() throws -> BrowserState {
        // SessionStore moves unreadable files aside, so read a copy.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("session.json")
        try FileManager.default.copyItem(at: Self.fixture, to: copy)
        return try #require(try SessionStore(fileURL: copy).load())
    }

    @Test func decodesTheSharedFixture() throws {
        let state = try load()
        #expect(state.spaces.map(\.name) == ["Personal", "Work"])
        #expect(state.selectedSpace.name == "Work")
        #expect(state.searchEngine == .duckDuckGo)
        #expect(state.favorites.map(\.title) == ["Mail"])
        #expect(state.spaces[0].pinned.map(\.displayTitle) == ["Docs", "Renamed"])
        #expect(state.spaces[0].tabs[0].displayTitle == "example.com")
        // The second space uses the pre-folders `pinned` array and has no `tint`.
        #expect(state.spaces[1].pinned.map(\.title) == ["Old pinned"])
        #expect(state.spaces[1].theme.tint == Theme.defaultTint)
        #expect(state.spaces[1].about == "Komado: orders and suppliers")
        #expect(state.adblockAllowedHosts == ["news.example.com"])
    }

    @Test func roundTrips() throws {
        let state = try load()
        let again = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
    }
}
