import KiteCore
import Observation
import SwiftUI

/// Claude in the browser: ⌘J or the sidebar's Claude button opens the Claude bar, which
/// sits where ⌘T's bar does. Type a goal and Return hands it to the Claude desktop app
/// (one Claude, with Kite's tools), or starts a task here in Kite, and the bar follows that
/// task as it works. Esc hides it; the task keeps going.
@MainActor
@Observable
final class ClaudeBubbleModel {
    var tasks: ClaudeTasksController?
    /// The user's own Claude Code sessions, for the bar's Claude Code side (⌃⌘J).
    var code: ClaudeCodeSessionsController?
    private(set) var isOpen = false

    /// What the bar shows: Kite's Claude (⌘J tasks) or the user's Claude Code sessions.
    enum Mode { case tasks, code }
    private(set) var mode: Mode = .tasks {
        didSet { if mode != oldValue { updateWatching() } }
    }
    /// The Claude Code side's draft, apart from ⌘J's.
    var codeDraft = ""
    /// A folder picked for a new Claude Code session, until its first message is sent.
    var newSessionFolder: String?
    /// The task the bubble follows; nil shows a fresh composer.
    var taskID: UUID?
    var draft = ""
    var attachTab = false
    /// Bumped to move focus into the text field.
    var focusToken = 0
    @ObservationIgnored var onOpenChange: (Bool) -> Void = { _ in }
    /// Opens a Claude Project's page in a Peek and posts the message there.
    @ObservationIgnored var postToProject: (_ page: URL, _ message: String) -> Void = { _, _ in }

    /// Opens on `task`, or on the task it showed last (a fresh composer once that's done and read).
    func open(task: UUID? = nil, attachTab: Bool = false) {
        guard tasks != nil else { return }
        mode = .tasks
        if let task { taskID = task }
        if attachTab { taskID = nil; self.attachTab = true }
        if let taskID { tasks?.selectedID = taskID }
        setOpen(true)
        focusToken += 1
    }

    func close() { setOpen(false) }

    func toggle() { isOpen && mode == .tasks ? close() : open() }

    /// Opens the Claude Code side: the sessions list, or the session it showed last.
    func openCode(session: String? = nil) {
        guard let code else { return }
        if let session { code.selectedID = session; newSessionFolder = nil }
        mode = .code
        setOpen(true)
        focusToken += 1
    }

    func toggleCode() { isOpen && mode == .code ? close() : openCode() }

    /// Back to the Claude Code sessions list.
    func showSessions() {
        code?.selectedID = nil
        newSessionFolder = nil
        codeDraft = ""
        focusToken += 1
    }

    /// A new Claude Code session in `folder`: the field takes its first message.
    func newSession(in folder: String) {
        code?.selectedID = nil
        newSessionFolder = folder
        focusToken += 1
    }

    /// Return in the Claude Code field: a message to the shown session, or a new session's first.
    func sendCode() {
        guard let code else { return }
        let text = codeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = code.selectedID {
            code.send(text, to: id)
        } else if let folder = newSessionFolder {
            code.startNew(in: folder, text: text)
            newSessionFolder = nil
        } else {
            return
        }
        codeDraft = ""
    }

    private func updateWatching() {
        code?.setVisible(isOpen && mode == .code)
    }

    func newTask() {
        taskID = nil
        draft = ""
        focusToken += 1
    }

    /// Sends the draft where the space's route says.
    func start(frontTab: BrowserTab?, space: UUID) {
        guard let tasks else { return }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        let tab = attachTab ? frontTab : nil
        switch tasks.route(for: space) {
        case let .project(id, _):
            let context = tab.map {
                ClaudeInvocation.TabContext(id: $0.id, title: $0.displayTitle, url: $0.url?.absoluteString ?? "")
            }
            draft = ""
            attachTab = false
            close()
            postToProject(ClaudeRoute.projectURL(id: id), ClaudeRoute.projectMessage(goal: goal, tab: context))
            return
        case let .folder(path):
            tasks.start(goal: goal, tab: tab, directory: path, space: space)
            taskID = tasks.selectedID
            draft = ""
            attachTab = false
            return
        case .newChat:
            break
        }
        // In the Claude app it's the same Claude as the user's other chats, with its memory.
        if tasks.runsIn == .desktop, tasks.handOffToDesktop(goal: goal, tab: tab) {
            draft = ""
            attachTab = false
            close()
            return
        }
        tasks.start(goal: goal, tab: tab, space: space)
        taskID = tasks.selectedID
        draft = ""
        attachTab = false
    }

    /// Test This Ticket: a ticket test on `ticket`, followed in the bar.
    func testTicket(_ ticket: LinearTicket, tasks: ClaudeTasksController) {
        guard let id = tasks.testTicket(TicketTest.Request(ticket: ticket)) else { return }
        open(task: id)
    }

    func followUp() {
        guard let tasks, let taskID else { return }
        tasks.followUp(taskID, text: draft)
        draft = ""
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return updateWatching() }
        isOpen = open
        updateWatching()
        onOpenChange(open)
    }
}

