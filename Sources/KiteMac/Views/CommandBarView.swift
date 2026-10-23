import KiteCore
import SwiftUI

enum CommandSuggestion: Identifiable, Hashable {
    case open(URL)
    case search(String, URL)
    case switchTab(BrowserTab)
    case command(MenuCommand)

    var id: String {
        switch self {
        case .open(let url): "open:\(url.absoluteString)"
        case .search(let query, _): "search:\(query)"
        case .switchTab(let tab): "tab:\(tab.id)"
        case .command(let command): "command:\(command.path)/\(command.title)"
        }
    }
}

/// Dimmed backdrop plus the bar itself. Present only while the bar is open, so
/// the text field gets focus fresh every time.
struct CommandBarOverlay: View {
    let store: BrowserStore
    let onCommit: (CommandSuggestion, CommandBarMode) -> Void

    var body: some View {
        if let mode = store.commandBar {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { store.hideCommandBar() }
                CommandBarView(store: store, mode: mode) { onCommit($0, mode) }
                    .padding(.top, 110)
            }
        }
    }
}

private struct CommandBarView: View {
    let store: BrowserStore
    let mode: CommandBarMode
    let onCommit: (CommandSuggestion) -> Void

    @State private var query: String
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    init(store: BrowserStore, mode: CommandBarMode, onCommit: @escaping (CommandSuggestion) -> Void) {
        self.store = store
        self.mode = mode
        self.onCommit = onCommit
        let current = mode == .editCurrent ? store.state.selectedTab?.url?.absoluteString : nil
        _query = State(initialValue: current ?? "")
    }

    private var suggestions: [CommandSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let state = store.state
        let tabs = TabSearch.rank(text, in: state, limit: 5)
            .filter { mode == .newTab || $0.tab.id != state.selectedTab?.id }
            .map { CommandSuggestion.switchTab($0.tab) }
        let search = CommandSuggestion.search(text, state.searchEngine.searchURL(for: text))
        if URLInput.looksLikeURL(text), let url = URLInput.resolve(text, engine: state.searchEngine) {
            return [.open(url)] + tabs + [search]
        }
        // Menu commands, Arc-style. A strong match ("copy url") goes above the web search.
        let commands = mode == .newTab ? MenuCommand.search(text, in: NSApp.mainMenu) : []
        let strong = commands.filter { $0.score >= 80 }.map { CommandSuggestion.command($0.command) }
        let weak = commands.filter { $0.score < 80 }.map { CommandSuggestion.command($0.command) }
        return strong + [search] + tabs + weak
    }

    var body: some View {
        let items = suggestions
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search or enter URL", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { commit(items) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onExitCommand { store.hideCommandBar() }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if !items.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(suggestion: item, engine: store.state.searchEngine, highlighted: index == highlighted)
                            .contentShape(Rectangle())
                            .onTapGesture { onCommit(item) }
                            .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func commit(_ items: [CommandSuggestion]) {
        guard items.indices.contains(highlighted) else { return }
        onCommit(items[highlighted])
    }
}

private struct SuggestionRow: View {
    let suggestion: CommandSuggestion
    let engine: SearchEngine
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if case .switchTab = suggestion {
                Text("Switch to Tab").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if case .command(let command) = suggestion, let shortcut = command.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.22) : .clear)
        )
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .open: Image(systemName: "globe")
        case .search: Image(systemName: "magnifyingglass")
        case .switchTab(let tab): FaviconView(tab: tab)
        case .command: Image(systemName: "command")
        }
    }

    private var title: String {
        switch suggestion {
        case .open(let url): url.absoluteString
        case .search(let query, _): query
        case .switchTab(let tab): tab.displayTitle
        case .command(let command): command.title
        }
    }

    private var subtitle: String? {
        switch suggestion {
        case .open: "Open"
        case .search: "Search \(engine.displayName)"
        case .switchTab(let tab): tab.url?.host()
        case .command(let command): command.path
        }
    }
}
