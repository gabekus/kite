import AppKit
import KiteCore
import Observation
import UserNotifications

/// Claude Tasks: Kite's own Claude. The user gives it a goal; Kite runs Claude Code
/// headless (`claude -p`) on their Claude login, with Kite's MCP server as its only
/// tools, and the task works in background tabs in its own folder of the Claude space.
///
/// While any task runs, the Mac doesn't idle-sleep and closing the window doesn't quit
/// Kite. A finished task posts a notification and badges the Dock icon.
@MainActor
@Observable
final class ClaudeTasksController {
    private(set) var tasks: [ClaudeTask] = []
    /// Tasks with a Claude Code process, observable (for the sidebar button and the panel).
    private(set) var runningIDs: Set<UUID> = []
    /// Claude Code is installed and signed in, and Kite's tools are on. Until then the
    /// sidebar's Claude button shows a yellow dot, and clicking it sets everything up.
    private(set) var isSetUp = UserDefaults.standard.bool(forKey: ClaudeTasksController.setUpKey)
    var isSettingUp = false

    static let setUpKey = "claudeSetUp"

    /// Where ⌘J sends a request: the Claude desktop app (one Claude, with its memory and
    /// history) or a headless Claude Code task in Kite. Desktop when it's installed.
    var runsIn: ClaudeRunsIn = UserDefaults.standard.string(forKey: ClaudeRunsIn.defaultsKey).flatMap(ClaudeRunsIn.init)
        ?? (ClaudeDesktop.isInstalled ? .desktop : .kite) {
        didSet { UserDefaults.standard.set(runsIn.rawValue, forKey: ClaudeRunsIn.defaultsKey) }
    }

    func markSetUp(_ setUp: Bool) {
        isSetUp = setUp
        UserDefaults.standard.set(setUp, forKey: Self.setUpKey)
    }
    /// The task the panel shows.
    var selectedID: UUID? {
        didSet { if let selectedID { markRead(selectedID) } }
    }
    /// True while the panel is on screen, so finished tasks it shows don't notify.
    @ObservationIgnored var isPanelVisible: () -> Bool = { false }
    /// Brings the panel up on a task (a notification was clicked).
    @ObservationIgnored var showPanel: ((UUID) -> Void)?

    @ObservationIgnored private let store: BrowserStore
    @ObservationIgnored let automation: AutomationController
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let workDirectory: URL
    @ObservationIgnored private var runs: [UUID: Run] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var notifications: NotificationDelegate?

    /// One `claude -p` process: one turn of a task.
    private final class Run {
        let process: Process
        var stopped = false
        let stderr = Collector()

        init(process: Process) { self.process = process }
    }

    /// Bytes from a pipe's background handler, read on the main thread at the end.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var lines = LineBuffer()

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

