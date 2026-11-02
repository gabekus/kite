import AppKit
import KiteCore
import SwiftUI

/// ⌃⌘J, or the Claude Code button in the ⌘J bar: the user's own Claude Code sessions in the same
/// bar as ⌘J (same panel, field and transcript). Without a session it lists the pinned ones and
/// the last few, filtered by what's typed; picking one shows its conversation (live while it runs
/// in a terminal or the Claude app), and Return continues it from Kite.
struct ClaudeCodeBar: View {
    let model: ClaudeBubbleModel
    let code: ClaudeCodeSessionsController
    let transcriptHeight: CGFloat
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    private typealias C = ArcMetrics.CommandBar
    private typealias M = ClaudeBubble.Metrics

    var body: some View {
        let session = code.selectedID.flatMap { code.session($0) }
        let conversation = code.selectedID.flatMap { code.conversation($0) }
        VStack(spacing: 0) {
            field(session: session)
            if code.selectedID != nil || model.newSessionFolder != nil {
                divider
                header(session: session)
                if let conversation, !conversation.entries.isEmpty || code.isRunning(conversation.sessionID ?? "") {
                    transcript(conversation, isRunning: code.selectedID.map(code.isRunning) ?? false)
                } else if model.newSessionFolder != nil {
                    Text("Claude Code starts a new session in this folder, with its CLAUDE.md, settings and tools.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, C.textX)
                        .padding(.trailing, C.iconX)
                        .padding(.vertical, 12)
                }
            } else {
                let rows = self.rows
                if !rows.isEmpty {
                    divider
                    list(rows)
                } else {
                    divider
                    Text(model.codeDraft.isEmpty
                         ? "No Claude Code sessions yet. Start one in a folder with the New Session button."
                         : "No sessions match.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, C.textX)
                        .padding(.vertical, 14)
                }
            }
        }
        .modifier(CommandBarPanel(accent: .claude))
        .tint(.claude)
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onChange(of: model.codeDraft) { highlighted = 0 }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(C.dividerOpacity))
            .frame(height: 0.5)
            .padding(.horizontal, C.dividerInset)
    }

    // MARK: Field

    private func field(session: ClaudeCodeSession?) -> some View {
        @Bindable var model = model
        let id = code.selectedID
        let isRunning = id.map(code.isRunning) ?? false
        return HStack(alignment: .center, spacing: 0) {
            ClaudeCodeMark(size: M.markSize)
                .frame(width: C.iconSize, height: C.iconSize)
                .padding(.leading, C.iconX)
                .padding(.trailing, C.textX - C.iconX - C.iconSize)
            TextField("", text: $model.codeDraft,
                      prompt: Text(placeholder(session: session, isRunning: isRunning)).foregroundStyle(.primary.opacity(C.placeholderOpacity)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: C.fieldFontSize, weight: .medium))
                .lineLimit(1...6)
                .offset(y: -C.fieldTextLift)
                .padding(.vertical, 8)
                .focused($focused)
                .disabled(isRunning)
                .onSubmit(submit)
                .onKeyPress(.downArrow) {
                    guard isListing else { return .ignored }
                    highlighted = min(highlighted + 1, max(rows.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard isListing else { return .ignored }
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onExitCommand { model.close() }
            HStack(spacing: M.buttonGap) {
                if let id {
                    button("All Sessions", symbol: "chevron.left") { model.showSessions() }
                    button(code.isPinned(id) ? "Unpin" : "Pin to the Claude Code Bar",
                           symbol: code.isPinned(id) ? "pin.fill" : "pin", active: code.isPinned(id)) { code.togglePin(id) }
                    if isRunning {
                        button("Stop", symbol: "stop.circle") { code.stop(id) }
                    }
                    if ClaudeDesktop.isInstalled, !isRunning {
                        button("Open in the Claude App", symbol: "arrow.up.forward.app") { code.openInDesktop(id) }
                    }
                } else if model.newSessionFolder != nil {
                    button("All Sessions", symbol: "chevron.left") { model.showSessions() }
                } else {
                    newSessionMenu
                }
                permissionsButton
                ClaudeCodeSwitchButton(toCode: false, size: M.buttonSize) { model.open() }
            }
            .padding(.leading, 8)
            .padding(.trailing, C.iconX - (M.buttonSize - C.iconSize) / 2)
        }
        .frame(minHeight: C.fieldHeight)
    }

    private var isListing: Bool { code.selectedID == nil && model.newSessionFolder == nil }

    private func submit() {
        guard isListing else { return model.sendCode() }
        let rows = self.rows
        guard rows.indices.contains(highlighted) else { return }
        model.codeDraft = ""
        model.openCode(session: rows[highlighted].session.id)
    }

    private func placeholder(session: ClaudeCodeSession?, isRunning: Bool) -> String {
        if let folder = model.newSessionFolder { return "New Claude Code session in \(ClaudeRoute.folderName(folder))…" }
        guard code.selectedID != nil else { return "Search your Claude Code sessions" }
        if isRunning { return "Claude Code is working… (Esc to hide; it keeps going)" }
        return "Continue “\(session?.title ?? "this session")”"
    }

    private var newSessionMenu: some View {
        Menu {
            Section("New Session In") {
                ForEach(ClaudeRoutePicker.folders(including: .newChat), id: \.self) { path in
                    Button(ClaudeRoute.folderName(path)) { model.newSession(in: path) }
                }
            }
            Button("Choose Folder…") {
                if let path = ClaudeRoutePicker.chooseFolder() { model.newSession(in: path) }
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .medium))
                .frame(width: M.buttonSize, height: M.buttonSize)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("New Claude Code Session")
        .accessibilityLabel("New Claude Code Session")
    }

    /// Nobody can answer Claude Code's permission prompts from here, so the bar says up front what it may do.
    private var permissionsButton: some View {
        let full = code.permissions == .bypassPermissions
        return Menu {
            ForEach(ClaudeCodeInvocation.Permissions.allCases, id: \.self) { mode in
                Button {
                    code.permissions = mode
                    model.focusToken += 1
                } label: {
                    if mode == code.permissions { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                }
            }
        } label: {
            Image(systemName: full ? "exclamationmark.shield.fill" : "checkmark.shield")
                .font(.system(size: 14, weight: .medium))
                .frame(width: M.buttonSize, height: M.buttonSize)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(full ? Color.claude : .secondary)
        .help("Turns sent from Kite: \(code.permissions.label)")
        .accessibilityLabel("Permissions: \(code.permissions.label)")
    }

    private func button(_ help: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: M.buttonSize, height: M.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.claude : .secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: List

    struct Row: Identifiable {
        var session: ClaudeCodeSession
        var pinned: Bool
        var id: String { session.id }
    }

    /// Pinned first, then recent, narrowed by what's typed.
    private var rows: [Row] {
        let all = code.pinned.map { Row(session: $0, pinned: true) } + code.recent.map { Row(session: $0, pinned: false) }
        let query = model.codeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { row in
            [row.session.title, row.session.folderName ?? "", row.session.gitBranch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func list(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 || rows[index - 1].pinned != row.pinned {
                    Text(row.pinned ? "Pinned" : "Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, C.rowIconX + C.rowFillInset)
                        .padding(.top, index == 0 ? 2 : 8)
                        .padding(.bottom, 2)
                }
                ClaudeCodeSessionRow(row: row, highlighted: index == highlighted,
                                     running: code.isRunning(row.session.id), unread: code.unreadIDs.contains(row.session.id))
                    .contentShape(Rectangle())
                    .onTapGesture { model.openCode(session: row.session.id) }
                    .onHover { if $0 { highlighted = index } }
                    .contextMenu {
                        Button(row.pinned ? "Unpin" : "Pin") { code.togglePin(row.session.id) }
                        if ClaudeDesktop.isInstalled {
                            Button("Open in the Claude App") { code.openInDesktop(row.session.id) }
                        }
                        if let directory = row.session.directory {
                            Button("Show Folder in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, C.rowInset)
        .padding(.top, C.listTopGap)
        .padding(.bottom, C.listBottomGap)
    }

    // MARK: Session

    private func header(session: ClaudeCodeSession?) -> some View {
        HStack(spacing: 6) {
            if let folder = model.newSessionFolder {
                Image(systemName: "folder")
                Text(folder).lineLimit(1).truncationMode(.middle)
            } else if let session {
                Text(session.title).fontWeight(.semibold).lineLimit(1)
                if let detail = ClaudeCodeSessionRow.detail(session) {
                    Text("· \(detail)").lineLimit(1)
                }
                Spacer(minLength: 6)
                if code.isRunning(session.id) {
                    Text("Running in Kite").foregroundStyle(Color.claude)
                } else if session.isLive() {
                    Text("Active now").foregroundStyle(Color.claude)
                } else {
                    Text(session.updatedAt, style: .relative) + Text(" ago")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.leading, C.textX)
        .padding(.trailing, C.iconX)
        .padding(.top, 10)
    }

    private func transcript(_ conversation: ClaudeTask, isRunning: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(conversation.entries.enumerated()), id: \.offset) { _, entry in
                        ClaudeTaskEntryView(entry: entry, toolSymbol: "terminal")
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
            .frame(maxHeight: transcriptHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.entries.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// One session in the list, in ⌘T's row geometry and Claude's colour.
struct ClaudeCodeSessionRow: View {
    let row: ClaudeCodeBar.Row
    let highlighted: Bool
    let running: Bool
    let unread: Bool

    private typealias C = ArcMetrics.CommandBar

    /// "kite · main"
    static func detail(_ session: ClaudeCodeSession) -> String? {
        let parts = [session.folderName, session.gitBranch].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let session = row.session
        HStack(spacing: 0) {
            Image(systemName: row.pinned ? "pin.fill" : "terminal")
                .resizable()
                .scaledToFit()
                .frame(width: C.rowIconSize - 2, height: C.rowIconSize - 2)
                .frame(width: C.rowIconTileSize, height: C.rowIconTileSize)
                .background(highlighted ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(highlighted ? Color.claude : .primary)
                .overlay(alignment: .topTrailing) {
                    if running || session.isLive() || unread {
                        Circle()
                            .fill(highlighted ? Color.white : Color.claude)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -2)
                    }
                }
                .padding(.leading, C.rowIconX)
                .padding(.trailing, C.rowTitleX - C.rowIconX - C.rowIconTileSize)
            (Text(session.title) + Text(Self.detail(session).map { " — " + $0 } ?? "")
                .foregroundColor(highlighted ? .white.opacity(0.7) : .primary.opacity(0.5)))
                .lineLimit(1)
                .opacity(highlighted ? 1 : C.rowTextOpacity)
            Spacer(minLength: C.actionGap)
            Group {
                if running {
                    Text("Running")
                } else if session.isLive() {
                    Text("Active")
                } else {
                    Text(session.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
            }
            .opacity(highlighted ? 0.8 : C.rowDetailOpacity)
            .padding(.trailing, C.actionGap)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? Color.claude : .primary)
                .frame(width: C.actionBoxSize, height: C.actionBoxSize)
                .background(highlighted ? Color.white : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(highlighted ? 1 : 0.7)
                .padding(.trailing, C.actionBoxTrailing)
        }
        .font(.system(size: C.rowFontSize, weight: .medium))
        .foregroundStyle(highlighted ? Color.white : .primary)
        .frame(height: C.rowFillHeight)
        .background(
            RoundedRectangle(cornerRadius: C.rowCornerRadius, style: .continuous)
                .fill(highlighted ? Color.claude : .clear)
        )
        .padding(.horizontal, C.rowFillInset)
        .padding(.top, C.rowFillInset)
        .frame(height: C.rowPitch, alignment: .top)
    }
}

/// Claude Code in the bar: Claude's own mark (`ClaudeMark`, the real logo's path) with a small
/// terminal badge. Not a drawn Claude Code logo: Kite only uses Claude's real mark.
struct ClaudeCodeMark: View {
    var size: CGFloat = 17

    var body: some View {
        ClaudeMark()
            .fill(Color.claude)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.primary)
                    .background(Circle().fill(.background).padding(-1))
                    .offset(x: size * 0.22, y: size * 0.18)
            }
    }
}

/// The button that switches the bar between ⌘J (Kite's Claude) and the Claude Code sessions.
struct ClaudeCodeSwitchButton: View {
    let toCode: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        let help = toCode ? "Claude Code Sessions (⌃⌘J)" : "Ask Claude in Kite (⌘J)"
        Button(action: action) {
            Group {
                if toCode {
                    ClaudeCodeMark(size: 14)
                } else {
                    ClaudeMark().fill(Color.claude).frame(width: 14, height: 14)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
