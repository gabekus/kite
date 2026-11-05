import Foundation
import Testing
@testable import KiteCore

/// Tests/Fixtures/downloads-v1.json is the downloads list Kite for Windows (windows/) shares with
/// the Mac. Both test suites load it, so a change that breaks the other app fails here. It holds a
/// live download as Windows writes one (a Windows path, an engine id and context), and items from
/// before engineContext, isIncognito and speed.
@Suite struct DownloadsFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/downloads-v1.json")

    func load() throws -> DownloadsFile {
        try JSONDecoder().decode(DownloadsFile.self, from: Data(contentsOf: Self.fixture))
    }

    @Test func decodesTheSharedFixture() throws {
        let file = try load()
        #expect(file.version == 1)
        let items = file.downloads.items
        #expect(items.map(\.state) == [.inProgress, .complete, .canceled, .interrupted])
        #expect(items[0].engineID == 7 && items[0].engineContext == "Profile 1")
        #expect(items[0].path == #"C:\Users\me\Downloads\Kite Setup.exe"#)
        #expect(items[0].fraction == 0.375 && items[0].speed == 250000)
        #expect(items[1].fileName == "report.pdf" && items[1].sourceHost == "example.com")
        #expect(items[1].startedAt == Date(timeIntervalSinceReferenceDate: 783800000))
        #expect(items[2].fileName == "big.zip" && items[2].fraction == nil)
        #expect(items[3].isIncognito == false && items[3].speed == 0 && items[3].engineID == nil)
        var restored = file.downloads
        restored.markRestored()
        #expect(restored.items.map(\.state) == [.interrupted, .complete, .canceled, .interrupted])
    }

    @Test func roundTrips() throws {
        let file = try load()
        let again = try JSONDecoder().decode(DownloadsFile.self, from: JSONEncoder().encode(file))
        #expect(again.downloads == file.downloads)
    }
}