        /// For stdout: complete stream-json lines.
        func lines(from chunk: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return (try? lines.append(chunk)) ?? []
        }
    }

    init(store: BrowserStore, automation: AutomationController, supportDirectory: URL) {
        self.store = store
        self.automation = automation
        fileURL = ClaudeTaskList.fileURL(supportDirectory: supportDirectory)
        workDirectory = supportDirectory.appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("Work", isDirectory: true)
        tasks = ClaudeTaskList.load(from: fileURL).tasks
        automation.isRunningTask = { [weak self] id in self?.runs[id] != nil }
        automation.taskOpenedTab = { [weak self] task, tab in self?.file(tab, under: task) }
        updateBadge()
    }

    var isRunningAny: Bool { !runningIDs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { runningIDs.contains(id) }

    var unreadCount: Int { tasks.filter(\.unread).count }

    func task(_ id: UUID) -> ClaudeTask? { tasks.first { $0.id == id } }

    // MARK: Starting and stopping

    /// Starts a new task. `tab` attaches the tab the user is looking at ("Ask about this tab").
    func start(goal: String, tab: BrowserTab?) {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        var task = ClaudeTask(goal: goal)
        if let tab {
            task.append(ClaudeTask.Entry(.note, "Attached “\(tab.displayTitle)”."))
        }
        if !automation.isEnabled {
            // Starting a task is the user asking Claude to use the browser.
            automation.setEnabled(true)
            if automation.isEnabled {
                task.append(ClaudeTask.Entry(.note, "Turned on Allow Claude to Control the Browser (Kite menu)."))
            }
        }
        tasks.insert(task, at: 0)
        selectedID = task.id
        guard automation.isEnabled else {
            return fail(task.id, "Kite couldn't turn on Claude's connection, so the task can't use the browser.")
        }
        requestNotificationPermission()
        let context = tab.map {
            ClaudeInvocation.TabContext(id: $0.id, title: $0.displayTitle, url: $0.url?.absoluteString ?? "")
        }
        launch(task.id, prompt: ClaudeInvocation.prompt(goal: goal, tab: context), resume: nil)
    }

    // MARK: Claude desktop app

    /// Sends a ⌘J request to a new chat in the Claude desktop app, which has Kite's tools,
    /// so it happens in the same Claude as the user's other chats. Returns false when
    /// Desktop isn't installed (the caller runs it in Kite instead).
    func handOffToDesktop(goal: String, tab: BrowserTab?) -> Bool {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, ClaudeDesktop.isInstalled else { return false }
        // Desktop's Claude reaches the browser through Kite's MCP server.
        if !automation.isEnabled { automation.setEnabled(true) }
        if !ClaudeDesktop.isLinked {
            let cli = automation.cliPath, profile = automation.profileOverride
            Task.detached { _ = ClaudeDesktop.link(cli: cli, profile: profile) }
        }
        let context = tab.map {
            ClaudeInvocation.TabContext(id: $0.id, title: $0.displayTitle, url: $0.url?.absoluteString ?? "")
        }
        return ClaudeDesktop.openChat(prompt: ClaudeDesktopLink.prompt(goal: goal, tab: context))
    }

    /// A finished task that ran in Kite can carry on in Desktop's Code tab, as the same session.
    func canOpenInDesktop(_ id: UUID) -> Bool {
        guard ClaudeDesktop.isInstalled, runs[id] == nil, let task = task(id) else { return false }
        return task.sessionID != nil
    }

    func openInDesktop(_ id: UUID) {
        guard canOpenInDesktop(id), let sessionID = task(id)?.sessionID else { return }
        Task.detached { [weak self] in
            let failure = ClaudeDesktop.openSession(sessionID)
            await MainActor.run {
                guard let self, let i = self.index(id) else { return }
                self.tasks[i].append(ClaudeTask.Entry(.note, failure.map { "Couldn't open this in Claude: \($0)" }
                    ?? "Opened in the Claude app. Carry on there; it's the same conversation."))
                self.scheduleSave()
            }
        }
    }

    /// Another turn on a finished task, in the same Claude conversation.
    func followUp(_ id: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runs[id] == nil, let i = index(id) else { return }
        tasks[i].followUp(text)
        if !automation.isEnabled { automation.setEnabled(true) }
        launch(id, prompt: text, resume: tasks[i].sessionID)
    }

    func stop(_ id: UUID) {
        guard let run = runs[id] else { return }
        run.stopped = true
        // A run still looking for Claude Code has no process yet; spawn sees `stopped`.
        if run.process.isRunning { run.process.terminate() }
    }

    func stopAll() {
        for id in runs.keys { stop(id) }
    }

    /// Forgets a finished task, and closes its tabs.
    func remove(_ id: UUID) {
        guard runs[id] == nil else { return }
        closeTabs(id)
        tasks.removeAll { $0.id == id }
        if selectedID == id { selectedID = tasks.first?.id }
        scheduleSave()
        updateBadge()
    }

    // MARK: Tabs

    /// The task's folder in the Claude space, made the first time it opens a tab.
    private func file(_ tab: UUID, under id: UUID) {
        guard let i = index(id) else { return }
        let title = tasks[i].title
        let existing = tasks[i].folderID.flatMap { folder in store.state.folder(matching: folder.uuidString)?.folder.id }
        let folder = existing ?? store.mutate { state -> UUID in
            let space = state.claudeSpace()
            return state.createFolder(name: title, inSpace: state.space(matching: space.uuidString) ?? 0)
        }
        store.mutate { _ = $0.moveTab(tab, toFolder: folder) }
        tasks[i].folderID = folder
        if !tasks[i].tabIDs.contains(tab) { tasks[i].tabIDs.append(tab) }
        scheduleSave()
    }

    func hasTabs(_ id: UUID) -> Bool {
        guard let task = task(id) else { return false }
        return task.tabIDs.contains { store.state.tab($0) != nil }
    }

    /// Shows the task's first open tab.
    func showTabs(_ id: UUID) {
        guard let task = task(id), let tab = task.tabIDs.first(where: { store.state.tab($0) != nil }) else { return }
        store.mutate { $0.select(tab: tab) }
        automation.host?.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the task's folder and every tab in it.
    func closeTabs(_ id: UUID) {
        guard let i = index(id) else { return }
        if let folder = tasks[i].folderID { store.mutate { _ = $0.removeFolder(folder) } }
        // Tabs the user dragged out of the folder stay.
        tasks[i].folderID = nil
        tasks[i].tabIDs = tasks[i].tabIDs.filter { store.state.tab($0) != nil }
        scheduleSave()
    }

    // MARK: Running Claude Code

    private func launch(_ id: UUID, prompt: String, resume: String?) {
        let cli = automation.cliPath, profile = automation.profileOverride
        let directory = workDirectory
        let jev = automation.jev
        // What the user just asked (the goal, or the follow-up), without the attached tab.
        let goal = task(id)?.entries.last { $0.kind == .user }?.text
        // A placeholder so the task counts as running (and keeps Kite awake) while Claude Code is found.
        let placeholder = Run(process: Process())
        runs[id] = placeholder
        updateActivity()
        Task.detached { [weak self] in
            // Jev sizes the goal while Claude Code is found: a quick lookup runs on the fast model.
            async let model = Self.model(for: goal, jev: jev)
            let claude = ClaudeConnect.findClaude()
            let environment = Self.environment()
            let chosen = await model
            let arguments = ClaudeInvocation.arguments(kiteCLI: cli, profile: profile, taskID: id, resume: resume, model: chosen)
            await self?.noteModel(chosen, for: id)
            await self?.spawn(id, claude: claude, arguments: arguments, environment: environment,
                              directory: directory, prompt: prompt, placeholder: placeholder)
        }
    }

    /// Each turn is sized on its own, so a quick follow-up on a long task is quick too.
    nonisolated private static func model(for goal: String?, jev: JevClient?) async -> String? {
        guard let goal, let jev else { return nil }
        let (state, questions) = Jev.routing(goal: goal)
        guard let answers = try? await jev.ask(state: state, questions: questions) else { return nil }
        return Jev.model(for: answers)
    }

    private func noteModel(_ model: String?, for id: UUID) {
        guard let model, let i = index(id) else { return }
        tasks[i].append(ClaudeTask.Entry(.note, "Quick lookup, so this runs on the fast model (\(model.capitalized))."))
    }

    private func spawn(_ id: UUID, claude: String?, arguments: [String], environment: [String: String],
                       directory: URL, prompt: String, placeholder: Run) {
        guard runs[id] === placeholder, !placeholder.stopped else {
            runs[id] = nil
            updateActivity()
            if let i = index(id) {
                tasks[i].processExited(status: 0, stderr: "", stopped: true)
                scheduleSave()
            }
            return
        }
        guard let claude else {
            runs[id] = nil
            updateActivity()
            markSetUp(false)
            return fail(id, "Couldn't find Claude Code. Click the Claude button in the sidebar to set it up again.")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let run = Run(process: process)
        let stdout = Collector()
        // Done once the output has ended and the process has exited, in either order.
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
            updateActivity()
            return fail(id, "Couldn't start Claude Code: \(error.localizedDescription)")
        }
        runs[id] = run
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: Data(prompt.utf8))
            try? handle.close()
        }
    }

    private func apply(_ events: [ClaudeStreamEvent], to id: UUID) {
        guard let i = index(id) else { return }
        let wasRunning = tasks[i].status == .running
        for event in events {
            tasks[i].apply(event)
            if case .session(_, _, false) = event {
                tasks[i].append(ClaudeTask.Entry(.error, "Kite's tools didn't connect to Claude Code. Is Allow Claude to Control the Browser on?"))
            }
        }
        if wasRunning, tasks[i].status.isFinished { finished(tasks[i]) }
        scheduleSave()
    }

    private func exited(_ id: UUID, run: Run) {
        guard runs[id] === run else { return }
        runs[id] = nil
        updateActivity()
        guard let i = index(id) else { return }
        let wasRunning = tasks[i].status == .running
        tasks[i].processExited(status: run.process.terminationStatus, stderr: run.stderr.text, stopped: run.stopped)
        if wasRunning, tasks[i].status == .failed { finished(tasks[i]) }
        scheduleSave()
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let i = index(id) else { return }
        tasks[i].append(ClaudeTask.Entry(.error, message))
        tasks[i].status = .failed
        scheduleSave()
    }

    /// GUI apps get a bare PATH. Claude Code may be a Node script, so give it the login shell's.
    nonisolated static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let (status, output) = ClaudeConnect.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, path.contains("/") { environment["PATH"] = path }
        // Kite's own test switches mustn't leak into Claude Code.
        environment["KITE_DIAGNOSTICS"] = nil
        return environment
    }

    // MARK: Awake, notifications, badge

    /// Keeps the Mac from idle-sleeping while a task runs (a closed lid still sleeps).
    private func updateActivity() {
        if runningIDs != Set(runs.keys) { runningIDs = Set(runs.keys) }
        if runs.isEmpty, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        } else if !runs.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Claude is working on a task in Kite")
        }
    }

    private func finished(_ task: ClaudeTask) {
        if isPanelVisible() && NSApp.isActive && selectedID == task.id {
            markRead(task.id)
        } else {
            notify(task)
        }
        updateBadge()
    }

    private func markRead(_ id: UUID) {
        guard let i = index(id), tasks[i].unread else { return }
        tasks[i].unread = false
        scheduleSave()
        updateBadge()
    }

    private func updateBadge() {
        let unread = unreadCount
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    /// Notifications need a real app bundle (not a `swift run` build).
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify, notifications == nil else { return }
        let delegate = NotificationDelegate { [weak self] id in
            MainActor.assumeIsolated {
                self?.selectedID = id
                self?.showPanel?(id)
            }
        }
        notifications = delegate
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ task: ClaudeTask) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = task.status == .done ? "Claude finished: \(task.title)" : "Claude couldn't finish: \(task.title)"
        let body = (task.status == .done ? task.lastReply : task.entries.last { $0.kind == .error }?.text) ?? ""
        content.body = body.count > 240 ? String(body.prefix(239)) + "…" : body
        content.sound = .default
        content.userInfo = ["task": task.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Saving

    private func index(_ id: UUID) -> Int? { tasks.firstIndex { $0.id == id } }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try ClaudeTaskList(tasks: tasks).save(to: fileURL)
        } catch {
            NSLog("Kite: couldn't save Claude tasks: \(error)")
        }
    }
}

/// Opens the panel on the task a clicked notification was about, and shows notifications
/// even while Kite is in front (the panel may be closed).
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let open: @Sendable (UUID) -> Void

    init(open: @escaping @Sendable (UUID) -> Void) {
        self.open = open
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let string = response.notification.request.content.userInfo["task"] as? String, let id = UUID(uuidString: string) {
            DispatchQueue.main.async { self.open(id) }
        }
        completionHandler()
    }
}
