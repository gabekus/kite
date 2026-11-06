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
    /// The window's store: its selection is the front space and tab the tools act on.
    var store: BrowserStore { get }
    /// The window has closed (and hasn't been shown again).
    var hasClosed: Bool { get }
    /// Pages that exist right now (shown or in the background), for recording the network.
    var livePages: [UUID: WebPage] { get }
    /// The tab's page, created in the background if it isn't live.
    func automationPage(for tab: BrowserTab) -> WebPage
    func closeAutomatedTab(_ id: UUID)
    /// Whether the password manager (Settings) can fill in this window, for sign_in.
    var canOpenPasswordManager: Bool { get }
    /// Its name ("1Password", "Bitwarden"), or nil with none chosen.
    var passwordManagerName: String? { get }
    /// Opens its popup over the selected tab. False if it couldn't.
    func openPasswordManager() -> Bool
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
        /// Its latest update: Chromium's id is unique only within `update.engineContext`.
        var update: DownloadUpdate
        /// Order seen, for the report.
        var sequence: Int
    }

    private(set) var settings: AutomationSettings
    var isEnabled: Bool { settings.allowClaudeControl }
    /// Tabs Claude is driving right now, with their idle clocks. Not observed: every tool call
    /// touches it, and the sidebar only needs to know which tabs (`controlledTabIDs`).
    @ObservationIgnored private(set) var controlledTabs: [UUID: ControlledTab] = [:] {
        didSet {
            let ids = Set(controlledTabs.keys)
            if ids != controlledTabIDs { controlledTabIDs = ids }
            if !controlledTabs.isEmpty, expiryTimer == nil { startExpiryTimer() }
        }
    }
    /// The tabs Claude is driving: the sidebar marks their rows and the Claude folders that hold them,
    /// and the page gets Claude's border while one is in front.
    private(set) var controlledTabIDs: Set<UUID> = []
    /// What Claude said about each tab with tab_status, and the tabs it opened or acted on (not only read), so every one
    /// of them shows a state in the sidebar (`tabState`): working, needs you, done, or left without a word.
    private(set) var tabDeclared: [UUID: ClaudeTabState.Declared] = [:]
    /// When Claude last opened or acted on each tab (not only read it). Observed: the sidebar shows those tabs.
    private(set) var touchedTabs: [UUID: Date] = [:]
    /// The connection that last acted on each tab, and the stalls it has heard about (`stalledNews`).
    @ObservationIgnored private var tabConnection: [UUID: Int] = [:]
    @ObservationIgnored private var stallsTold: [UUID: Date] = [:]
    /// Tabs handed to the user to sign in (sign_in), for the banner's Done and Cancel.
    var signIns: [UUID: SignInRequest] = [:]
    /// Steps Claude handed to the user (handoff), newest last, kept a while after they end so Claude can read how
    /// they went. The ring on each step's page shows it, and the sidebar marks their tabs.
    var handoffs: [Handoff] = []
    /// The last step each tab's click ended, and the last tab each tab's page opened, so a click that opens a tab
    /// is told apart from one that doesn't (whichever of the two Kite hears first).
    @ObservationIgnored var handoffClicks: [UUID: (step: String, at: Date)] = [:]
    @ObservationIgnored var handoffOpens: [UUID: (tab: UUID, at: Date)] = [:]
    @ObservationIgnored var handoffPoller: Task<Void, Never>?
    /// Which step's ring each tab's page shows, so Kite takes it off when the step ends.
    @ObservationIgnored var ringShown: [UUID: String] = [:]
    /// The frame of another origin that holds each tab's ring, when the step's control is in one (`ringLook`).
    @ObservationIgnored var ringFrames: [UUID: PageFrame] = [:]
    @ObservationIgnored var handoffCount = 0
    /// Steps a handoff report has told Claude are blocked, so a wait ends early for each only once.
    @ObservationIgnored var reportedBlockedSteps: Set<String> = []
    /// When each step's control was last seen missing, so a page still drawing it isn't taken for another page.
    @ObservationIgnored var controlMissingSince: [String: Date] = [:]
    @ObservationIgnored var handoffPolling = false
    /// Window and app notifications that call for a look (`watchHandoffEvents`), and the last tabs it saw.
    @ObservationIgnored var handoffObservers: [NSObjectProtocol] = []
    /// The handoff ring's watch on the tools' store (the front tab, the steps' tabs), re-armed when they move to another window (`attach`).
    @ObservationIgnored var handoffTabsWatch = StoreWatch<[String]>()
    /// The one look after `UserHandoff.offPageDelay` (`scheduleHandoffFollowUp`).
    @ObservationIgnored var handoffFollowUp: Task<Void, Never>?
    @ObservationIgnored var handoffPollAgain = false
    /// A lead to a step's tab waiting for the user to pause typing or clicking in Kite (`HandoffLead`).
    @ObservationIgnored var handoffLead: Task<Void, Never>?
    /// Tabs Kite just brought forward for a step: their next look scrolls the control into view and pulses the ring.
    @ObservationIgnored var ringJumps: Set<UUID> = []
    /// Which connection made each handoff, and the handoffs whose end it has heard, for `handoffNews`.
    @ObservationIgnored var handoffConnections: [String: Int] = [:]
    @ObservationIgnored var handoffEndsTold: Set<String> = []
    /// The step whose tag shows on its own at the top of each tab's page, its control not found there.
    @ObservationIgnored var ringFloating: [UUID: String] = [:]

    /// The normal window the tools work in, and its store. It moves when that window closes (`attach`).
    @ObservationIgnored private weak var attachedHost: AutomationHost?
    @ObservationIgnored private var attachedStore: BrowserStore
    /// The window and store a tool call works in: the ones it started with, so one call doesn't act on two
    /// windows' selections, until that window closes under it; then the window the tools moved to.
    var host: AutomationHost? { target.host }
    var store: BrowserStore { target.store }
    private var target: Target {
        if let started = Self.commandTarget, let host = started.host, !host.hasClosed { return started }
        return Target(host: attachedHost, store: attachedStore)
    }
    struct Target: @unchecked Sendable {
        weak var host: AutomationHost?
        let store: BrowserStore
    }
    @TaskLocal static var commandTarget: Target?
    /// Before a tool call that needs a window: AppDelegate moves the tools to a live normal window,
    /// opening one if none is left, so they never drive a window that has closed.
    @ObservationIgnored var ensureWindow: (() -> Void)?
    @ObservationIgnored let supportDirectory: URL
    @ObservationIgnored private var server: AutomationServer?
    /// Tabs the user pressed Stop on. Cleared when the setting is turned off and on again.
    @ObservationIgnored private var revoked: Set<UUID> = []
    @ObservationIgnored private var pendingConfirmations: [UUID: [NSAlert]] = [:]
    /// Runs only while Claude drives a tab, to end the indicator once it's idle.
    @ObservationIgnored private var expiryTimer: Timer?
    /// While the setting is on: watches the socket's folder, to reopen the socket if it couldn't open at launch or
    /// its file went away. App activation checks too. No timer: an idle Kite shouldn't wake for it.
    @ObservationIgnored private var socketFolderWatch: DispatchSourceFileSystemObject?
    /// The folder above it, for that folder (the profile, or /tmp/kite-<uid>) being moved or deleted.
    @ObservationIgnored private var socketParentWatch: DispatchSourceFileSystemObject?
    /// Only while the socket couldn't open (another Kite answering, or a socket a crashed one left with no folder
    /// change to tell): a slow retry.
    @ObservationIgnored private var socketRetry: Timer?
    /// When the socket last failed to open. A failed bind unlinks the path, which the folder watch sees; retries it
    /// prompts within `socketRetryPause` are skipped, so a failure can't loop through the watch.
    @ObservationIgnored private var lastSocketFailure: Date?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Other Kites found holding the socket, each reported once (`reportSocketTaken`).
    @ObservationIgnored private var reportedSocketHolders: Set<Int32> = []
    /// The last reason the socket didn't open, so each reason is logged once.
    @ObservationIgnored private var lastSocketError: String?
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
    /// The tabs each Claude task opened, newest last, so a placeholder tab id can mean the task's only tab.
    @ObservationIgnored var taskTabs: [UUID: [UUID]] = [:]
    /// The session folder name each connection (one Claude session) last used, so its later Claude-folder
    /// tabs land in the same Claude › Session folder without repeating it.
    @ObservationIgnored var sessionFolders: [Int: String] = [:]
    /// Which tab's page opened which, so results can say where an action's new tabs went.
    @ObservationIgnored var openedTabs = OpenedTabs()
    /// By "context#id".
    @ObservationIgnored private(set) var downloads: [String: Download] = [:]
    @ObservationIgnored private var downloadObserver: NSObjectProtocol?
    /// Each tab's last read, the baseline for change-only reads.
    @ObservationIgnored var snapshots: [UUID: PageDiff.Snapshot] = [:]

    /// The tab the running batch last acted on, to say once where it ended up.
    @ObservationIgnored var batchTab: UUID?

    /// True while a batch runs: a step that would need confirmation stops the batch instead of asking.
    @TaskLocal static var inBatch = false
    /// The Claude task (Claude Tasks panel) the running call comes from, if Kite started its client.
    @TaskLocal static var agentTask: UUID?

    /// TypeSafe's Jev, when the user has a key: quick typed decisions (see `Jev`).
    @ObservationIgnored var jev: JevClient?

    /// Claude Tasks: whether a task id is one of Kite's running tasks, and where its new tabs go.
    @ObservationIgnored var isRunningTask: ((UUID) -> Bool)?
    /// `session` is the short name Claude gave its work (tabs_create's `session`), which names the task's folder.
    @ObservationIgnored var taskOpenedTab: ((_ task: UUID, _ tab: UUID, _ session: String?) -> Void)?
    /// Ticket tests (`TicketTest`): which tasks are one, so Kite keeps them from posting on Linear, and
    /// `kite test-ticket` starting one (`TicketTest.wireTool`, never an MCP tool).
    @ObservationIgnored var isTicketTest: ((UUID) -> Bool)?
    @ObservationIgnored var startTicketTest: ((JSONValue) -> ToolOutput)?

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
        attachedStore = store
        self.supportDirectory = supportDirectory
        settings = AutomationSettings.load(from: AutomationSettings.fileURL(supportDirectory: supportDirectory))
        handoffs = Handoff.load(from: Handoff.fileURL(supportDirectory: supportDirectory))
        handoffCount = Handoff.lastNumber(in: handoffs)
        skipUnshowableHandoffSteps()
    }

    /// Points the tools at `host`'s window and store.
    func attach(_ host: AutomationHost) {
        let moved = host.store !== attachedStore
        attachedHost = host
        attachedStore = host.store
        guard moved else { return }
        // The handoff ring watched the old store's front tab: watch this one's.
        let generation = handoffTabsWatch.rebind()
        if !handoffObservers.isEmpty { watchHandoffTabs(generation: generation) }
        // Pages already live in this window's pool (and its linked ones) get recorded too.
        if isRecordingNetwork { for (id, page) in host.livePages { Task { await record(id, page: page) } } }
    }

    /// Tabs whose pages Claude is using: when the tools' window closes, they move to the next one rather than
    /// close and reload there.
    var tabsKeptLive: Set<UUID> { Set(controlledTabs.keys).union(claudeOpened).union(trackedPages.keys) }

    var socketURL: URL { AutomationWire.socketURL(supportDirectory: supportDirectory) }

    /// Opens the socket if the setting is on. Call once the window exists.
    ///
    /// A socket that can't open at launch never turns the setting off: Kite
    /// tries again when the socket's folder changes, when Kite comes to the front,
    /// and every 30 s while it has no socket, so "Allow Claude to Control the
    /// Browser" stays on across restarts and updates until the user turns it off.
    func start() {
        // Steps Claude handed over before Kite quit show again, whether or not Claude is connected now.
        watchHandoffEvents()
        if handoffs.contains(where: { !$0.isFinished }) { pollHandoffsSoon() }
        if isEnabled {
            if !openSocket(interactive: false) {
                NSLog("Kite: Claude's connection didn't open at launch; retrying.")
            }
            startWatchdog()
        }
        if isRecordingNetwork { startRecording() }
    }

    private func startWatchdog() {
        watchSocketFolder()
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSocket() }
        }
    }

    private func stopWatchdog() {
        socketFolderWatch?.cancel()
        socketFolderWatch = nil
        socketParentWatch?.cancel()
        socketParentWatch = nil
        stopSocketRetry()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private static let socketRetryPause: TimeInterval = 2

    /// Watches the socket's folder for the socket being deleted or replaced (`.write`) and for the folder itself
    /// being deleted or renamed, and the folder above for being deleted or renamed. After either moves, the watches
    /// are on the old folders: they follow the path to the new ones (which checkSocket made).
    private func watchSocketFolder() {
        socketFolderWatch?.cancel()
        socketParentWatch?.cancel()
        let folder = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketFolderWatch = watch(folder, [.write, .delete, .rename])
        socketParentWatch = watch(folder.deletingLastPathComponent(), [.delete, .rename])
    }

    private func watch(_ folder: URL, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Kite: can't watch \(folder.path) for Claude's socket.")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source, source === self.socketFolderWatch || source === self.socketParentWatch else { return }
                let moved = !source.data.isDisjoint(with: [.delete, .rename])
                self.checkSocket(fromWatch: true)
                if moved, self.isEnabled { self.watchSocketFolder() }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    private func startSocketRetry() {
        guard socketRetry == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSocket() }
        }
        timer.tolerance = 10
        socketRetry = timer
    }

    private func stopSocketRetry() {
        socketRetry?.invalidate()
        socketRetry = nil
    }

    /// Something else can take the socket away from a running Kite: another Kite
    /// on the same profile quitting, or a crashed launch's cleanup. Reopen it.
    /// Never waits on the server's queue (see `AutomationServer`).
    private func checkSocket(fromWatch: Bool = false) {
        guard isEnabled else { return stopWatchdog() }
        if fromWatch, server == nil, let lastSocketFailure, Date().timeIntervalSince(lastSocketFailure) < Self.socketRetryPause { return }
        if let server, server.isListening, server.ownsSocketFile { return }
        if let server {
            NSLog("Kite: Claude's socket file at \(server.socketURL.path) went away; reopening it.")
            server.stop()
            self.server = nil
        }
        _ = openSocket(interactive: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard openSocket(interactive: true) else { return }
            startWatchdog()
        } else {
            stopWatchdog()
            server?.stop()
            server = nil
            stop(tabs: Set(controlledTabs.keys).union(pendingConfirmations.keys).union(trackedPages.keys))
            stopRecording()
            network.clear()
            revoked.removeAll()
            activities.removeAll()
            snapshots.removeAll()
            claudeOpened.removeAll()
            taskTabs.removeAll()
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
        guard isRecordingNetwork, let actions = page.automation as? PageActions else { return }
        // Not in a Task: the page loads its first URL as soon as Chromium attaches it.
        if recordedPages[id] == nil { forgetClosedTabs(live: store.state.allTabIDs) }
        recordedPages[id] = (ObjectIdentifier(page), actions)
        actions.startEventsNow(domains: ["Network"]) { [weak self] method, params in
            self?.received(method, params, tab: id)
        }
    }

    /// Ends page loads Chromium answered but never reported finished (see `NetworkLog.finishAnsweredDocuments`).
    func pageFinishedLoading(_ id: UUID) {
        guard isEnabled else { return }
        let finished = network.finishAnsweredDocuments(tab: id.uuidString)
        if isRecordingNetwork { networkStore.append(finished) }
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

    func setUseClaudeSpace(_ use: Bool) { update { $0.useClaudeSpace = use } }

    func setAskBeforeActing(_ ask: Bool) { update { $0.askBeforeActing = ask } }

    private func update(_ change: (inout AutomationSettings) -> Void) {
        change(&settings)
        do {
            try settings.save(to: AutomationSettings.fileURL(supportDirectory: supportDirectory))
        } catch {
            NSLog("Kite: couldn't save the automation settings: \(error)")
        }
    }

    func shutdown() {
        stopWatchdog()
        stopWatchingHandoffEvents()
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
                // The window it's on, which may not be the tools' window any more.
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
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

    private func openSocket(interactive: Bool) -> Bool {
        let server = AutomationServer(
            socketURL: socketURL,
            handler: { [weak self] request, connection, received in
                await self?.perform(request, connection: connection, received: received) ?? .failure(.disabled)
            },
            onDisconnect: { [weak self] connection in
                Task { @MainActor in self?.disconnected(connection) }
            }
        )
        do {
            try server.start()
        } catch {
            // Turning the setting on shows its own alert with the same holder; at launch and on retries, this one.
            if !interactive, let taken = error as? AutomationServer.SocketTaken { reportSocketTaken(taken) }
            guard interactive else {
                let reason = "\(error)"
                if reason != lastSocketError { NSLog("Kite: couldn't open Claude's socket: \(reason)") }
                lastSocketError = reason
                lastSocketFailure = Date()
                startSocketRetry()
                return false
            }
            let alert = NSAlert()
            alert.messageText = "Kite couldn't start Claude's connection"
            alert.informativeText = "\(error)"
            _ = WindowPresenter.runModal(alert)
            return false
        }
        self.server = server
        lastSocketError = nil
        lastSocketFailure = nil
        stopSocketRetry()
        watchDownloads()
        return true
    }

    /// Another Kite answers on this profile's socket, so Claude's tools reach it, not this Kite. Says so loudly, once per
    /// holder: a log line and an alert naming its PID, app and start time. The installed Kite offers to quit a holder
    /// that isn't the installed Kite (a test or stale build on the real profile), and takes the socket once it's gone.
    private func reportSocketTaken(_ taken: AutomationServer.SocketTaken) {
        guard let holder = taken.holder, holder.pid != getpid(), !reportedSocketHolders.contains(holder.pid) else { return }
        reportedSocketHolders.insert(holder.pid)
        NSLog("Kite: Claude's automation socket at %@ is served by another Kite, %@. Claude's tools reach that Kite, "
            + "not this one, until it quits.", taken.path, holder.summary)
        let home = NSHomeDirectory()
        let mayQuitIt = RealProfileGuard.isInstalledKite(bundleID: Bundle.main.bundleIdentifier,
                                                         bundlePath: Bundle.main.bundleURL.path, home: home)
            && !holder.isInstalledKite(home: home)
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Another Kite has Claude's connection"
            alert.informativeText = "Claude's tools are talking to another Kite on this profile, not this one:\n\n"
                + "\(holder.summary)\n\nThis Kite takes over Claude's connection as soon as that one quits."
            if mayQuitIt {
                alert.informativeText += " It isn't the Kite in Applications, so it's a test or old build."
                alert.addButton(withTitle: "Quit the Other Kite")
                alert.addButton(withTitle: "Leave It Running")
            } else {
                alert.addButton(withTitle: "OK")
            }
            guard WindowPresenter.runModal(alert) == .alertFirstButtonReturn, mayQuitIt else { return }
            self?.quitSocketHolder(holder, path: taken.path)
        }
    }

    /// Asks the holder to quit (as ⌘Q would), if it's still the one answering, then takes the socket.
    private func quitSocketHolder(_ holder: SocketServerProcess, path: String) {
        guard SocketServerProcess.serving(socketPath: path)?.pid == holder.pid else { return checkSocket() }
        NSLog("Kite: asking %@ to quit, to take Claude's socket back.", holder.summary)
        if NSRunningApplication(processIdentifier: holder.pid)?.terminate() != true { kill(holder.pid, SIGTERM) }
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                tries += 1
                let gone = SocketServerProcess.serving(socketPath: path)?.pid != holder.pid
                if gone || tries >= 20 { timer.invalidate(); self?.checkSocket() }
            }
        }
    }

    private func watchDownloads() {
        #if canImport(CEFBridge)
        guard downloadObserver == nil else { return }
        downloadObserver = NotificationCenter.default.addObserver(forName: .KCDownloadDidUpdate, object: nil, queue: .main) {
            [weak self] note in
            // Claude stays out of incognito: its downloads (URLs, paths) are never listed.
            guard let info = note.userInfo, let update = DownloadUpdate(notificationInfo: info), !update.isIncognito else { return }
            let key = "\(update.engineContext)#\(update.engineID)"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.downloads[key] = Download(update: update, sequence: self.downloads[key]?.sequence ?? self.downloads.count)
            }
        }
        #endif
    }

    // MARK: Control indicator

    func markControlled(_ id: UUID, connection: Int) {
        if controlledTabs[id] == nil { Trace.event("tab.state", tab: id, connection: connection, ["state": "working"]) }
        var entry = controlledTabs[id] ?? ControlledTab(lastActive: Date(), connections: [])
        entry.lastActive = Date()
        entry.connections.insert(connection)
        controlledTabs[id] = entry
        tabConnection[id] = connection
    }

    /// Tabs `connection` touched and then left, unfinished, with no step for the user: what its next tool result says,
    /// once per stall, so the agent marks them done or hands them over.
    func stalledNews(for connection: Int) -> String? {
        let state = store.state
        let stalled = touchedTabs.compactMap { id, touched -> (UUID, Date)? in
            guard tabConnection[id] == connection, case .needsYou(_, true)? = tabState(id),
                  stallsTold[id].map({ $0 < touched }) ?? true else { return nil }
            return (id, touched)
        }
        guard !stalled.isEmpty else { return nil }
        for (id, touched) in stalled {
            stallsTold[id] = touched
            Trace.event("tab.state", tab: id, actor: .kite, connection: connection, ["state": "stalled"])
        }
        let names = stalled.map { id, _ in "\(id.uuidString) (“\(state.tab(id)?.displayTitle ?? "")”)" }.joined(separator: ", ")
        return "Kite: the user's sidebar shows “\(ClaudeTabState.stoppedHere)” in orange on tabs you acted on and left without "
            + "a word: \(names). Finish the work there, or call tab_status with state done and a note of what you did, or "
            + "handoff what's the user's."
    }

    /// Claude opened the tab or acted on it: from now on it always shows a state.
    func noteTouched(_ id: UUID) {
        touchedTabs[id] = Date()
    }

    /// The one state a tab Claude opened or drove shows (`ClaudeTabState`), or nil for one it never touched.
    func tabState(_ id: UUID) -> ClaudeTabState? {
        ClaudeTabState.of(step: waitingStep(on: id)?.instruction, declared: tabDeclared[id], active: controlledTabIDs.contains(id),
                          lastTouched: touchedTabs[id])
    }

    /// tab_status: Claude says where a tab stands. Done ends the working indicator at once.
    func setTabStatus(_ id: UUID, _ kind: ClaudeTabState.Declared.Kind, note: String?, connection: Int) {
        Trace.event("tab.state", tab: id, url: store.state.tab(id)?.url, connection: connection,
                    ["state": .string(kind.rawValue), "declared": true, "note_len": .number(Double(note?.count ?? 0))])
        if kind == .working { markControlled(id, connection: connection) } else { controlledTabs[id] = nil }
        let now = Date()
        // Touched at or before what Claude says now, so the word stands until it acts on the tab again.
        if touchedTabs[id] == nil { touchedTabs[id] = now }
        tabDeclared[id] = .init(kind: kind, note: note, at: now)
    }

    /// The sidebar's Clear Claude's Mark: the tab goes back to showing nothing until Claude touches it again.
    func clearTabMark(_ id: UUID) {
        tabDeclared[id] = nil
        touchedTabs[id] = nil
    }

    /// The Claude session folder name of the session driving a tab, if it named one.
    func sessionName(controlling id: UUID) -> String? {
        controlledTabs[id]?.connections.sorted().compactMap { sessionFolders[$0] }.first
    }

    /// A tab's page opened `child`. When Claude drives the opener, it drives the child too: the border and the
    /// sidebar's mark go with the work, and it may close the child (a copy, a popup it's done with) without asking.
    func tabOpened(_ child: UUID, by opener: UUID) {
        openedTabs.record(child: child, opener: opener)
        if let entry = controlledTabs[opener] {
            controlledTabs[child] = ControlledTab(lastActive: Date(), connections: entry.connections)
        }
        if claudeOpened.contains(opener) { claudeOpened.insert(child); noteTouched(child) }
        handoffTabOpened(child, by: opener)
    }

    /// The tabs `opener` opened since `date`, for a tool's result. Nil when there are none.
    func openedReport(by opener: UUID, since date: Date) -> String? {
        let state = store.state
        let front = state.selectedTab?.id
        let tabs = openedTabs.opened(by: opener, since: date).compactMap { id in
            state.tab(id).map { tab in
                AutomationReport.OpenedTab(id: id, title: tab.displayTitle, url: tab.url, isFront: id == front,
                                           copyOf: openedTabs.earlierCopy(of: id) { state.tab($0)?.url })
            }
        }
        return AutomationReport.opened(tabs, by: opener)
    }

    /// Refreshes a controlled tab's idle clock without adding a connection.
    func touchControlled(_ id: UUID) {
        controlledTabs[id]?.lastActive = Date()
    }

    private func disconnected(_ connection: Int) {
        for (id, var entry) in controlledTabs where entry.connections.contains(connection) {
            entry.connections.remove(connection)
            controlledTabs[id] = entry
        }
        expireIdleTabs()
    }

    /// Every 5 s while Claude drives a tab; stops once none is left.
    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIdleTabs() }
        }
        timer.tolerance = 1
        expiryTimer = timer
    }

    private func expireIdleTabs(now: Date = Date()) {
        let live = store.state.allTabIDs
        for (id, entry) in controlledTabs {
            let idle = entry.connections.isEmpty ? Timing.idleAfterDisconnect : Timing.idleWhileConnected
            if now.timeIntervalSince(entry.lastActive) > idle || !live.contains(id) {
                controlledTabs[id] = nil
                if live.contains(id) { Trace.event("tab.state", tab: id, actor: .kite, ["state": "idle"]) }
            }
        }
        forgetClosedTabs(live: live)
        if !isEnabled || controlledTabs.isEmpty {
            expiryTimer?.invalidate()
            expiryTimer = nil
        }
    }

    /// Closed tabs take their logs with them. Runs with the expiry timer, and whenever a tab's log starts, so logs of
    /// closed tabs don't pile up while no timer runs.
    private func forgetClosedTabs(live: Set<UUID>) {
        openedTabs.retain(live: live)
        for id in Array(tabDeclared.keys) where !live.contains(id) { tabDeclared[id] = nil }
        for id in Array(touchedTabs.keys) where !live.contains(id) { touchedTabs[id] = nil }
        for id in Array(tabConnection.keys) where !live.contains(id) { tabConnection[id] = nil; stallsTold[id] = nil }
        for id in Array(snapshots.keys) where !live.contains(id) { snapshots[id] = nil }
        for id in Array(activities.keys) where !live.contains(id) {
            activities[id] = nil
            trackedPages[id] = nil
        }
        for id in Array(recordedPages.keys) where !live.contains(id) {
            recordedPages[id] = nil
            network.forget(tab: id.uuidString)
        }
    }

    // MARK: Events and waiting

    /// Starts collecting a tab's DevTools events, once per page (a hibernated tab gets a new page).
    func track(_ id: UUID, page: WebPage, actions: PageActions) async throws {
        let identity = ObjectIdentifier(page)
        guard trackedPages[id]?.page != identity else { return }
        if trackedPages[id] == nil { forgetClosedTabs(live: store.state.allTabIDs) }
        trackedPages[id] = (identity, actions)
        if activities[id] == nil { activities[id] = TabActivity() }
        try await actions.startEvents(domains: ["Page", "Runtime", "Log", "Network"]) { [weak self] method, params in
            self?.received(method, params, tab: id)
        }
    }

    private func received(_ method: String, _ params: JSONValue, tab id: UUID) {
        if method == "Runtime.bindingCalled" {
            handoffBindingCalled(params, tab: id)
            return
        }
        if method == "Page.navigatedWithinDocument" { handoffPageNavigated(id) }
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
        await Trace.measure("wait") { await settleUntraced(id, startDelay: startDelay) }
    }

    private func settleUntraced(_ id: UUID, startDelay: TimeInterval) async {
        try? await Task.sleep(for: .seconds(startDelay))
        if activities[id]?.dialog != nil { return }
        let deadline = Date().addingTimeInterval(Timing.loadWait)
        while store.pages[id]?.isLoading == true, Date() < deadline, activities[id]?.dialog == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Running tool calls

    func perform(_ request: AutomationWire.Request, connection: Int, received: Double? = nil) async -> ToolOutput {
        guard isEnabled else { return .failure(.disabled) }
        // Every call is traced here, at the one door they all come through (`traceCall`).
        let actor = TraceCall.actor(client: request.client)
        let output = try? await traceCall(request.tool, arguments: request.arguments, connection: connection, actor: actor,
                                          task: request.task, parent: nil, received: received) {
            await self.performUntraced(request, connection: connection)
        }
        return output ?? .failure(AutomationError(.failed, "No result."))
    }

    private func performUntraced(_ request: AutomationWire.Request, connection: Int) async -> ToolOutput {
        if request.tool == TicketTest.wireTool {
            // Only the user's own `kite test-ticket`: a Claude task can't start another task.
            guard request.task == nil else { return .failure(AutomationError(.denied, "A Claude task can't start a ticket test.")) }
            return startTicketTest?(request.arguments) ?? .failure(AutomationError(.unsupported, "This Kite can't run ticket tests."))
        }
        do {
            let command = try AutomationCommand(tool: request.tool, arguments: request.arguments)
            // On WebKit because Chromium didn't start, the tabs aren't the user's sessions: say so, don't show empty carts.
            if AppDelegate.engineFellBack, command.tool != .ui {
                return .failure(AutomationError(.unsupported, EngineFallback.toolError))
            }
            if command.needsWindow { ensureWindow?() }
            let task = request.task.flatMap(UUID.init(uuidString:)).flatMap { isRunningTask?($0) == true ? $0 : nil }
            let started = Target(host: attachedHost, store: attachedStore)
            // A batch's steps keep their raw arguments for their trace records.
            let batchTab = request.arguments["tab"]
            let steps = (request.arguments["steps"]?.arrayValue ?? []).map { step -> JSONValue in
                var arguments = step["arguments"]?.objectValue ?? [:]
                if arguments["tab"] == nil, let batchTab { arguments["tab"] = batchTab }
                return .object(arguments)
            }
            var output = try await Self.$commandTarget.withValue(started) {
                try await Self.$agentTask.withValue(task) {
                    try await Self.$batchStepArguments.withValue(steps) { try await run(command, connection: connection) }
                }
            }
            // A handoff this connection made that ended while it did other things: it hears so on its next call.
            if command.tool != .handoff, command.tool != .handoffStatus, let news = handoffNews(for: connection) {
                output.content.append(.text(news))
            }
            if command.tool != .tabStatus, let news = stalledNews(for: connection) { output.content.append(.text(news)) }
            return output
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
                // Models sometimes send a placeholder ("${tab}"). When the task has one tab open, that's the tab it
                // means: use it rather than spend a turn on the retry.
                if let task = Self.agentTask,
                   case let open = (taskTabs[task] ?? []).filter({ store.state.tab($0) != nil && !revoked.contains($0) }),
                   open.count == 1, let only = store.state.tab(open[0]) {
                    return only
                }
                // Otherwise name the real ids so the retry needs no extra call.
                let opened = claudeOpened.filter { store.state.tab($0) != nil }.prefix(5).map(\.uuidString)
                let hint = opened.isEmpty ? "" : " Tabs you opened: " + opened.joined(separator: ", ") + "."
                throw AutomationError(.invalidArguments,
                    "\"\(string)\" isn't a tab id. Pass the id itself (a UUID, as tabs_create or tabs_context gave it), or omit tab for the front tab.\(hint) Call tabs_context for every id.")
            }
            tab = store.state.tab(id)
        } else {
            tab = store.state.selectedTab
        }
        guard let tab else { throw AutomationError(.notFound, "That tab isn't open. Call tabs_context for the open tabs.") }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
        // Nothing reads or touches a tab while the user types a password into it.
        if signIns[tab.id] != nil { throw AutomationError(.failed, SignInHandoff.busyMessage) }
        return tab
    }

    // MARK: Confirmation

    /// A pointer action Kite can't describe: a coordinate click with nothing hit-testable under it, or a
    /// drag. A ticket test refuses it on Linear, since the guard can't tell what it would press.
    func authorizeUndescribed(tab: BrowserTab) throws {
        if let task = Self.agentTask, isTicketTest?(task) == true,
           TicketTest.isLinear(store.state.tab(tab.id)?.url?.host()) {
            throw AutomationError(.denied, TicketTest.postingRefusal)
        }
    }

    func authorize(_ action: AutomationAction, tab: BrowserTab) async throws {
        // A ticket test drafts its report on Linear; only the user posts it.
        if let task = Self.agentTask, isTicketTest?(task) == true,
           let refusal = TicketTest.blocksPosting(action, host: store.state.tab(tab.id)?.url?.host()) {
            throw AutomationError(.denied, refusal)
        }
        switch AutomationPolicy.evaluate(action, host: store.state.tab(tab.id)?.url?.host()) {
        case .allow:
            // Ask Before Claude Acts: Jev takes a second look at clicks the word list let through.
            // It can only add a question, and a slow or failed answer adds none.
            if settings.askBeforeActing, case .click(let element) = action, let jev,
               let request = await Self.jevConfirmation(element, host: store.state.tab(tab.id)?.url?.host(), jev: jev) {
                try await require(request, tab: tab.id)
            }
        case .deny(let reason):
            throw AutomationError(.denied, reason)
        case .confirm(let request):
            try await require(request, tab: tab.id)
        }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
    }

    nonisolated private static func jevConfirmation(_ element: ElementDescription, host: String?,
                                                     jev: JevClient) async -> ConfirmationRequest? {
        let (state, questions) = Jev.guardrail(click: element, host: host)
        guard let answers = try? await jev.ask(state: state, questions: questions),
              Jev.needsConfirmation(answers) else { return nil }
        return ConfirmationRequest(action: "click something that may not be undoable\(host.map { " on \($0)" } ?? "")",
                                   detail: "Claude wants to click \(element.summary).")
    }

    /// Asks the user; throws if they say no. Inside a batch it stops the batch instead.
    /// With Ask Before Claude Acts off (the default) it lets the action through.
    func require(_ request: ConfirmationRequest, tab id: UUID) async throws {
        guard settings.askBeforeActing else { return }
        if Self.inBatch { throw NeedsConfirmation(request: request) }
        guard await confirm(request, tab: id) else {
            if revoked.contains(id) { throw AutomationError.stopped }
            throw AutomationError.denied(request.action)
        }
    }

    /// Shows the tab and asks. Deny is the default button; no answer within two minutes is a no.
    private func confirm(_ request: ConfirmationRequest, tab id: UUID) async -> Bool {
        guard let window = host?.window else { return false }
        store.mutateWithoutUndo { $0.select(tab: id) }
        WindowPresenter.show(window, activate: true)

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
        let asked = TraceClock.now()
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        let waited = TraceClock.monotonic() - asked.m
        Trace.phase("confirm", waited)
        Trace.event("confirm.answered", tab: id, actor: .user, duration: waited, start: asked, ["allowed": .bool(response == .alertSecondButtonReturn)])
        timeout.cancel()
        return response == .alertSecondButtonReturn
    }

    // MARK: Setup help

    /// The CLI inside the app bundle, or next to the executable in a `swift build`.
    var cliPath: String { Self.cliPath }

    static var cliPath: String {
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

    static func shellQuote(_ string: String) -> String { Shell.quote(string) }
}
