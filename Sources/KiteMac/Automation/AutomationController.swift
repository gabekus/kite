import AppKit
import KiteCore
import Observation
#if canImport(CEFBridge)
import CEFBridge
#endif

/// What the automation controller needs from the browser window.
@MainActor
protocol AutomationHost: AnyObject {
    var window: NSWindow? { get }
    /// Pages that exist right now (shown or in the background), for recording the network.
    var livePages: [UUID: WebPage] { get }
    /// The tab's page, created in the background if it isn't live.
    func automationPage(for tab: BrowserTab) -> WebPage
    func closeAutomatedTab(_ id: UUID)
}

/// "Claude in the browser", the local half: runs Claude's tool calls against
/// real tabs, asks the user before anything that commits on their behalf, and
/// tracks which tabs Claude is driving so the window can say so.
///
/// Off by default. While off there's no socket at all, and no DevTools events
/// are collected from any tab.
@MainActor
@Observable
final class AutomationController {
    struct ControlledTab: Equatable {
        var lastActive: Date
        /// Socket connections that touched the tab. A tab whose client went away fades sooner.
        var connections: Set<Int>
    }

    struct Download: Equatable {
        var id: Int
        var url: String
        var path: String
        var state: String
        var receivedBytes: Int64
        var totalBytes: Int64
    }

    private(set) var settings: AutomationSettings
    var isEnabled: Bool { settings.allowClaudeControl }
    /// Tabs Claude is driving right now, for the "Claude is controlling this tab" banner.
    private(set) var controlledTabs: [UUID: ControlledTab] = [:]

    @ObservationIgnored weak var host: AutomationHost?
    @ObservationIgnored let store: BrowserStore
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private var server: AutomationServer?
    /// Tabs the user pressed Stop on. Cleared when the setting is turned off and on again.
    @ObservationIgnored private var revoked: Set<UUID> = []
    @ObservationIgnored private var pendingConfirmations: [UUID: [NSAlert]] = [:]
    @ObservationIgnored private var expiryTimer: Timer?
    /// Console, network and dialog state of tabs Claude has touched, and the page each was collected from.
    @ObservationIgnored var activities: [UUID: TabActivity] = [:]
    @ObservationIgnored private var trackedPages: [UUID: (page: ObjectIdentifier, actions: PageActions)] = [:]
    /// Every request in the tabs being watched, redacted. See `NetworkLog`.
    @ObservationIgnored var network = NetworkLog()
    /// Where recorded requests go on disk, and HAR exports.
    @ObservationIgnored private(set) lazy var networkStore = NetworkLogStore(
        directory: NetworkLogStore.directory(supportDirectory: supportDirectory))
    /// Pages whose Network domain is on because recording is, whether or not Claude drives them.
    @ObservationIgnored private var recordedPages: [UUID: (page: ObjectIdentifier, actions: PageActions)] = [:]
    @ObservationIgnored private var waiters: [UUID: [Waiter]] = [:]
    @ObservationIgnored private var nextWaiterID = 0
    /// Tabs Claude opened itself; closing any other tab asks first.
    @ObservationIgnored var claudeOpened: Set<UUID> = []
    @ObservationIgnored private(set) var downloads: [Int: Download] = [:]
    @ObservationIgnored private var downloadObserver: NSObjectProtocol?
    /// Each tab's last read, the baseline for change-only reads.
    @ObservationIgnored var snapshots: [UUID: PageDiff.Snapshot] = [:]

    /// The tab the running batch last acted on, to say once where it ended up.
    @ObservationIgnored var batchTab: UUID?

    /// True while a batch runs: a step that would need confirmation stops the batch instead of asking.
    @TaskLocal static var inBatch = false

    struct NeedsConfirmation: Error {
        let request: ConfirmationRequest
    }

    enum Timing {
        static let idleWhileConnected: TimeInterval = 120
        static let idleAfterDisconnect: TimeInterval = 15
        static let loadWait: TimeInterval = 10
        static let confirmationWait: TimeInterval = 120
    }

    private struct Waiter {
        let id: Int
        let check: (String?, JSONValue, TabActivity) -> Bool
        let finish: (Bool) -> Void
    }

    init(store: BrowserStore, supportDirectory: URL) {
        self.store = store
        self.supportDirectory = supportDirectory
        settings = AutomationSettings.load(from: AutomationSettings.fileURL(supportDirectory: supportDirectory))
    }

