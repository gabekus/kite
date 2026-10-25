import KiteCore
import Observation
import SwiftUI

/// Claude in the browser: a chat bubble floating at the bottom centre of the page.
/// ⌘J or the sidebar's Claude button opens it; type a goal, Return starts a task, and the
/// bubble follows that task as it works. Esc hides it; the task keeps going.
@MainActor
@Observable
final class ClaudeBubbleModel {
    var tasks: ClaudeTasksController?
    private(set) var isOpen = false
    /// The task the bubble follows; nil shows a fresh composer.
    var taskID: UUID?
    var draft = ""
    var attachTab = false
    /// Bumped to move focus into the text field.
    var focusToken = 0
    @ObservationIgnored var onOpenChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var showAllTasks: () -> Void = {}

    /// Opens on `task`, or on the task it showed last (a fresh composer once that's done and read).
    func open(task: UUID? = nil, attachTab: Bool = false) {
        guard tasks != nil else { return }
        if let task { taskID = task }
        if attachTab { taskID = nil; self.attachTab = true }
        if let taskID { tasks?.selectedID = taskID }
        setOpen(true)
        focusToken += 1
    }

    func close() { setOpen(false) }

    func toggle() { isOpen ? close() : open() }

    func newTask() {
        taskID = nil
        draft = ""
        focusToken += 1
    }

    func start(frontTab: BrowserTab?) {
        guard let tasks else { return }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        tasks.start(goal: goal, tab: attachTab ? frontTab : nil)
        taskID = tasks.selectedID
        draft = ""
        attachTab = false
    }

    func followUp() {
        guard let tasks, let taskID else { return }
        tasks.followUp(taskID, text: draft)
        draft = ""
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        onOpenChange(open)
    }
}

struct ClaudeBubble: View {
    let model: ClaudeBubbleModel
    let store: BrowserStore
    @FocusState private var focused: Bool

    enum Metrics {
        static let maxWidth: CGFloat = 620
        static let bottomInset: CGFloat = 18
        static let cornerRadius: CGFloat = 20
        static let transcriptMaxHeight: CGFloat = 340
    }

    var body: some View {
        if let tasks = model.tasks {
            let task = model.taskID.flatMap { tasks.task($0) }
            VStack(spacing: 0) {
                if let task {
                    header(task, tasks: tasks)
                    transcript(task, isRunning: tasks.isRunning(task.id))
                    Divider().opacity(0.5)
                }
                input(task: task, isRunning: task.map { tasks.isRunning($0.id) } ?? false)
            }
            .frame(maxWidth: Metrics.maxWidth)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, Metrics.bottomInset)
            .onExitCommand { model.close() }
            .onAppear { focused = true }
            .onChange(of: model.focusToken) { focused = true }
        }
    }

    private func header(_ task: ClaudeTask, tasks: ClaudeTasksController) -> some View {
        HStack(spacing: 8) {
            ClaudeMark()
                .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 13, height: 13)
            Text(task.title).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer()
            if tasks.hasTabs(task.id) {
                headerButton("Show Tabs", symbol: "square.on.square") { tasks.showTabs(task.id) }
            }
            if tasks.isRunning(task.id) {
                headerButton("Stop", symbol: "stop.circle") { tasks.stop(task.id) }
            }
            headerButton("New Task", symbol: "square.and.pencil") { model.newTask() }
            headerButton("All Tasks", symbol: "list.bullet") { model.showAllTasks() }
            headerButton("Hide (Esc)", symbol: "xmark") { model.close() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func headerButton(_ help: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func transcript(_ task: ClaudeTask, isRunning: Bool) -> some View {
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
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .textSelection(.enabled)
            }
            .frame(maxHeight: Metrics.transcriptMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: task.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: task.entries.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func input(task: ClaudeTask?, isRunning: Bool) -> some View {
        @Bindable var model = model
        let frontTab = store.state.selectedTab
        return HStack(alignment: .center, spacing: 10) {
            if task == nil {
                ClaudeMark()
                    .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 16, height: 16)
            }
            TextField(placeholder(task: task, isRunning: isRunning), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .disabled(isRunning)
                .onSubmit { task == nil ? model.start(frontTab: frontTab) : model.followUp() }
            if task == nil, let frontTab {
                Button {
                    model.attachTab.toggle()
                } label: {
                    Label(frontTab.displayTitle, systemImage: model.attachTab ? "paperclip.circle.fill" : "paperclip")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14))
                        .foregroundStyle(model.attachTab ? Color.claude : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.attachTab ? "Attached “\(frontTab.displayTitle)”" : "Attach this tab")
            }
            if task == nil {
                Button("Hide (Esc)", systemImage: "xmark") { model.close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide (Esc)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func placeholder(task: ClaudeTask?, isRunning: Bool) -> String {
        guard task != nil else { return "Ask Claude to do something in your browser…" }
        return isRunning ? "Claude is working… (Esc to hide; it keeps going)" : "Follow up"
    }
}
