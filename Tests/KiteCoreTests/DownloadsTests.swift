import Foundation
import Testing
@testable import KiteCore

@Suite struct DownloadsTests {
    func update(_ id: Int, _ state: DownloadItem.State = .inProgress, received: Int64 = 0, total: Int64 = 100,
                path: String = "/Users/me/Downloads/report.pdf") -> DownloadUpdate {
        DownloadUpdate(engineID: id, url: "https://www.example.com/report.pdf", path: path, state: state,
                       receivedBytes: received, totalBytes: total, speed: 50)
    }

    @Test func updatesOneEntryPerDownloadNewestFirst() {
        var list = DownloadList()
        #expect(list.apply(update(1)).isNew)
        #expect(!list.apply(update(1, received: 40)).isNew)
        list.apply(update(2))
        #expect(list.items.map(\.engineID) == [2, 1])
        #expect(list.items[1].receivedBytes == 40)
        #expect(list.items[1].fraction == 0.4)
    }

    @Test func keepsTheKnownPathWhenAnUpdateHasNone() {
        var list = DownloadList()
        list.apply(update(1))
        list.apply(update(1, path: ""))
        #expect(list.items[0].fileName == "report.pdf")
    }

    @Test func finishedDownloadsStopReportingSpeed() {
        var list = DownloadList()
        list.apply(update(1, received: 10))
        #expect(list.items[0].speed == 50)
        list.apply(update(1, .complete, received: 100))
        #expect(list.items[0].speed == 0)
        #expect(list.active.isEmpty)
    }

    @Test func restoredDownloadsAreNoLongerLive() throws {
        var list = DownloadList()
        list.apply(update(1, received: 10))
        list.apply(update(2, .complete, received: 100))
        let data = try JSONEncoder().encode(list)
        var restored = try JSONDecoder().decode(DownloadList.self, from: data)
        restored.markRestored()
        #expect(restored.items.allSatisfy { $0.engineID == nil })
        #expect(restored.items.map(\.state) == [.complete, .interrupted])
        // A new launch's id 1 is a new download, not the old one.
        #expect(restored.apply(update(1)).isNew)
    }

