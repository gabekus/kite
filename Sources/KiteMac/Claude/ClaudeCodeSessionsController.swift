import AppKit
import KiteCore
import Observation

/// The Claude Code bar: the user's own Claude Code sessions (terminal and the Claude app's Code
/// tab), pinned ones and the last few, read from Claude Code's transcripts. Picking one shows its
/// conversation, live while it runs elsewhere, and a message sent from Kite continues it with
/// `claude -p --resume`, in its folder, with the user's own settings and tools. No browser
/// control: these are coding sessions, not Kite tasks.
@MainActor
@Observable
final class ClaudeCodeSessionsController {
    private(set) var pinned: [ClaudeCodeSession] = []
    private(set) var recent: [ClaudeCodeSession] = []
    /// Each shown session's conversation. `ClaudeTask` is only the transcript and run state here.
    private(set) var conversations: [String: ClaudeTask] = [:]
    /// Sessions with a Claude Code process Kite started.
    private(set) var runningIDs: Set<String> = []
    /// Kite's runs that finished while the bar wasn't showing them.
    private(set) var unreadIDs: Set<String> = []
    private(set) var pins: ClaudeCodePins
    /// A session Kite just started, until its transcript shows up in the list.
    private(set) var started: [String: ClaudeCodeSession] = [:]
    /// The shown session, kept up to date when it's no longer one of the listed ones.
    private(set) var shown: ClaudeCodeSession?

    var permissions: ClaudeCodeInvocation.Permissions = UserDefaults.standard.string(forKey: ClaudeCodeInvocation.Permissions.defaultsKey)
        .flatMap(ClaudeCodeInvocation.Permissions.init) ?? .acceptEdits {
        didSet { UserDefaults.standard.set(permissions.rawValue, forKey: ClaudeCodeInvocation.Permissions.defaultsKey) }
    }

