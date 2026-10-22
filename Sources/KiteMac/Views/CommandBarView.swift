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

/// The bar over the window, like Arc's: no dimming, a click outside closes it.
/// Present only while the bar is open, so the text field gets focus fresh every time.
struct CommandBarOverlay: View {
    let store: BrowserStore
    let onCommit: (CommandSuggestion, CommandBarMode) -> Void

    var body: some View {
        if let mode = store.commandBar {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { store.hideCommandBar() }
                    CommandBarView(store: store, mode: mode) { onCommit($0, mode) }
                        .padding(.top, (proxy.size.height * C.topFraction).rounded())
                }
            }
            // Measured from the window's top edge, titlebar included.
            .ignoresSafeArea()
        }
    }
}

private typealias C = ArcMetrics.CommandBar

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
        let accent = store.state.selectedSpace.theme.accent
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: C.iconSize, height: C.iconSize)
                    .padding(.leading, C.iconX)
                    .padding(.trailing, C.textX - C.iconX - C.iconSize)
                TextField("", text: $query, prompt: Text("Search or Enter URL...").foregroundStyle(.primary.opacity(C.placeholderOpacity)))
                    .textFieldStyle(.plain)
                    .font(.system(size: C.fieldFontSize))
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
                    .padding(.trailing, C.iconX)
            }
            .frame(height: C.fieldHeight)

            if !items.isEmpty {
                Rectangle()
                    .fill(.primary.opacity(C.dividerOpacity))
                    .frame(height: 0.5)
                    .padding(.horizontal, C.dividerInset)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(suggestion: item, engine: store.state.searchEngine, highlighted: index == highlighted, accent: accent)
                            .contentShape(Rectangle())
                            .onTapGesture { onCommit(item) }
                            .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(.horizontal, C.rowInset)
                .padding(.top, C.listTopGap)
                .padding(.bottom, C.listBottomGap)
            }
        }
        .frame(width: C.width)
        .modifier(CommandBarPanel())
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func commit(_ items: [CommandSuggestion]) {
        guard items.indices.contains(highlighted) else { return }
        onCommit(items[highlighted])
    }
}

/// Arc's panel: near-black in dark mode, a hairline border, a wide soft shadow.
private struct CommandBarPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: C.cornerRadius, style: .continuous)
        content
            .background(scheme == .dark ? Color(white: 0.106) : Color(white: 0.98), in: shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(C.borderOpacity) : Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(C.shadowOpacity), radius: C.shadowRadius, y: C.shadowY)
    }
}

private struct SuggestionRow: View {
    let suggestion: CommandSuggestion
    let engine: SearchEngine
    let highlighted: Bool
    let accent: ThemeColor

    var body: some View {
        HStack(spacing: 0) {
            icon
                .frame(width: C.rowIconSize, height: C.rowIconSize)
                .frame(width: C.rowIconTileSize, height: C.rowIconTileSize)
                .background(highlighted ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(highlighted ? Color(accent) : .primary)
                .padding(.leading, C.rowIconX)
                .padding(.trailing, C.rowTitleX - C.rowIconX - C.rowIconTileSize)
            Text(title)
                .lineLimit(1)
                .opacity(highlighted ? 1 : C.rowTextOpacity)
            Spacer(minLength: C.actionGap)
            if let detail {
                Text(detail)
                    .opacity(highlighted ? 0.8 : C.rowDetailOpacity)
                    .padding(.trailing, C.actionGap)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? Color(accent) : .primary)
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
                .fill(highlighted ? Color(accent) : .clear)
        )
        .padding(.horizontal, C.rowFillInset)
        .padding(.top, C.rowFillInset)
        .frame(height: C.rowPitch, alignment: .top)
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .open: Image(systemName: "globe").resizable().scaledToFit()
        case .search: Image(systemName: "magnifyingglass").resizable().scaledToFit()
        case .switchTab(let tab): FaviconView(tab: tab, size: C.rowIconSize)
        case .command: Image(systemName: "command").resizable().scaledToFit()
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

    /// Arc's dim label before the arrow: what Return will do.
    private var detail: String? {
        switch suggestion {
        case .open: "Open"
        case .search: "Search \(engine.displayName)"
        case .switchTab: "Switch to Tab"
        case .command(let command): command.shortcut ?? command.path
        }
    }
}

private extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: Double(color.r), green: Double(color.g), blue: Double(color.b))
    }
}
