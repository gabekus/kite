import Foundation
import Testing
@testable import KiteCore

/// Tests/Fixtures/history-v1.json is history.json as Kite for Mac writes it, which Kite for
/// Windows (windows/src/core/History.cpp) reads and writes too. Both test suites load it, so a
/// change that breaks the other app fails here. The second test reads the file as Kite for
/// Windows writes it (sorted keys, unescaped slashes).
@Suite struct HistoryFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/history-v1.json")

    func load(_ data: Data) throws -> History {
        // HistoryFile moves unreadable files aside, so read a copy.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("history.json")
        try data.write(to: copy)
        return try #require(try HistoryFile(fileURL: copy).load())
    }

    @Test func decodesTheSharedFixture() throws {
        let history = try load(Data(contentsOf: Self.fixture))
        #expect(history.entries.count == 3)
        let kite = history.entries["https://github.com/gabekus/kite"]
        #expect(kite?.title == "gabekus/kite")
        #expect(kite?.visitCount == 4)
        #expect(kite?.lastVisit == Date(timeIntervalSinceReferenceDate: 784111234.567891))
        #expect(history.entries["https://www.example.com/"]?.displayTitle == "www.example.com")
        #expect(history.entries["https://ja.wikipedia.org/wiki/%E5%87%A7"]?.title == "凧 - Wikipedia")
    }

    /// Tests/Fixtures/history-url-keys.json: a URL as Chromium can report it, and the key history
    /// keeps for it, which is NSURL's absoluteString (the Mac's CEF bridge makes its URLs with
    /// NSURL(string:)). Kite for Windows makes the same keys itself (History::Normalized), and its
    /// suite reads the same pairs, so the two can't drift apart.
    @Test func urlKeysAreWhatNSURLWrites() throws {
        struct Pair: Decodable { let raw: String; let key: String }
        struct Fixture: Decodable { let cases: [Pair] }
        let file = Self.fixture.deletingLastPathComponent().appendingPathComponent("history-url-keys.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        // Which NSURL this ran against: its parsing changed with macOS 14 (RFC 3986), Kite's minimum.
        print("HistoryFixtureTests.urlKeysAreWhatNSURLWrites: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #expect(fixture.cases.count >= 8)
        for pair in fixture.cases {
            #expect(NSURL(string: pair.raw)?.absoluteString == pair.key, "\(pair.raw)")
            // A key is its own key: what the Mac wrote reads back unchanged.
            #expect(NSURL(string: pair.key)?.absoluteString == pair.key, "\(pair.key)")
            // And history keeps it under that key.
            var history = History()
            if let url = URL(string: pair.raw) { history.recordVisit(url, title: "", at: Date(timeIntervalSinceReferenceDate: 0)) }
            #expect(history.entries.keys.sorted() == [pair.key], "\(pair.raw)")
        }
    }

    @Test func readsKiteForWindowsWriting() throws {
        // What windows/src/core/History.cpp's EncodeFile writes for the fixture.
        let windows = #"{"history":{"entries":{"https://github.com/gabekus/kite":{"lastVisit":784111234.567891,"title":"gabekus/kite","url":"https://github.com/gabekus/kite","visitCount":4},"https://ja.wikipedia.org/wiki/%E5%87%A7":{"lastVisit":783999999.5,"title":"凧 - Wikipedia","url":"https://ja.wikipedia.org/wiki/%E5%87%A7","visitCount":2},"https://www.example.com/":{"lastVisit":784000000,"title":"","url":"https://www.example.com/","visitCount":1}}},"version":1}"#
        let fromWindows = try load(Data(windows.utf8))
        let fromMac = try load(Data(contentsOf: Self.fixture))
        #expect(fromWindows == fromMac)
    }
}