    var socketURL: URL { AutomationWire.socketURL(supportDirectory: supportDirectory) }

    /// Opens the socket if the setting is on. Call once the window exists.
    func start() {
        if isEnabled && !openSocket() { settings.allowClaudeControl = false }
        if isRecordingNetwork { startRecording() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard openSocket() else { return }
        } else {
            server?.stop()
            server = nil
            stop(tabs: Set(controlledTabs.keys).union(pendingConfirmations.keys).union(trackedPages.keys))
            stopRecording()
            network.clear()
            revoked.removeAll()
            activities.removeAll()
            snapshots.removeAll()
            claudeOpened.removeAll()
            if let downloadObserver { NotificationCenter.default.removeObserver(downloadObserver) }
            downloadObserver = nil
        }
        update { $0.allowClaudeControl = enabled }
        if enabled && isRecordingNetwork { startRecording() }
    }

    // MARK: Network recording

    /// Every tab's requests go to the network log (and to disk), not just the tabs Claude drives.
    var isRecordingNetwork: Bool { isEnabled && settings.recordNetwork }

    func setRecordNetwork(_ record: Bool) {
        guard record != settings.recordNetwork else { return }
        update { $0.recordNetwork = record }
        if isRecordingNetwork { startRecording() } else { stopRecording() }
    }

    /// A tab got a page (opened, revived, or a popup): watch it if recording.
    func pageCreated(_ id: UUID, _ page: WebPage) {
        guard isRecordingNetwork else { return }
        Task { await record(id, page: page) }
    }

    private func startRecording() {
        networkStore.prune()
        for (id, page) in host?.livePages ?? [:] {
            Task { await record(id, page: page) }
        }
    }

    private func stopRecording() {
        for (id, recorded) in recordedPages where trackedPages[id]?.page != recorded.page {
            Task { await recorded.actions.stopEvents(domains: ["Network"]) }
        }
        recordedPages.removeAll()
        networkStore.flush()
    }

    private func record(_ id: UUID, page: WebPage) async {
        let identity = ObjectIdentifier(page)
        guard isRecordingNetwork, recordedPages[id]?.page != identity, let actions = page.automation as? PageActions else { return }
        recordedPages[id] = (identity, actions)
        do {
            try await actions.startEvents(domains: ["Network"]) { [weak self] method, params in
                self?.received(method, params, tab: id)
            }
        } catch {
            recordedPages[id] = nil
        }
    }

    func setAllowJavaScript(_ allow: Bool) { update { $0.allowJavaScript = allow } }
    func setUseClaudeSpace(_ use: Bool) { update { $0.useClaudeSpace = use } }

    private func update(_ change: (inout AutomationSettings) -> Void) {
        change(&settings)
        do {
            try settings.save(to: AutomationSettings.fileURL(supportDirectory: supportDirectory))
        } catch {
            NSLog("Kite: couldn't save the automation settings: \(error)")
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
        if settings.recordNetwork { networkStore.flush() }
    }

    /// The Stop button: Claude loses these tabs until the setting is turned off and on.
    func stop(tabs: Set<UUID>) {
        revoked.formUnion(tabs)
        for id in tabs {
            controlledTabs[id] = nil
            for alert in pendingConfirmations.removeValue(forKey: id) ?? [] {
                host?.window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            }
            for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.finish(false) }
            if let tracked = trackedPages.removeValue(forKey: id) {
                // Recording keeps the tab's Network domain on.
                let keepNetwork = recordedPages[id]?.page == tracked.page
                Task { await tracked.actions.stopEvents(domains: keepNetwork ? ["Log", "Runtime"] : ["Network", "Log", "Runtime"]) }
            }
        }
    }

    func isRevoked(_ id: UUID) -> Bool { revoked.contains(id) }
    var revokedTabs: Set<UUID> { revoked }

    /// The driver of the tab's current page, if its network is being watched, for fetching bodies.
    func networkActions(_ tab: String) -> PageActions? {
        guard let id = UUID(uuidString: tab) else { return nil }
        return trackedPages[id]?.actions ?? recordedPages[id]?.actions
    }

