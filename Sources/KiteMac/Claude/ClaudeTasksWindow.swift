import AppKit
import KiteCore
import Observation
import SwiftUI

/// The Claude Tasks window: start a task, watch it work, read the result, follow up.
@MainActor
final class ClaudeTasksWindowController: NSWindowController, NSWindowDelegate {
    private let tasks: ClaudeTasksController
    private let composer = ClaudeTaskComposer()

    init(tasks: ClaudeTasksController, store: BrowserStore) {
        self.tasks = tasks
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Claude Tasks"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeTasks")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ClaudeTasksView(tasks: tasks, store: store, composer: composer))
        if !window.setFrameUsingName("ClaudeTasks") { window.center() }
        tasks.isPanelVisible = { [weak window] in window?.isVisible == true && window?.isMiniaturized == false }
        tasks.showPanel = { [weak self] id in self?.show(task: id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens on the composer. `attachTab` starts it with the front tab attached.
    func showComposer(attachTab: Bool) {
        tasks.selectedID = nil
        composer.attachTab = attachTab
        composer.focusToken += 1
        bringForward()
    }

    func show(task id: UUID) {
        tasks.selectedID = id
        bringForward()
    }

    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the composer holds between openings.
@MainActor
@Observable
final class ClaudeTaskComposer {
    var goal = ""
    var attachTab = false
    /// Bumped to move focus into the goal field.
    var focusToken = 0
}

struct ClaudeTasksView: View {
    let tasks: ClaudeTasksController
    let store: BrowserStore
    @Bindable var composer: ClaudeTaskComposer

    var body: some View {
        @Bindable var tasks = tasks
        NavigationSplitView {
            List(selection: $tasks.selectedID) {
                ForEach(tasks.tasks) { task in
                    ClaudeTaskRow(task: task, isRunning: tasks.isRunning(task.id)).tag(task.id)
                        .contextMenu {
                            if tasks.isRunning(task.id) {
                                Button("Stop") { tasks.stop(task.id) }
                            } else {
                                Button("Delete Task and Its Tabs") { tasks.remove(task.id) }
                            }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem {
                    Button {
                        tasks.selectedID = nil
                        composer.focusToken += 1
                    } label: {
                        Label("New Task", systemImage: "square.and.pencil")
                    }
                    .help("New Task")
                }
            }
        } detail: {
            if let id = tasks.selectedID, let task = tasks.task(id) {
                ClaudeTaskDetail(task: task, tasks: tasks)
                    .id(id)
            } else {
                ClaudeTaskComposerView(tasks: tasks, store: store, composer: composer)
            }
        }
    }
}

private struct ClaudeTaskRow: View {
    let task: ClaudeTask
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).fontWeight(task.unread ? .semibold : .regular).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if isRunning { return task.entries.last { $0.kind == .tool }?.text ?? "Starting…" }
        let reply = task.lastReply?.split(whereSeparator: \.isNewline).first.map(String.init)
        return reply ?? task.updatedAt.formatted(.relative(presentation: .named))
    }

    private var symbol: String {
        switch task.status {
        case .running, .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    private var tint: Color {
        switch task.status {
        case .running, .done: .claude
        case .failed: .orange
        case .stopped: .secondary
        }
    }
}

private struct ClaudeTaskComposerView: View {
    let tasks: ClaudeTasksController
    let store: BrowserStore
    @Bindable var composer: ClaudeTaskComposer
    @FocusState private var focused: Bool

    private var frontTab: BrowserTab? { store.state.selectedTab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should Claude do?").font(.title2.weight(.semibold))
            Text("Claude works in background tabs in the Claude space, and lets you know when it's done. "
                 + "Kite still asks before anything is submitted, sent, bought or deleted.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $composer.goal)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .frame(minHeight: 90, maxHeight: 200)
            if let tab = frontTab {
                Toggle(isOn: $composer.attachTab) {
                    Text("Attach “\(tab.displayTitle)”").lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button("Start") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(composer.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { focused = true }
        .onChange(of: composer.focusToken) { focused = true }
    }

    private func start() {
        tasks.start(goal: composer.goal, tab: composer.attachTab ? frontTab : nil)
        composer.goal = ""
        composer.attachTab = false
    }
}

private struct ClaudeTaskDetail: View {
    let task: ClaudeTask
    let tasks: ClaudeTasksController
    @State private var reply = ""

    private var isRunning: Bool { tasks.isRunning(task.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(task.title).font(.headline).lineLimit(1)
                Spacer()
                if tasks.hasTabs(task.id) {
                    Button("Show Tabs") { tasks.showTabs(task.id) }
                    if !isRunning { Button("Close Tabs") { tasks.closeTabs(task.id) } }
                }
                if isRunning { Button("Stop") { tasks.stop(task.id) } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
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
                    .padding(16)
                    .textSelection(.enabled)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: task.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: task.entries.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack {
                TextField(isRunning ? "Claude is working…" : "Follow up", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .disabled(isRunning)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(isRunning || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            if task.costUSD > 0 {
                Text("About $\(task.costUSD, specifier: "%.2f") of usage at API prices")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
        }
    }

    private func send() {
        tasks.followUp(task.id, text: reply)
        reply = ""
    }
}

private struct ClaudeTaskEntryView: View {
    let entry: ClaudeTask.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            ClaudeMarkdown(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .toolError:
            Label(entry.text, systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .note:
            Text(entry.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

}

/// Claude's replies: paragraphs, lists, headings, code and tables (SwiftUI's own
/// Markdown only does inline styles).
private struct ClaudeMarkdown: View {
    let text: String

    enum Block {
        case paragraph(String)
        case heading(String)
        case bullet(marker: String, text: String)
        case code(String)
        case table([[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .heading(let text):
                    Text(Self.inline(text)).font(.headline)
                case let .bullet(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                    .padding(.leading, 4)
                case .code(let text):
                    Text(text).font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow(alignment: .top) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                                }
                            }
                            if index == 0 { Divider() }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:--:| row under the header.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(marker: "•", text: String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(marker: String(line[...dot]), text: String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
