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