    @Test func idsAreKeyedByBrowserContext() {
        var list = DownloadList()
        list.apply(DownloadUpdate(engineID: 1, url: "https://a/x", path: "/d/x", state: .complete, receivedBytes: 5, totalBytes: 5))
        // Another profile's and an incognito window's first downloads are new rows, not the first one finishing again.
        #expect(list.apply(DownloadUpdate(engineID: 1, engineContext: "Profile 1", url: "https://b/y", path: "/d/y",
                                          state: .inProgress, receivedBytes: 0, totalBytes: 9)).isNew)
        #expect(list.apply(DownloadUpdate(engineID: 1, engineContext: "incognito-1", isIncognito: true, url: "https://c/z",
                                          path: "/d/z", state: .inProgress, receivedBytes: 0, totalBytes: 9)).isNew)
        list.apply(DownloadUpdate(engineID: 1, engineContext: "Profile 1", url: "https://b/y", path: "/d/y",
                                  state: .inProgress, receivedBytes: 4, totalBytes: 9))
        #expect(list.items.count == 3)
        #expect(list.item(engineID: 1, context: "")?.state == .complete)
        #expect(list.item(engineID: 1, context: "Profile 1")?.receivedBytes == 4)
        #expect(list.item(engineID: 1, context: "incognito-1")?.isIncognito == true)
        #expect(list.item(engineID: 1, context: "Profile 2") == nil)
    }

    @Test func incognitoDownloadsAreNeverSaved() throws {
        var list = DownloadList()
        list.apply(update(1, .complete))
        list.apply(DownloadUpdate(engineID: 1, engineContext: "incognito-1", isIncognito: true, url: "https://secret/a",
                                  path: "/d/secret.pdf", state: .complete, receivedBytes: 1, totalBytes: 1))
        #expect(list.items.count == 2)
        let data = try JSONEncoder().encode(DownloadsFile(downloads: list))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        let restored = try JSONDecoder().decode(DownloadsFile.self, from: data).downloads
        #expect(restored.items.count == 1)
        #expect(restored.items.allSatisfy { !$0.isIncognito })
    }

    @Test func readsFilesFromBeforeContexts() throws {
        // downloads.json as Kite wrote it before engineContext and isIncognito.
        let json = """
        {"version":1,"downloads":{"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","engineID":3,
        "url":"https://a/x","path":"/d/x","state":"complete","receivedBytes":5,"totalBytes":5,"speed":0,
        "startedAt":700000000}]}}
        """
        let file = try JSONDecoder().decode(DownloadsFile.self, from: Data(json.utf8))
        #expect(file.downloads.items.count == 1)
        #expect(file.downloads.items[0].isIncognito == false)
        #expect(file.downloads.items[0].engineContext == nil)
    }

    @Test func anUnreadableFileIsMovedAsideNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kite-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("downloads.json")

        // No file: an empty list, nothing moved.
        let empty = try #require(DownloadsFile.load(file))
        #expect(empty.list.items.isEmpty && empty.movedAside == nil)

        // A good file restores, with nothing live.
        var list = DownloadList()
        list.apply(update(1, received: 10))
        try JSONEncoder().encode(DownloadsFile(downloads: list)).write(to: file)
        let good = try #require(DownloadsFile.load(file))
        #expect(good.list.items.map(\.state) == [.interrupted])
        #expect(good.movedAside == nil)

        // A damaged one is kept beside it, and the path is free for the next save.
        try Data("{\"version\":1,\"downl".utf8).write(to: file)
        let bad = try #require(DownloadsFile.load(file))
        #expect(bad.list.items.isEmpty)
        let aside = try #require(bad.movedAside)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: aside) == Data("{\"version\":1,\"downl".utf8))
    }

    @Test func activeFractionCombinesBytes() {
        var list = DownloadList()
        list.apply(update(1, received: 50, total: 100))
        list.apply(update(2, received: 0, total: 300))
        list.apply(update(3, received: 10, total: -1))
        #expect(list.activeFraction == 0.125)
    }

    @Test func clearingKeepsLiveDownloads() {
        var list = DownloadList()
        list.apply(update(1))
        list.apply(update(2, .complete))
        list.apply(update(3, .canceled))
        list.clearFinished()
        #expect(list.items.map(\.engineID) == [1])
    }

    @Test func oldFinishedDownloadsFallOff() {
        var list = DownloadList()
        list.apply(update(0))
        for id in 1...(DownloadList.limit + 5) { list.apply(update(id, .complete)) }
        #expect(list.items.count == DownloadList.limit)
        // The live one survives even though it's the oldest.
        #expect(list.items.last?.engineID == 0)
    }

    @Test func subtitles() {
        var list = DownloadList()
        list.apply(update(1, received: 1_000_000, total: 4_000_000))
        #expect(DownloadText.subtitle(list.items[0]).contains(" of "))
        list.apply(update(1, .complete, received: 4_000_000, total: 4_000_000))
        let done = DownloadText.subtitle(list.items[0])
        #expect(done.hasPrefix("PDF · "))
        #expect(done.hasSuffix(" from example.com"))
        list.apply(update(1, .interrupted))
        #expect(DownloadText.subtitle(list.items[0]) == "Failed to Download")
        #expect(DownloadText.kind(of: "Kite.dmg") == "Disk Image")
        #expect(DownloadText.kind(of: "a.zip") == "ZIP Archive")
    }

    @Test func stateNamesFromChromium() {
        #expect(DownloadUpdate.state(named: "complete") == .complete)
        #expect(DownloadUpdate.state(named: "canceled") == .canceled)
        #expect(DownloadUpdate.state(named: "interrupted") == .interrupted)
        #expect(DownloadUpdate.state(named: "in-progress") == .inProgress)
    }
}