    /// The session the bar shows; nil lists them.
    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            shown = selectedID.flatMap(session)
            if let selectedID {
                unreadIDs.remove(selectedID)
                reloadConversation(selectedID)
            }
        }
    }

    /// The user's home; a test profile's fixture folder (`ClaudeCodeSessions.home`).
    @ObservationIgnored private let home = ClaudeCodeSessions.home(environment: ProcessInfo.processInfo.environment,
                                                                   userHome: FileManager.default.homeDirectoryForCurrentUser)
    @ObservationIgnored private let pinsURL: URL
    /// Kite's own ⌘J tasks run Claude Code in here: they're not the user's sessions.
    @ObservationIgnored private let kiteDirectories: [String]
    @ObservationIgnored private var runs: [String: Run] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshing = false
    /// A change came in while a listing ran: list again once it's done (no sooner than 2 seconds on).
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var lastListing: Date?
    @ObservationIgnored private var trailingListing: DispatchWorkItem?
    /// The bar is open, in `barWindow`.
    @ObservationIgnored private var barOpen = false
    @ObservationIgnored private weak var barWindow: NSWindow?
    @ObservationIgnored private var watchObserver: NSObjectProtocol?
    /// Each loaded conversation's transcript date, so a poll reloads only what changed.
    @ObservationIgnored private var loadedDates: [String: Date] = [:]
    /// Each shown conversation's place in its transcript, so a reload reads only what was added.
    @ObservationIgnored private var readers: [String: ClaudeCodeTranscriptReader] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    /// The Claude app's titles for its Code tab's sessions.
    @ObservationIgnored private var desktop = ClaudeDesktopSessions.Index()
    @ObservationIgnored private var activity: NSObjectProtocol?

    private final class Run {
        let process: Process
        var stopped = false
        let stderr = ClaudeProcessOutput()

        init(process: Process) { self.process = process }
    }

    init(supportDirectory: URL) {
        pinsURL = ClaudeCodePins.fileURL(supportDirectory: supportDirectory)
        pins = ClaudeCodePins.load(from: pinsURL)
        kiteDirectories = [supportDirectory.appendingPathComponent("Claude", isDirectory: true).path]
    }

    var isRunningAny: Bool { !runningIDs.isEmpty }

    func isRunning(_ id: String) -> Bool { runningIDs.contains(id) }

    func isPinned(_ id: String) -> Bool { pins.isPinned(id) }

    func session(_ id: String) -> ClaudeCodeSession? {
        pinned.first { $0.id == id } ?? recent.first { $0.id == id } ?? started[id] ?? (shown?.id == id ? shown : nil)
    }

    func conversation(_ id: String) -> ClaudeTask? { conversations[id] }

    /// Changed in the last minute and a half by something other than Kite's own last turn:
    /// probably running in a terminal or the Claude app right now.
    func isActiveElsewhere(_ session: ClaudeCodeSession) -> Bool {
        session.isLive() && !(kiteRanAt[session.id].map { session.updatedAt.timeIntervalSince($0) <= 5 } ?? false)
    }

    // MARK: Watching

    /// Changes under the watched folders come in this long after the first one, together.
    static let watchLatency: TimeInterval = 0.5

    /// While the bar is open and its window can be seen, the list and the shown conversation follow
    /// the transcripts: an FSEvents stream on them, not a poll, listing again at most every 2 seconds
    /// and only for changes to sessions' transcripts. Kite needn't be in front (Claude Code in a
    /// terminal beside it), but a covered or minimized window stops watching. Opening the bar or the
    /// window showing again lists them again.
    func setVisible(_ visible: Bool, in window: NSWindow?) {
        let opened = visible && !barOpen
        barOpen = visible
        barWindow = window
        removeWatchObservers()
        if visible, let window {
            watchObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWatching() }
            }
        }
        updateWatching()
        // Watching lists them as it starts; opened in a covered window, the bar still gets one listing.
        if opened, watcher == nil { refresh() }
    }

    private func removeWatchObservers() {
        if let watchObserver { NotificationCenter.default.removeObserver(watchObserver) }
        watchObserver = nil
    }

    isolated deinit {
        removeWatchObservers()
        watcher?.stop()
    }

    /// KITE_TEST_ASSUME_VISIBLE=1 (test profiles only): watch as if the window could be seen, since a
    /// background test window is always covered.
    private static let assumeVisible = UIDiagnostics.enabledByEnvironment
        && ProcessInfo.processInfo.environment["KITE_TEST_ASSUME_VISIBLE"] == "1"

    private var shouldWatch: Bool {
        guard barOpen, let barWindow else { return false }
        return Self.assumeVisible || barWindow.occlusionState.contains(.visible)
    }

    private func updateWatching() {
        guard shouldWatch else {
            watcher?.stop()
            watcher = nil
            trailingListing?.cancel()
            trailingListing = nil
            return
        }
        guard watcher == nil else { return }
        let projects = DirectoryWatcher.resolved(ClaudeCodeSessions.projectsDirectory(home: home))
        let desktop = DirectoryWatcher.resolved(ClaudeDesktopSessions.directory(home: home))
        let excluding = kiteDirectories.map { DirectoryWatcher.resolved(URL(fileURLWithPath: $0)) } + kiteDirectories
        watcher = DirectoryWatcher(paths: ClaudeCodeSessions.watchedDirectories(home: home), latency: Self.watchLatency) { [weak self] paths, rescan in
            // Dropped or coalesced events don't name every file: list rather than guess.
            guard rescan || paths.contains(where: {
                ClaudeCodeSessions.isListingChange($0, projects: projects, desktop: desktop, excluding: excluding)
            }) else { return }
            self?.listSoon()
        }
        refresh()
    }

    /// A transcript changed: lists again now, or 2 seconds after the last listing started (one call
    /// for everything that changed in between).
    private func listSoon() {
        guard trailingListing == nil else { return }
        let delay = ClaudeCodeSessions.listingDelay(lastStarted: lastListing)
        if delay == 0, !refreshing { return refresh() }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingListing = nil
            if self.refreshing { self.refreshAgain = true } else { self.refresh() }
        }
        trailingListing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: work)
    }

    /// Lists the sessions again (off the main thread), and reloads the shown one if it changed.
    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        lastListing = Date()
        if UIDiagnostics.enabledByEnvironment { NSLog("Kite: Claude Code sessions listing") }
        let home = home, pinnedIDs = pins.pinned, excluding = kiteDirectories, previous = desktop
        let known = Dictionary((pinned + recent + [shown].compactMap { $0 }).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shownID = selectedID
        Task.detached(priority: .userInitiated) { [weak self] in
            let desktop = ClaudeDesktopSessions.index(home: home, previous: previous)
            let list = ClaudeCodeSessions.list(home: home, pinned: pinnedIDs, excluding: excluding, known: known,
                                               desktop: desktop.byCLISessionID, shown: shownID)
            await self?.listed(list, desktop: desktop)
        }
    }

    private func listed(_ list: (pinned: [ClaudeCodeSession], recent: [ClaudeCodeSession], shown: ClaudeCodeSession?),
                        desktop: ClaudeDesktopSessions.Index) {
        refreshing = false
        // A change during the listing waits out the 2 seconds too, rather than listing straight again.
        if refreshAgain {
            refreshAgain = false
            listSoon()
        }
        self.desktop = desktop
        if pinned != list.pinned { pinned = list.pinned }
        if recent != list.recent { recent = list.recent }
        // A listing started before the selection changed says nothing about the new one.
        if let listed = list.shown, listed.id == selectedID, shown != listed { shown = listed }
        let listedIDs = Set((pinned + recent + [shown].compactMap { $0 }).map(\.id))
        if started.keys.contains(where: listedIDs.contains) { started = started.filter { !listedIDs.contains($0.key) } }
        if let selectedID, runs[selectedID] == nil, let session = session(selectedID),
           loadedDates[selectedID] != session.updatedAt {
            reloadConversation(selectedID)
        }
    }

    /// Reads what was added to the session's transcript into its conversation (not while Kite's
    /// own run streams into it).
    private func reloadConversation(_ id: String) {
        guard runs[id] == nil, !reading.contains(id) else { return }
        reading.insert(id)
        let home = home
        let known = session(id)?.transcript
        var reader = readers[id] ?? ClaudeCodeTranscriptReader()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let file = known ?? ClaudeCodeSessions.transcript(id: id, home: home) else {
                await self?.loaded(id, reader: nil, date: nil)
                return
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            _ = reader.read(file)
            await self?.loaded(id, reader: reader, date: date)
        }
    }

    private func loaded(_ id: String, reader: ClaudeCodeTranscriptReader?, date: Date?) {
        reading.remove(id)
        guard let reader, runs[id] == nil else { return }
        readers[id] = reader
        loadedDates[id] = date
        let entries = reader.entries
        var conversation = conversations[id] ?? Self.emptyConversation(id)
        guard conversation.entries != entries || conversation.status == .running else { return }
        conversation.entries = entries
        if conversation.status == .running { conversation.status = .done }
        conversations[id] = conversation
    }

    private static func emptyConversation(_ id: String) -> ClaudeTask {
        var conversation = ClaudeTask(goal: "")
        conversation.entries = []
        conversation.sessionID = id
        conversation.status = .done
        return conversation
    }

    // MARK: Pins

    func togglePin(_ id: String) {
        pins.toggle(id)
        savePins()
        refresh()
    }

    private func savePins() {
        do { try pins.save(to: pinsURL) } catch { NSLog("Kite: couldn't save Claude Code pins: \(error)") }
    }

    // MARK: Sending

    /// Another turn on a session, in its folder.
    func send(_ text: String, to id: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runs[id] == nil else { return }
        guard let directory = session(id)?.directory else {
            return fail(id, "Kite can't tell which folder this session works in, so it can't continue it here. Open it in the Claude app instead.")
        }
        var conversation = conversations[id] ?? Self.emptyConversation(id)
        if let session = self.session(id), isActiveElsewhere(session) {
            conversation.append(.init(.note, "This session changed in the last minute. If it's still running in a terminal or the Claude app, both will add to it."))
        }
        conversation.followUp(text)
        conversations[id] = conversation
        launch(id, prompt: text, directory: directory, resume: id, newSession: nil)
    }

    /// A new session in `folder`, under an id Kite picks, shown right away.
    @discardableResult
    func startNew(in folder: String, text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        // Claude Code keys transcripts by the real path (/tmp is /private/tmp).
        let folder = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let transcript = ClaudeCodeSessions.projectsDirectory(home: home)
            .appendingPathComponent(ClaudeCodeFolders.transcriptKey(folder), isDirectory: true)
            .appendingPathComponent("\(id).jsonl")
        started[id] = ClaudeCodeSession(id: id, transcript: transcript, directory: folder,
                                        title: ClaudeTask.title(for: text), gitBranch: nil, updatedAt: Date())
        var conversation = Self.emptyConversation(id)
        conversation.followUp(text)
        conversations[id] = conversation
        selectedID = id
        launch(id, prompt: text, directory: folder, resume: nil, newSession: id)
        return id
    }

    func stop(_ id: String) {
        guard let run = runs[id] else { return }
        run.stopped = true
        if run.process.isRunning { run.process.terminate() }
    }

    func stopAll() {
        for id in runs.keys { stop(id) }
    }

    /// Opens the session in the Claude app's Code tab. Returns what went wrong, or nil.
    func openInDesktop(_ id: String) {
        if let failure = ClaudeDesktop.openSession(id) { note(id, "Couldn't open this in Claude: \(failure)") }
    }

    // MARK: Running Claude Code

    private func launch(_ id: String, prompt: String, directory: String, resume: String?, newSession: String?) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return fail(id, "The folder \(directory) isn't there any more.")
        }
        let arguments = ClaudeCodeInvocation.arguments(resume: resume, newSession: newSession, permissions: permissions)
        let placeholder = Run(process: Process())
        runs[id] = placeholder
        updateRunning()
        Task.detached { [weak self] in
            let claude = ClaudeCommand.find()
            await self?.spawn(id, claude: claude, arguments: arguments,
                              directory: folder, prompt: prompt, placeholder: placeholder)
        }
    }

    private func spawn(_ id: String, claude: ClaudeCommand?, arguments: [String],
                       directory: URL, prompt: String, placeholder: Run) {
        guard runs[id] === placeholder, !placeholder.stopped else {
            runs[id] = nil
            updateRunning()
            conversations[id]?.processExited(status: 0, stderr: "", stopped: true)
            return
        }
        guard let claude else {
            runs[id] = nil
            updateRunning()
            return fail(id, "Couldn't find Claude Code. Install it, or check that `claude` runs in Terminal.")
        }
        let process = claude.process(arguments: arguments, directory: directory)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let run = Run(process: process)
        let stdout = ClaudeProcessOutput()
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                finished.leave()
                return
            }
            let events = stdout.lines(from: chunk).flatMap(ClaudeStream.events(from:))
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(events, to: id) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { run.stderr.append(chunk) }
        }
        process.terminationHandler = { _ in finished.leave() }
        finished.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.exited(id, run: run) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            runs[id] = nil
            updateRunning()
            return fail(id, "Couldn't start Claude Code: \(error.localizedDescription)")
        }
        runs[id] = run
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: Data(prompt.utf8))
            try? handle.close()
        }
    }

    /// `id` is where the run started; Claude Code may report a new session id (a fork), which the
    /// conversation, pin and selection then follow.
    private func apply(_ events: [ClaudeStreamEvent], to id: String) {
        var key = id
        for event in events {
            if case let .session(newID, _, _) = event, newID != key, runs[key] != nil, conversations[newID] == nil {
                rekey(key, to: newID)
                key = newID
            }
            conversations[key]?.apply(event)
        }
    }

    private func rekey(_ old: String, to new: String) {
        runs[new] = runs.removeValue(forKey: old)
        readers[new] = readers.removeValue(forKey: old)
        conversations[new] = conversations.removeValue(forKey: old)
        if var moved = started.removeValue(forKey: old) ?? session(old) {
            moved.id = new
            started[new] = moved
        }
        if pins.isPinned(old) {
            pins.rename(old, to: new)
            savePins()
        }
        if selectedID == old { selectedID = new }
        updateRunning()
        // The run's exit is reported under the id it started with.
        renamed[old] = new
    }

    @ObservationIgnored private var renamed: [String: String] = [:]
    /// When Kite's last turn on each session ended.
    @ObservationIgnored private var kiteRanAt: [String: Date] = [:]

    private func exited(_ launchedID: String, run: Run) {
        let id = renamed.removeValue(forKey: launchedID) ?? launchedID
        guard runs[id] === run else { return }
        runs[id] = nil
        updateRunning()
        conversations[id]?.processExited(status: run.process.terminationStatus, stderr: run.stderr.text, stopped: run.stopped)
        conversations[id]?.unread = false
        if selectedID != id { unreadIDs.insert(id) }
        // The transcript now has the turn; the next poll keeps the conversation in step with it.
        loadedDates[id] = nil
        kiteRanAt[id] = Date()
        refresh()
    }

    private func note(_ id: String, _ text: String) {
        var conversation = conversations[id] ?? Self.emptyConversation(id)
        conversation.append(.init(.note, text))
        conversations[id] = conversation
    }

    private func fail(_ id: String, _ message: String) {
        var conversation = conversations[id] ?? Self.emptyConversation(id)
        conversation.append(.init(.error, message))
        conversation.status = .failed
        conversations[id] = conversation
    }

    /// Keeps the Mac from idle-sleeping while a turn runs, like ⌘J's tasks.
    private func updateRunning() {
        if runningIDs != Set(runs.keys) { runningIDs = Set(runs.keys) }
        if runs.isEmpty, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        } else if !runs.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Claude Code is working on a session in Kite")
        }
    }
}

/// Bytes from a Claude Code process's pipe, read on a background handler.
final class ClaudeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var buffer = LineBuffer()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 { data = data.suffix(8_192) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Complete stream-json lines.
    func lines(from chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return (try? buffer.append(chunk)) ?? []
    }
}
