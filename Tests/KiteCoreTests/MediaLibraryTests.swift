import Foundation
import Testing
@testable import KiteCore

struct MediaLibraryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func item(_ name: String, _ date: Date, _ source: MediaLibrary.Source = .desktop) -> MediaLibrary.Item {
        .init(file: URL(fileURLWithPath: "/m/\(name)"), date: date, source: source, kind: MediaLibrary.kind(of: URL(fileURLWithPath: name)) ?? .image)
    }

    @Test func sourcesInArcOrder() {
        #expect(MediaLibrary.Source.allCases.map(\.title) == ["Documents", "Desktop", "Screenshots", "Kite Captures", "Downloads"])
    }

    @Test func kindsByExtension() {
        #expect(MediaLibrary.kind(of: URL(fileURLWithPath: "/a/B.PNG")) == .image)
        #expect(MediaLibrary.kind(of: URL(fileURLWithPath: "/a/b.heic")) == .image)
        #expect(MediaLibrary.kind(of: URL(fileURLWithPath: "/a/b.mov")) == .video)
        #expect(MediaLibrary.kind(of: URL(fileURLWithPath: "/a/b.pdf")) == nil)
        #expect(MediaLibrary.kind(of: URL(fileURLWithPath: "/a/b")) == nil)
    }

    @Test func screenshotsFolder() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        #expect(MediaLibrary.screenshotsFolder(location: nil, home: home).path == "/Users/x/Desktop")
        #expect(MediaLibrary.screenshotsFolder(location: "", home: home).path == "/Users/x/Desktop")
        #expect(MediaLibrary.screenshotsFolder(location: "/tmp/shots", home: home).path == "/tmp/shots")
    }

    @Test func sectionsNewestFirstUnderLibraryHeadings() {
        // Wednesday 2026-10-28 12:00 UTC; the week starts Sunday the 25th.
        let now = Date(timeIntervalSince1970: 1_793_188_800)
        let hour: TimeInterval = 3600
        let items = [
            item("old.png", now - 40 * 24 * hour),
            item("today.png", now - 1 * hour),
            item("monday.png", now - 50 * hour),
            item("yesterday.mov", now - 20 * hour),
            item("today2.png", now - 2 * hour),
        ]
        let sections = MediaLibrary.sections(items, now: now, calendar: calendar)
        #expect(sections.map { $0.title(locale: Locale(identifier: "en_US"), calendar: calendar) }
                == ["Today", "Yesterday", "Earlier This Week", "September 2026"])
        #expect(sections[0].items.map(\.name) == ["today.png", "today2.png"])
        #expect(sections[1].items.first?.kind == .video)
    }

    @Test func filterSourcesQueryAndHidden() {
        let now = Date()
        let items = [
            item("cat.png", now, .desktop),
            item("dog.png", now - 1, .downloads),
            item("Screen Shot.png", now - 2, .screenshots),
        ]
        func names(_ filter: MediaLibrary.Filter, hidden: Set<String> = []) -> [String] {
            MediaLibrary.sections(items, filter: filter, hidden: hidden, now: now).flatMap(\.items).map(\.name)
        }
        #expect(names(.init()) == ["cat.png", "dog.png", "Screen Shot.png"])
        #expect(names(.init(sources: [.downloads, .screenshots])) == ["dog.png", "Screen Shot.png"])
        #expect(names(.init(sources: [])) == [])
        #expect(names(.init(query: "SCREEN")) == ["Screen Shot.png"])
        #expect(names(.init(), hidden: ["/m/cat.png"]) == ["dog.png", "Screen Shot.png"])
    }

    @Test func captureStoreKeepsAndDeletes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kite-captures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureStore(folder: folder)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let capture = try store.store(png: png, sourceURL: URL(string: "https://example.com"), title: "Example")
        #expect(try Data(contentsOf: store.file(for: capture)) == png)

        let reopened = CaptureStore(folder: folder)
        #expect(reopened.all.map(\.id) == [capture.id])
        #expect(reopened.all.first?.sourceURL?.absoluteString == "https://example.com")

        reopened.delete(capture.id)
        #expect(reopened.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file(for: capture).path))
        #expect(CaptureStore(folder: folder).all.isEmpty)
    }

    @Test func mediaLibraryPage() {
        #expect(LibraryPage(stored: "MediaPage") == .media)
        #expect(LibraryPage.allCases.map(\.rawValue) == ["DownloadsPage", "ArchivePage", "MediaPage"])
        #expect(LibraryPage.media.title == "Media")
    }
}
