import AppKit
import KiteCore
import Observation

/// What the Media page shows (Arc's `MediaPageReducer`): the pictures and videos in Documents,
/// Desktop, Downloads and the screenshots folder, read only after the user allows it on the page
/// (Arc's `isOnboardedToMediaPage`), plus Kite's own Captures. Files the user hides stay hidden (Arc's
/// "Hide from Arc", IgnoredPaths.json). Folders are watched while the page is open.
@MainActor
@Observable
final class MediaLibraryModel {
    static let shared = MediaLibraryModel()

    private(set) var items: [MediaLibrary.Item] = []
    private(set) var hidden: Set<String> = []
    private(set) var isOnboarded = false
    /// "Show media from:", kept like Arc's `dataSourcePreferences`.
    var sources = Set(MediaLibrary.Source.allCases) {
        didSet { save() }
    }

    @ObservationIgnored let captures: CaptureStore
    @ObservationIgnored private let settingsURL: URL
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var scanGeneration = 0

    private struct Settings: Codable {
        var onboarded = false
        var hiddenPaths: [String] = []
        var sources: [MediaLibrary.Source]?
    }

    private init() {
        let support = AppDelegate.supportDirectory
        captures = CaptureStore(folder: support.appendingPathComponent("Captures", isDirectory: true))
        settingsURL = support.appendingPathComponent("Media.json")
        if let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            isOnboarded = settings.onboarded
            hidden = Set(settings.hiddenPaths)
            if let sources = settings.sources { self.sources = Set(sources) }
        }
        items = captureItems()
    }

    // MARK: Folders

    /// The user's home. A test build (`KITE_SUPPORT_PATH`) can point it at fixtures with
    /// `KITE_TEST_MEDIA_HOME`, so trying the page doesn't read the user's own folders.
    private static var home: URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let path = environment["KITE_TEST_MEDIA_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var isTestHome: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KITE_SUPPORT_PATH"] != nil && !(environment["KITE_TEST_MEDIA_HOME"] ?? "").isEmpty
    }

    private static var folders: [(MediaLibrary.Source, URL)] {
        let home = home
        let location = isTestHome ? nil : UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return [
            (.documents, home.appendingPathComponent("Documents", isDirectory: true)),
            (.desktop, home.appendingPathComponent("Desktop", isDirectory: true)),
            (.downloads, home.appendingPathComponent("Downloads", isDirectory: true)),
            (.screenshots, MediaLibrary.screenshotsFolder(location: location, home: home)),
        ]
    }

    /// Reads the folders off the main thread: each folder's own files (not subfolders), pictures and
    /// videos only. A screenshot or screen recording (macOS marks them) counts as Screenshots wherever
    /// it is.
    nonisolated private static func scan(_ folders: [(MediaLibrary.Source, URL)]) -> [MediaLibrary.Item] {
        var items: [MediaLibrary.Item] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        for (source, folder) in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for file in files {
                guard let kind = MediaLibrary.kind(of: file), seen.insert(file.path).inserted,
                      let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
                let isScreenCapture = getxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
                items.append(.init(file: file, date: date, source: isScreenCapture ? .screenshots : source, kind: kind))
            }
        }
        return items
    }

    private func captureItems() -> [MediaLibrary.Item] {
        captures.all.map { capture in
            .init(file: captures.file(for: capture), date: capture.date, source: .captures, kind: .image,
                  sourceURL: capture.sourceURL, captureID: capture.id)
        }
    }

    func refresh() {
        let captured = captureItems()
        guard isOnboarded else {
            items = captured
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        let folders = Self.folders
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan(folders)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.scanGeneration else { return }
                    self.items = found + self.captureItems()
                }
            }
        }
    }

    // MARK: Page lifetime

    /// The page came on screen: read everything and watch the folders for changes.
    func pageAppeared() {
        viewers += 1
        refresh()
        if viewers == 1 { startWatching() }
    }

    func pageDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stopWatching() }
    }

    private func startWatching() {
        stopWatching()
        guard isOnboarded else { return }
        var paths = Set<String>()
        for (_, folder) in Self.folders where paths.insert(folder.path).inserted {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
    }

    // MARK: Actions

    /// Arc's welcome card button: from now on the page reads the folders (macOS asks for each).
    func allowAccess() {
        isOnboarded = true
        save()
        refresh()
        if viewers > 0 { startWatching() }
    }

    /// Arc's "Hide from Arc": the file stays where it is; the page stops showing it.
    func hide(_ item: MediaLibrary.Item) {
        hidden.insert(item.file.path)
        save()
    }

    /// Arc's Delete for a Capture.
    func deleteCapture(_ item: MediaLibrary.Item) {
        guard let id = item.captureID else { return }
        captures.delete(id)
        items.removeAll { $0.captureID == id }
    }

    /// Keeps a capture for the page (Arc's `CaptureClient.storeCapture`).
    func storeCapture(png: Data, sourceURL: URL?, title: String) {
        guard (try? captures.store(png: png, sourceURL: sourceURL, title: title)) != nil else { return }
        refresh()
    }

    private func save() {
        let settings = Settings(onboarded: isOnboarded, hiddenPaths: hidden.sorted(),
                                sources: MediaLibrary.Source.allCases.filter(sources.contains))
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
    }
}
