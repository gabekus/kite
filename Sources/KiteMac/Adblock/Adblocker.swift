import Foundation
import KiteCore

/// The built-in ad and tracker blocker: keeps the filter lists and uBO's scriptlets
/// fresh in `support/Adblock/`, builds the engine off the main thread (or loads its
/// cached copy, which takes ~15 ms instead of ~50), and answers the engines'
/// questions about what to block and inject.
///
/// Layout: `lists/<id>.txt`, `resources.json` (scriptlets + redirects),
/// `engine.dat` (the serialized engine), `status.json` (when each was fetched).
@MainActor
final class Adblocker {
    /// Whether Kite was built with the ad blocker (scripts/build-adblock.sh).
    static var isAvailable: Bool {
        #if canImport(KiteAdblock)
        true
        #else
        false
        #endif
    }

    let directory: URL
    /// The page-side function that empties the class/id queue. Random per launch so
    /// pages can't count on its name.
    let drainName = "__kite_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    let styleID = UUID().uuidString.prefix(8).lowercased()

    private(set) var isEnabled = true
    private(set) var allowedHosts: Set<String> = []
    /// Called on the main thread with each new engine, and when the on/off policy changes.
    var onEngineChange: [() -> Void] = []
    var onPolicyChange: [() -> Void] = []

    #if canImport(KiteAdblock)
    private(set) var engine: AdblockEngine?
    /// Just `BrowserNags`, for pages the main engine doesn't filter (the ad blocker
    /// is off there, or the lists haven't downloaded yet). Builds in about a millisecond.
    private lazy var nagEngine = AdblockEngine.build(lists: BrowserNags.withBuiltIn([]))
    /// Exceptions for the last pages asked about, so the class/id reports don't recompute them.
    private var exceptionsByHost: [String: [String]] = [:]
    #endif

