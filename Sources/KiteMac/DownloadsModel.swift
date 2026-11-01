import AppKit
import KiteCore
import Observation
import WebKit
#if canImport(CEFBridge)
import CEFBridge
#endif

/// Every window's downloads list, fed by both engines and kept in the profile's downloads.json.
@MainActor
@Observable
final class DownloadsModel {
    static let shared = DownloadsModel()

    private(set) var list = DownloadList()
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// WebKit downloads by the negative engine id they're listed under (Chromium's ids are positive).
    @ObservationIgnored private var webKitDownloads: [Int: WKDownload] = [:]
    @ObservationIgnored private var webKitProgress: [Int: NSKeyValueObservation] = [:]
    @ObservationIgnored private var nextWebKitID = -1
    /// The title of the tab each live download came from, for Tidy Downloads.
    @ObservationIgnored private var sourceTitles: [UUID: String] = [:]
    /// The front window's current tab title: where a Chromium download most likely started.
    @ObservationIgnored var currentTabTitle: () -> String? = { nil }

    /// Posted when a download first appears, with the page's view that started it (a Chromium
    /// browser's view or the WKWebView) as the object and the item's id under "id". Little Kite
    /// puts its own window's downloads in its tray.
    static let didStartDownload = Notification.Name("KiteDownloadDidStart")

    private struct File: Codable {
        var version: Int
        var downloads: DownloadList
    }

    /// Loads the profile's list and starts listening to Chromium.
    func start(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            list = file.downloads
            list.markRestored()
        }
        #if canImport(CEFBridge)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .KCDownloadDidUpdate, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let id = (info["id"] as? NSNumber)?.intValue else { return }
            let update = DownloadUpdate(
                engineID: id,
                url: info["url"] as? String ?? "",
                path: info["path"] as? String ?? "",
                state: DownloadUpdate.state(named: info["state"] as? String ?? ""),
                receivedBytes: (info["receivedBytes"] as? NSNumber)?.int64Value ?? 0,
                totalBytes: (info["totalBytes"] as? NSNumber)?.int64Value ?? -1,
                speed: (info["speed"] as? NSNumber)?.int64Value ?? 0)
            let source = (note.object as? KCBrowser)?.view
            MainActor.assumeIsolated { DownloadsModel.shared.apply(update, source: source) }
        }
        #endif
    }

    func apply(_ update: DownloadUpdate, sourceTitle: String? = nil, source: NSView? = nil) {
        let previous = list.items.first { $0.engineID == update.engineID }?.state
        // A finished download is final: a late progress tick (WebKit's KVO hops to the main queue)
        // would mark it in progress again, and a late repeat would put back a path Tidy Downloads
        // has since renamed.
        if previous == .complete { return }
        let (item, isNew) = list.apply(update)
        if isNew, let title = sourceTitle ?? currentTabTitle(), !title.isEmpty { sourceTitles[item.id] = title }
        if isNew { NotificationCenter.default.post(name: Self.didStartDownload, object: source, userInfo: ["id": item.id]) }
        if update.state != .inProgress {
            let title = sourceTitles.removeValue(forKey: item.id)
            // Arc Max's Tidy Downloads: a finished download gets a readable name.
            if update.state == .complete, previous != .complete { DownloadTidier.shared.tidy(item, sourceTitle: title) }
        }
        // Progress ticks don't need a write each; a download starting or finishing does.
        if previous != update.state { saveSoon(after: .milliseconds(200)) } else { saveSoon(after: .seconds(5)) }
    }

    // MARK: WebKit

    func track(_ download: WKDownload, destination: URL, sourceTitle: String?) {
        let id = nextWebKitID
        nextWebKitID -= 1
        webKitDownloads[id] = download
        let url = download.originalRequest?.url?.absoluteString ?? ""
        let report: @MainActor (DownloadItem.State) -> Void = { [weak self] state in
            let progress = download.progress
            self?.apply(DownloadUpdate(engineID: id, url: url, path: destination.path, state: state,
                                       receivedBytes: progress.completedUnitCount, totalBytes: progress.totalUnitCount))
        }
        let progress = download.progress
        apply(DownloadUpdate(engineID: id, url: url, path: destination.path, state: .inProgress,
                             receivedBytes: progress.completedUnitCount, totalBytes: progress.totalUnitCount),
              sourceTitle: sourceTitle, source: download.webView)
        webKitProgress[id] = download.progress.observe(\.completedUnitCount) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { report(.inProgress) } }
        }
    }

    func webKitDownload(_ download: WKDownload, finished state: DownloadItem.State) {
        guard let id = webKitDownloads.first(where: { $0.value === download })?.key else { return }
        let progress = download.progress
        if let item = list.items.first(where: { $0.engineID == id }) {
            apply(DownloadUpdate(engineID: id, url: item.url, path: item.path, state: state,
                                 receivedBytes: progress.completedUnitCount,
                                 totalBytes: state == .complete ? max(progress.completedUnitCount, progress.totalUnitCount) : progress.totalUnitCount))
        }
        webKitDownloads[id] = nil
        webKitProgress[id] = nil
    }

    // MARK: Actions (Arc's download context menu: Open, Copy, Show in Finder, Hide from Arc, Move to Trash, Cancel)

    func fileExists(_ item: DownloadItem) -> Bool {
        !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path)
    }

    func open(_ item: DownloadItem) {
        guard item.state == .complete, fileExists(item) else { return reveal(item) }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    func reveal(_ item: DownloadItem) {
        guard fileExists(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// The file itself on the pasteboard, as Finder's Copy puts it.
    func copy(_ item: DownloadItem) {
        guard fileExists(item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: item.path) as NSURL])
    }

    func cancel(_ item: DownloadItem) {
        guard item.state == .inProgress, let id = item.engineID else { return }
        if let download = webKitDownloads[id] {
            download.cancel { _ in }
            webKitDownload(download, finished: .canceled)
            return
        }
        #if canImport(CEFBridge)
        if !KCBrowser.cancelDownload(withID: id) {
            // Chromium already forgot it (finished between the click and now): show it as it is.
            list.apply(DownloadUpdate(engineID: id, url: item.url, path: item.path, state: .canceled,
                                      receivedBytes: item.receivedBytes, totalBytes: item.totalBytes))
        }
        #endif
    }

    /// Hide from the list; the file stays.
    func remove(_ item: DownloadItem) {
        if item.state == .inProgress { cancel(item) }
        list.remove(item.id)
        saveSoon(after: .milliseconds(200))
    }

    func moveToTrash(_ item: DownloadItem) {
        guard fileExists(item) else { return remove(item) }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)]) { [weak self] _, error in
            if error == nil { MainActor.assumeIsolated { self?.remove(item) } }
        }
    }

    func clearFinished() {
        list.clearFinished()
        saveSoon(after: .milliseconds(200))
    }

    /// Delete browsing data's download history: the list forgets finished downloads started at
    /// or after `since`; the files stay.
    func removeHistory(since: Date?) {
        list.removeHistory(since: since)
        saveSoon(after: .milliseconds(200))
    }

    /// The file moved (Tidy Downloads renamed it, or Undo put it back): the list follows.
    func moved(_ id: UUID, to path: String) {
        guard list.setPath(path, for: id) else { return }
        saveSoon(after: .milliseconds(200))
    }

    // MARK: Saving

    private func saveSoon(after delay: Duration) {
        if saveTask != nil, delay > .seconds(1) { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(version: DownloadList.currentVersion, downloads: list))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save downloads: \(error)")
        }
    }
}