    private func openSocket() -> Bool {
        let server = AutomationServer(
            socketURL: socketURL,
            handler: { [weak self] request, connection in
                await self?.perform(request, connection: connection) ?? .failure(.disabled)
            },
            onDisconnect: { [weak self] connection in
                Task { @MainActor in self?.disconnected(connection) }
            }
        )
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Kite couldn't start Claude's connection"
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
        self.server = server
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIdleTabs() }
        }
        watchDownloads()
        return true
    }

    private func watchDownloads() {
        #if canImport(CEFBridge)
        guard downloadObserver == nil else { return }
        downloadObserver = NotificationCenter.default.addObserver(forName: .KCDownloadDidUpdate, object: nil, queue: .main) {
            [weak self] note in
            guard let info = note.userInfo, let id = (info["id"] as? NSNumber)?.intValue else { return }
            let download = Download(
                id: id, url: info["url"] as? String ?? "", path: info["path"] as? String ?? "", state: info["state"] as? String ?? "",
                receivedBytes: (info["receivedBytes"] as? NSNumber)?.int64Value ?? 0, totalBytes: (info["totalBytes"] as? NSNumber)?.int64Value ?? -1)
            MainActor.assumeIsolated { self?.downloads[id] = download }
        }
        #endif
    }

    // MARK: Control indicator

    func markControlled(_ id: UUID, connection: Int) {
        var entry = controlledTabs[id] ?? ControlledTab(lastActive: Date(), connections: [])
        entry.lastActive = Date()
        entry.connections.insert(connection)
        controlledTabs[id] = entry
    }

    private func disconnected(_ connection: Int) {
        for (id, var entry) in controlledTabs where entry.connections.contains(connection) {
            entry.connections.remove(connection)
            controlledTabs[id] = entry
        }
        expireIdleTabs()
    }

    private func expireIdleTabs(now: Date = Date()) {
        let live = store.state.allTabIDs
        for (id, entry) in controlledTabs {
            let idle = entry.connections.isEmpty ? Timing.idleAfterDisconnect : Timing.idleWhileConnected
            if now.timeIntervalSince(entry.lastActive) > idle || !live.contains(id) { controlledTabs[id] = nil }
        }
        // Closed tabs take their logs with them.
        for id in Array(snapshots.keys) where !live.contains(id) { snapshots[id] = nil }
        for id in Array(activities.keys) where !live.contains(id) {
            activities[id] = nil
            trackedPages[id] = nil
        }
        for id in Array(recordedPages.keys) where !live.contains(id) {
            recordedPages[id] = nil
            network.forget(tab: id.uuidString)
        }
        if !isEnabled { expiryTimer?.invalidate() }
    }

    // MARK: Events and waiting

    /// Starts collecting a tab's DevTools events, once per page (a hibernated tab gets a new page).
    func track(_ id: UUID, page: WebPage, actions: PageActions) async throws {
        let identity = ObjectIdentifier(page)
        guard trackedPages[id]?.page != identity else { return }
        trackedPages[id] = (identity, actions)
        if activities[id] == nil { activities[id] = TabActivity() }
        try await actions.startEvents(domains: ["Page", "Runtime", "Log", "Network"]) { [weak self] method, params in
            self?.received(method, params, tab: id)
        }
    }

    private func received(_ method: String, _ params: JSONValue, tab id: UUID) {
        if method.hasPrefix("Network.") {
            let finished = network.ingest(method: method, params: params, tab: id.uuidString)
            if isRecordingNetwork { networkStore.append(finished) }
        }
        guard activities[id] != nil, activities[id]!.ingest(method: method, params: params) || method.hasPrefix("Page.") else { return }
        wakeWaiters(id, method: method, params: params)
        if method.hasPrefix("Network.") || method == "Page.frameNavigated" {
            // Network idleness needs a quiet period with no further events.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                MainActor.assumeIsolated { self?.wakeWaiters(id, method: nil, params: .object([:])) }
            }
        }
    }

    private func wakeWaiters(_ id: UUID, method: String?, params: JSONValue) {
        guard let list = waiters[id], let activity = activities[id] else { return }
        for waiter in list where waiter.check(method, params, activity) { waiter.finish(true) }
    }

    /// Waits until `check` passes for one of the tab's events (method nil is a timer tick), or the timeout.
    func waitForEvent(_ id: UUID, timeout: TimeInterval, check: @escaping (String?, JSONValue, TabActivity) -> Bool) async -> Bool {
        if check(nil, .object([:]), activities[id] ?? TabActivity()) { return true }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            var done = false
            let finish: (Bool) -> Void = { [weak self] result in
                guard !done else { return }
                done = true
                self?.waiters[id]?.removeAll { $0.id == waiterID }
                continuation.resume(returning: result)
            }
            waiters[id, default: []].append(Waiter(id: waiterID, check: check, finish: finish))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                MainActor.assumeIsolated { self?.wakeWaiters(id, method: nil, params: .object([:])) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Runs an action, but returns early if it opens a JavaScript dialog: the page is
    /// frozen until the dialog is answered, so the input event wouldn't finish until then.
    func untilDialog(_ id: UUID, _ action: @escaping () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !done else { return }
                done = true
                continuation.resume(with: result)
            }
            Task {
                do {
                    try await action()
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
            Task {
                if await self.waitForEvent(id, timeout: Timing.loadWait * 3, check: { _, _, activity in activity.dialog != nil }) {
                    finish(.success(()))
                }
            }
        }
    }

    /// Lets a click or Return start its navigation, then waits (briefly) for the load to finish.
    func settle(_ id: UUID, startDelay: TimeInterval = 0.25) async {
        try? await Task.sleep(for: .seconds(startDelay))
        if activities[id]?.dialog != nil { return }
        let deadline = Date().addingTimeInterval(Timing.loadWait)
        while store.pages[id]?.isLoading == true, Date() < deadline, activities[id]?.dialog == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Running tool calls

    func perform(_ request: AutomationWire.Request, connection: Int) async -> ToolOutput {
        guard isEnabled else { return .failure(.disabled) }
        do {
            let command = try AutomationCommand(tool: request.tool, arguments: request.arguments)
            return try await run(command, connection: connection)
        } catch let error as AutomationError {
            return .failure(error)
        } catch let error as AutomationCommand.InvalidArguments {
            return .failure(AutomationError(.invalidArguments, error.description))
        } catch {
            return .failure(AutomationError(.failed, "\(error)"))
        }
    }

    func resolveTab(_ string: String?) throws -> BrowserTab {
        let tab: BrowserTab?
        if let string {
            guard let id = UUID(uuidString: string.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationError(.invalidArguments, "\"\(string)\" isn't a tab id. Call tabs_context for ids.")
            }
            tab = store.state.tab(id)
        } else {
            tab = store.state.selectedTab
        }
        guard let tab else { throw AutomationError(.notFound, "That tab isn't open. Call tabs_context for the open tabs.") }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
        return tab
    }

    // MARK: Confirmation

    func authorize(_ action: AutomationAction, tab: BrowserTab) async throws {
        switch AutomationPolicy.evaluate(action, host: store.state.tab(tab.id)?.url?.host()) {
        case .allow:
            break
        case .deny(let reason):
            throw AutomationError(.denied, reason)
        case .confirm(let request):
            try await require(request, tab: tab.id)
        }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
    }

    /// Asks the user; throws if they say no. Inside a batch it stops the batch instead.
    func require(_ request: ConfirmationRequest, tab id: UUID) async throws {
        if Self.inBatch { throw NeedsConfirmation(request: request) }
        guard await confirm(request, tab: id) else {
            if revoked.contains(id) { throw AutomationError.stopped }
            throw AutomationError.denied(request.action)
        }
    }

    /// Shows the tab and asks. Deny is the default button; no answer within two minutes is a no.
    private func confirm(_ request: ConfirmationRequest, tab id: UUID) async -> Bool {
        guard let window = host?.window else { return false }
        store.mutate { $0.select(tab: id) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.detail + "\n\nOnly allow this if you asked Claude to do it."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        pendingConfirmations[id, default: []].append(alert)
        defer { pendingConfirmations[id]?.removeAll { $0 === alert } }

        let timeout = DispatchWorkItem { [weak window] in
            window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.confirmationWait, execute: timeout)
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        timeout.cancel()
        return response == .alertSecondButtonReturn
    }

    // MARK: Setup help

    /// The CLI inside the app bundle, or next to the executable in a `swift build`.
    var cliPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/kite")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return executable.deletingLastPathComponent().appendingPathComponent("kite-cli").path
    }

    /// `KITE_SUPPORT_PATH`, when this Kite runs on a test profile, so the CLI finds the same socket.
    var profileOverride: String? { ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] }

    var claudeCodeCommand: String {
        var command = "claude mcp add -s user kite"
        if let profileOverride { command += " -e KITE_SUPPORT_PATH=\(Self.shellQuote(profileOverride))" }
        return command + " -- \(Self.shellQuote(cliPath)) mcp"
    }

    static func shellQuote(_ string: String) -> String {
        string.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? string : "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
