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
    /// Each live WebKit download's engine context (see WebEngine.downloadContextKey).
    @ObservationIgnored private var webKitContexts: [Int: String] = [:]
    /// Incognito sessions whose window has closed.
    @ObservationIgnored private var endedIncognitoContexts: Set<String> = []
    /// The front window's current tab title: where a Chromium download most likely started.
    @ObservationIgnored var currentTabTitle: () -> String? = { nil }

    /// Posted when a download first appears, with the page's view that started it (a Chromium
    /// browser's view or the WKWebView) as the object and the item's id under "id". Little Kite
    /// puts its own window's downloads in its tray.
    static let didStartDownload = Notification.Name("KiteDownloadDidStart")

    /// Loads the profile's list and starts listening to Chromium.
    func start(fileURL: URL) {
        if let loaded = DownloadsFile.load(fileURL) {
            self.fileURL = fileURL
            list = loaded.list
            if let aside = loaded.movedAside { NSLog("Kite: couldn't read downloads, moved them to \(aside.path)") }
        } else {
            NSLog("Kite: couldn't read or move downloads; not saving over \(fileURL.path) this launch")
        }
        #if canImport(CEFBridge)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .KCDownloadDidUpdate, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let update = DownloadUpdate(notificationInfo: info) else { return }
            let source = (note.object as? KCBrowser)?.view
            MainActor.assumeIsolated { DownloadsModel.shared.apply(update, source: source) }
        }
        #endif
    }

    func apply(_ update: DownloadUpdate, sourceTitle: String? = nil, source: NSView? = nil) {
        // Its incognito window has closed: a late update mustn't bring the row back.
        if update.isIncognito, endedIncognitoContexts.contains(update.engineContext) { return }
        let previous = list.item(engineID: update.engineID, context: update.engineContext)?.state
        // A finished download is final: a late progress tick (WebKit's KVO hops to the main queue)
        // would mark it in progress again, and a late repeat would put back a path Tidy Downloads
        // has since renamed.
        if previous == .complete { return }
        let (item, isNew) = list.apply(update)
        // Incognito downloads never leave Kite: no tab title kept, no Tidy Downloads (it sends
        // names to Claude), nothing written to downloads.json.
        if isNew, !item.isIncognito, let title = sourceTitle ?? currentTabTitle(), !title.isEmpty { sourceTitles[item.id] = title }
        if isNew { NotificationCenter.default.post(name: Self.didStartDownload, object: source, userInfo: ["id": item.id]) }
        if update.state != .inProgress {
            let title = sourceTitles.removeValue(forKey: item.id)
            // Arc Max's Tidy Downloads: a finished download gets a readable name.
            if update.state == .complete, previous != .complete, !item.isIncognito {
                DownloadTidier.shared.tidy(item, sourceTitle: title)
            }
        }
        if item.isIncognito { return }
        // Progress ticks don't need a write each; a download starting or finishing does.
        if previous != update.state { saveSoon(after: .milliseconds(200)) } else { saveSoon(after: .seconds(5)) }
    }

    // MARK: WebKit

    /// `context` is the WebKit engine's downloadContextKey.
    func track(_ download: WKDownload, destination: URL, sourceTitle: String?, context: String, incognito: Bool) {
        let id = nextWebKitID
        nextWebKitID -= 1
        webKitDownloads[id] = download
        webKitContexts[id] = context
        let url = download.originalRequest?.url?.absoluteString ?? ""
        let report: @MainActor (DownloadItem.State) -> Void = { [weak self] state in
            let progress = download.progress
            self?.apply(DownloadUpdate(engineID: id, engineContext: context, isIncognito: incognito, url: url,
                                       path: destination.path, state: state,
                                       receivedBytes: progress.completedUnitCount, totalBytes: progress.totalUnitCount))
        }
        let progress = download.progress
        apply(DownloadUpdate(engineID: id, engineContext: context, isIncognito: incognito, url: url,
                             path: destination.path, state: .inProgress,
                             receivedBytes: progress.completedUnitCount, totalBytes: progress.totalUnitCount),
              sourceTitle: sourceTitle, source: download.webView)
        webKitProgress[id] = download.progress.observe(\.completedUnitCount) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { report(.inProgress) } }
        }
    }

    func webKitDownload(_ download: WKDownload, finished state: DownloadItem.State) {
        guard let id = webKitDownloads.first(where: { $0.value === download })?.key else { return }
        let progress = download.progress
        let context = webKitContexts.removeValue(forKey: id) ?? ""
        if let item = list.item(engineID: id, context: context) {
            apply(DownloadUpdate(engineID: id, engineContext: context, isIncognito: item.isIncognito,
                                 url: item.url, path: item.path, state: state,
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
        let context = item.engineContext ?? ""
        if !KCBrowser.cancelDownload(withID: id, contextKey: context) {
            // Chromium already forgot it (finished between the click and now): show it as it is.
            list.apply(DownloadUpdate(engineID: id, engineContext: context, isIncognito: item.isIncognito,
                                      url: item.url, path: item.path, state: .canceled,
                                      receivedBytes: item.receivedBytes, totalBytes: item.totalBytes))
        }
        #endif
    }

    /// An incognito window closed (`context` is its engine's downloadContextKey): its downloads
    /// stop and leave the list, as Chrome drops them with the incognito profile. Files stay.
    func endIncognitoSession(context: String) {
        endedIncognitoContexts.insert(context)
        let items = list.items.filter { $0.isIncognito && $0.engineContext == context }
        for item in items {
            if item.state == .inProgress { cancel(item) }
            sourceTitles[item.id] = nil
        }
        list.removeIncognito(context: context)
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
            let data = try JSONEncoder().encode(DownloadsFile(downloads: list))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save downloads: \(error)")
        }
    }
}