/// ⌘J: the ⌘T bar in Claude's colours. Same panel, width, position and field as the
/// command bar; the Claude mark sits where the magnifier does, and the task's transcript
/// fills the space the suggestions would. Covers the window while open, like ⌘T: a
/// click outside or Esc hides it, and the task keeps going.
struct ClaudeBubble: View {
    let model: ClaudeBubbleModel
    let store: BrowserStore
    @FocusState private var focused: Bool

    private typealias C = ArcMetrics.CommandBar

    enum Metrics {
        /// The mark is drawn a little inside the 18pt icon frame, like the magnifier's ink.
        static let markSize: CGFloat = 17
        /// Space kept free under the panel when the transcript is at its tallest.
        static let bottomMargin: CGFloat = 24
        static let transcriptMinHeight: CGFloat = 120
        static let buttonSize: CGFloat = 26
        static let buttonGap: CGFloat = 2
    }

    var body: some View {
        if model.isOpen, let tasks = model.tasks {
            GeometryReader { proxy in
                let top = (proxy.size.height * C.topFraction).rounded()
                let room = proxy.size.height - top - C.fieldHeight - Metrics.bottomMargin
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.close() }
                    Group {
                        if model.mode == .code, let code = model.code {
                            ClaudeCodeBar(model: model, code: code, transcriptHeight: max(Metrics.transcriptMinHeight, room))
                        } else {
                            panel(tasks: tasks, transcriptHeight: max(Metrics.transcriptMinHeight, room))
                        }
                    }
                    .frame(width: min(C.width, proxy.size.width - 32))
                    .padding(.top, top)
                }
                .frame(maxWidth: .infinity)
            }
            // Measured from the window's top edge, titlebar included, like ⌘T.
            .ignoresSafeArea()
        }
    }

    private func panel(tasks: ClaudeTasksController, transcriptHeight: CGFloat) -> some View {
        let task = model.taskID.flatMap { tasks.task($0) }
        let isRunning = task.map { tasks.isRunning($0.id) } ?? false
        return VStack(spacing: 0) {
            field(task: task, tasks: tasks, isRunning: isRunning)
            if let task {
                Rectangle()
                    .fill(Color.primary.opacity(C.dividerOpacity))
                    .frame(height: 0.5)
                    .padding(.horizontal, C.dividerInset)
                transcript(task, isRunning: isRunning, maxHeight: transcriptHeight)
            }
        }
        .modifier(CommandBarPanel(accent: .claude))
        .tint(.claude)
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }

    /// ⌘T's search row: icon at 22.5, text at 51.5, 18pt medium, 63.5 tall. A long prompt
    /// wraps and the row grows; one line keeps ⌘T's exact height.
    private func field(task: ClaudeTask?, tasks: ClaudeTasksController, isRunning: Bool) -> some View {
        @Bindable var model = model
        let frontTab = store.state.selectedTab
        let space = store.state.selectedSpace.id
        let route = tasks.route(for: space)
        return HStack(alignment: .center, spacing: 0) {
            ClaudeMark()
                .fill(Color.claude)
                .frame(width: Metrics.markSize, height: Metrics.markSize)
                .frame(width: C.iconSize, height: C.iconSize)
                .padding(.leading, C.iconX)
                .padding(.trailing, C.textX - C.iconX - C.iconSize)
            TextField("", text: $model.draft,
                      prompt: Text(placeholder(task: task, route: route, isRunning: isRunning)).foregroundStyle(.primary.opacity(C.placeholderOpacity)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: C.fieldFontSize, weight: .medium))
                .lineLimit(1...6)
                .offset(y: -C.fieldTextLift)
                .padding(.vertical, 8)
                .focused($focused)
                .disabled(isRunning)
                .onSubmit { task == nil ? model.start(frontTab: frontTab, space: space) : model.followUp() }
                .onExitCommand { model.close() }
            HStack(spacing: Metrics.buttonGap) {
                if task == nil {
                    routeMenu(tasks, route: route, space: space)
                }
                if task == nil, route == .newChat, ClaudeDesktop.isInstalled {
                    let desktop = tasks.runsIn == .desktop
                    barButton(desktop ? "Opens in the Claude app (click to run here in Kite)" : "Runs here in Kite (click to open in the Claude app)",
                              symbol: desktop ? "arrow.up.forward.app.fill" : "arrow.up.forward.app",
                              active: desktop) { tasks.runsIn = desktop ? .kite : .desktop }
                }
                if task == nil, let ticket = LinearTicket(url: frontTab?.url) {
                    barButton("Test This Ticket (\(ticket.key))", symbol: "checklist") { model.testTicket(ticket, tasks: tasks) }
                    if Spool.isInstalled {
                        barButton("Open \(ticket.key) in Spool", symbol: "arrow.up.forward.square") { Spool.open(ticket) }
                    }
                }
                if task == nil, let frontTab {
                    barButton(model.attachTab ? "Attached “\(frontTab.displayTitle)”" : "Attach this tab",
                              symbol: model.attachTab ? "paperclip.circle.fill" : "paperclip",
                              active: model.attachTab) { model.attachTab.toggle() }
                }
                if let task {
                    if tasks.hasTabs(task.id) {
                        barButton("Show Tabs", symbol: "square.on.square") { tasks.showTabs(task.id) }
                    }
                    if isRunning {
                        barButton("Stop", symbol: "stop.circle") { tasks.stop(task.id) }
                    }
                    if tasks.canOpenInDesktop(task.id) {
                        barButton("Continue in the Claude App", symbol: "arrow.up.forward.app") { tasks.openInDesktop(task.id) }
                    }
                }
                recentTasks(tasks)
                if model.code != nil {
                    ClaudeCodeSwitchButton(toCode: true, size: Metrics.buttonSize) { model.openCode() }
                }
                if task != nil {
                    barButton("New Task", symbol: "square.and.pencil") { model.newTask() }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, C.iconX - (Metrics.buttonSize - C.iconSize) / 2)
        }
        .frame(minHeight: C.fieldHeight)
    }

    /// The space's route, and a menu to change it: a new chat, a Claude Project, or a folder.
    private func routeMenu(_ tasks: ClaudeTasksController, route: ClaudeRoute, space: UUID) -> some View {
        Menu {
            routeItem(.newChat, current: route, tasks: tasks, space: space)
            Section("Claude Projects") {
                ForEach(tasks.routes.projects, id: \.id) { project in
                    routeItem(.project(id: project.id, name: project.name), current: route, tasks: tasks, space: space)
                }
                Button("Add Project…") {
                    ClaudeRoutePicker.askForProject(over: nil) { tasks.setRoute($0, for: space) }
                    model.focusToken += 1
                }
            }
            Section("Folders") {
                ForEach(ClaudeRoutePicker.folders(including: route), id: \.self) { path in
                    routeItem(.folder(path: path), current: route, tasks: tasks, space: space)
                }
                Button("Choose Folder…") {
                    if let path = ClaudeRoutePicker.chooseFolder() { tasks.setRoute(.folder(path: path), for: space) }
                    model.focusToken += 1
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(for: route))
                    .font(.system(size: 11, weight: .semibold))
                Text(route.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(route == .newChat ? 0.06 : 0)))
            .background(Capsule().fill(Color.claude.opacity(route == .newChat ? 0 : 0.14)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 160)
        .foregroundStyle(route == .newChat ? Color.secondary : Color.claude)
        .help("Where requests from this space go: \(route.label)")
        .accessibilityLabel("Route: \(route.label)")
    }

    private func routeItem(_ item: ClaudeRoute, current: ClaudeRoute, tasks: ClaudeTasksController, space: UUID) -> some View {
        Button {
            tasks.setRoute(item, for: space)
            model.focusToken += 1
        } label: {
            if item == current {
                Label(item.label, systemImage: "checkmark")
            } else {
                Text(item.label)
            }
        }
    }

    static func symbol(for route: ClaudeRoute) -> String {
        switch route {
        case .newChat: "bubble.left"
        case .project: "square.grid.2x2"
        case .folder: "folder"
        }
    }

    private func barButton(_ help: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.claude : .secondary)
        .help(help)
        // Otherwise VoiceOver reads the symbol's own name ("Attachements" for paperclip).
        .accessibilityLabel(help)
    }

    /// Earlier tasks, newest first: a small menu instead of a window.
    @ViewBuilder
    private func recentTasks(_ tasks: ClaudeTasksController) -> some View {
        let recent = tasks.tasks.prefix(15)
        if recent.count > 1 || (recent.count == 1 && model.taskID == nil) {
            Menu {
                ForEach(Array(recent)) { task in
                    Button {
                        model.open(task: task.id)
                    } label: {
                        Text(tasks.isRunning(task.id) ? "● \(task.title)" : task.title)
                    }
                    .disabled(task.id == model.taskID)
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Earlier tasks")
        }
    }

    private func transcript(_ task: ClaudeTask, isRunning: Bool, maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(task.entries.enumerated()), id: \.offset) { _, entry in
                        ClaudeTaskEntryView(entry: entry)
                    }
                    if isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.leading, C.textX)
                .padding(.trailing, C.iconX)
                .padding(.vertical, 12)
                .font(.system(size: 13))
                .textSelection(.enabled)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: task.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: task.entries.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func placeholder(task: ClaudeTask?, route: ClaudeRoute, isRunning: Bool) -> String {
        guard task != nil else {
            switch route {
            case let .project(_, name): return "Ask Claude… (posts in \(name))"
            case .folder: return "Ask Claude…"
            case .newChat: break
            }
            return model.tasks?.runsIn == .desktop && ClaudeDesktop.isInstalled
                ? "Ask Claude… (opens in the Claude app)" : "Ask Claude to do something in your browser…"
        }
        return isRunning ? "Claude is working… (Esc to hide; it keeps going)" : "Follow up"
    }
}