    private var refreshTimer: Timer?
    private var refreshing = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Kite"]
        return URLSession(configuration: configuration)
    }()

    private struct Status: Codable {
        var listsUpdatedAt: Date?
        var resourcesUpdatedAt: Date?
        var uboRelease: String?
        /// `engineFormat` the cached engine was built with.
        var engineFormat: Int?
        /// `BrowserNags.fingerprint` of the copy of that list in the cached engine.
        var browserNags: String?

        var cacheIsCurrent: Bool { engineFormat == Adblocker.engineFormat && browserNags == BrowserNags.fingerprint }

        mutating func markCacheCurrent() {
            engineFormat = Adblocker.engineFormat
            browserNags = BrowserNags.fingerprint
        }
    }

    /// Bump when the Rust build changes how lists compile (e.g. adblock-rust
    /// features), so an engine cached by an older Kite is rebuilt, not reused.
    /// 3: engines include `BrowserNags`.
    private nonisolated static let engineFormat = 3

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard Self.isAvailable else { return }
        // The restored tab starts loading right after launch, so load the cached
        // engine now (~20 ms) rather than let its first requests through unfiltered.
        loadCacheNow()
        Task {
            await loadFromDisk()
            await refreshIfDue()
        }
        // Lists refresh daily; checking hourly catches a Mac that slept through the deadline.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
    }

    func setPolicy(enabled: Bool, allowedHosts: Set<String>) {
        guard enabled != isEnabled || allowedHosts != self.allowedHosts else { return }
        isEnabled = enabled
        self.allowedHosts = allowedHosts
        onPolicyChange.forEach { $0() }
    }

    func blocks(_ url: URL?) -> Bool {
        guard isEnabled, let host = url?.host()?.lowercased(), url?.scheme?.hasPrefix("http") == true else { return false }
        return !allowedHosts.contains(host)
    }

    // MARK: Cosmetic filtering

    /// What to run at document start for a page, or nil when there's nothing to do.
    /// Pages the ad blocker skips still get `BrowserNags`.
    func documentStartScript(for url: URL) -> String? {
        #if canImport(KiteAdblock)
        guard let host = url.host(), url.scheme?.hasPrefix("http") == true else { return nil }
        if blocks(url), let engine, let resources = engine.cosmeticResources(for: url) {
            exceptionsByHost[host] = resources.exceptions
            if exceptionsByHost.count > 64 { exceptionsByHost = [host: resources.exceptions] }
            return resources.documentStartScript(host: host, styleID: String(styleID), drain: drainName)
        }
        // The nag list has no generic rules, so there's no class/id queue to drain.
        guard let resources = nagEngine?.cosmeticResources(for: url),
              !resources.hideSelectors.isEmpty || !resources.procedural.isEmpty else { return nil }
        return resources.documentStartScript(host: host, styleID: String(styleID), drain: nil)
        #else
        return nil
        #endif
    }

    /// Script that hands back the classes and ids a page queued (`genericHidingScript`'s input).
    var drainScript: String { CosmeticResources.drainScript(drainName) }

    /// The page reported classes and ids it uses; returns a script adding the
    /// generic rules that hide any of them, or nil when none apply.
    func genericHidingScript(payload: String, pageURL: URL?) -> String? {
        #if canImport(KiteAdblock)
        guard let pageURL, blocks(pageURL), let engine, let host = pageURL.host(),
              let seen = try? JSONDecoder().decode(SeenClassesAndIDs.self, from: Data(payload.utf8)) else { return nil }
        // Pages control the payload; cap it so a hostile one can't stall the main thread.
        let classes = Array(seen.classes.prefix(2000)), ids = Array(seen.ids.prefix(2000))
        let exceptions = exceptionsByHost[host] ?? engine.cosmeticResources(for: pageURL)?.exceptions ?? []
        let selectors = engine.hiddenSelectors(classes: classes, ids: ids, exceptions: exceptions)
        return selectors.isEmpty ? nil : CosmeticResources.appendCSSScript(selectors, styleID: String(styleID))
        #else
        return nil
        #endif
    }

    // MARK: Loading and refreshing

    #if canImport(KiteAdblock)
    private nonisolated var listsDirectory: URL { directory.appendingPathComponent("lists", isDirectory: true) }
    private var engineURL: URL { directory.appendingPathComponent("engine.dat") }
    private var resourcesURL: URL { directory.appendingPathComponent("resources.json") }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }

    private nonisolated func listURL(_ list: FilterList) -> URL { listsDirectory.appendingPathComponent(list.id + ".txt") }

    private func readStatus() -> Status {
        (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Status.self, from: $0) } ?? Status()
    }

    private func writeStatus(_ status: Status) {
        try? JSONEncoder().encode(status).write(to: statusURL, options: .atomic)
    }

    /// The downloaded list texts, then `BrowserNags`; empty until a list has
    /// downloaded. Only WebKit's rule conversion needs them after the engine is
    /// built, so they're read from disk on demand instead of kept in memory.
    nonisolated func readLists() -> [(text: Data, trusted: Bool)] {
        let downloaded = FilterList.defaults.compactMap { list in (try? Data(contentsOf: listURL(list))).map { ($0, list.trusted) } }
        return downloaded.isEmpty ? [] : BrowserNags.withBuiltIn(downloaded)
    }

    private func loadCacheNow() {
        let start = Date()
        guard readStatus().cacheIsCurrent, let data = try? Data(contentsOf: engineURL), let engine = AdblockEngine.deserialize(data) else { return }
        if let resources = try? Data(contentsOf: resourcesURL) { _ = engine.useResources(resources) }
        publish(engine)
        NSLog("Kite: ad blocker loaded from cache in %.0f ms", Date().timeIntervalSince(start) * 1000)
    }

    /// The cached engine if it's still readable, else a rebuild from the saved lists.
    private func loadFromDisk() async {
        guard engine == nil else { return }
        let engineURL = engineURL, resourcesURL = resourcesURL
        let lists = readLists()
        guard !lists.isEmpty else { return }
        let cacheIsCurrent = readStatus().cacheIsCurrent
        let loaded: AdblockEngine? = await Task.detached(priority: .userInitiated) {
            let resources = try? Data(contentsOf: resourcesURL)
            var engine = cacheIsCurrent ? (try? Data(contentsOf: engineURL)).flatMap(AdblockEngine.deserialize) : nil
            if engine == nil {
                engine = AdblockEngine.build(lists: lists)
                if let data = engine?.serialize() { try? data.write(to: engineURL, options: .atomic) }
            }
            if let resources { _ = engine?.useResources(resources) }
            return engine
        }.value
        if let loaded {
            if !cacheIsCurrent {
                var status = readStatus()
                status.markCacheCurrent()
                writeStatus(status)
            }
            publish(loaded)
        }
    }

    private func publish(_ engine: AdblockEngine) {
        self.engine = engine
        exceptionsByHost = [:]
        onEngineChange.forEach { $0() }
    }

    func refreshIfDue(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var status = readStatus()
        let now = Date()
        var changed = false
        try? FileManager.default.createDirectory(at: listsDirectory, withIntermediateDirectories: true)

        if force || engine == nil || FilterList.isRefreshDue(lastUpdated: status.listsUpdatedAt, now: now) {
            var fetched = 0
            await withTaskGroup(of: (FilterList, Data?).self) { group in
                for list in FilterList.defaults {
                    group.addTask { [session] in
                        guard let (data, response) = try? await session.data(from: list.url),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              FilterList.looksValid(String(decoding: data.prefix(4096), as: UTF8.self)) else { return (list, nil) }
                        return (list, data)
                    }
                }
                for await (list, data) in group {
                    guard let data else { NSLog("Kite: couldn't update filter list \(list.id)"); continue }
                    try? data.write(to: listURL(list), options: .atomic)
                    fetched += 1
                }
            }
            // Keep retrying hourly until every list came down; a partial update still rebuilds.
            if fetched == FilterList.defaults.count { status.listsUpdatedAt = now }
            changed = fetched > 0
        }

        if force || FilterList.isRefreshDue(lastUpdated: status.resourcesUpdatedAt, now: now)
            || !FileManager.default.fileExists(atPath: resourcesURL.path) {
            do {
                let release = try await ScriptletResources.latestRelease(session: session)
                if release != status.uboRelease || !FileManager.default.fileExists(atPath: resourcesURL.path) {
                    let source = try await ScriptletResources.download(
                        release: release, into: directory.appendingPathComponent("ubo", isDirectory: true), session: session)
                    let resources = try await Task.detached { try ScriptletResources.build(from: source) }.value
                    try resources.write(to: resourcesURL, options: .atomic)
                    try? FileManager.default.removeItem(at: source)
                    status.uboRelease = release
                    changed = true
                }
                status.resourcesUpdatedAt = now
            } catch {
                NSLog("Kite: couldn't update uBlock Origin resources: \(error)")
            }
        }
        guard changed else { return writeStatus(status) }
        status.markCacheCurrent()
        writeStatus(status)

        let lists = readLists()
        let engineURL = engineURL, resourcesURL = resourcesURL
        let rebuilt: AdblockEngine? = await Task.detached(priority: .utility) {
            guard let engine = AdblockEngine.build(lists: lists) else { return nil }
            if let data = engine.serialize() { try? data.write(to: engineURL, options: .atomic) }
            if let resources = try? Data(contentsOf: resourcesURL) { _ = engine.useResources(resources) }
            return engine
        }.value
        if let rebuilt { publish(rebuilt) }
    }
    #else
    func refreshIfDue(force: Bool = false) async {}
    private func loadFromDisk() async {}
    private func loadCacheNow() {}
    #endif
}
