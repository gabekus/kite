import KiteCore
import SwiftUI

enum CommandSuggestion: Identifiable, Hashable {
    case open(URL)
    case search(String, URL)
    /// A search on one site, after its Site Search shortcut and Tab.
    case siteSearch(SiteSearch, String, URL)
    case switchTab(BrowserTab)
    case history(HistoryEntry)
    case command(MenuCommand)
    /// ⇧⏎ on a search: Arc Max's Instant Links opens the top result(s) instead.
    case instantLinks(String)

    var id: String {
        switch self {
        case .open(let url): "open:\(url.absoluteString)"
        case .search(let query, _): "search:\(query)"
        case .siteSearch(let site, let query, _): "site:\(site.id):\(query)"
        case .switchTab(let tab): "tab:\(tab.id)"
        case .history(let entry): "history:\(entry.url.absoluteString)"
        case .command(let command): "command:\(command.path)/\(command.title)"
        case .instantLinks(let query): "instant:\(query)"
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
                    // Arc's 765pt, but never past the window's edges: the window can be 640 wide.
                    CommandBarView(store: store, mode: mode, width: min(C.width, proxy.size.width - 2 * C.minimumWindowMargin)) { onCommit($0, mode) }
                        .padding(.top, (proxy.size.height * C.topFraction).rounded())
                }
            }
            // Measured from the window's top edge, titlebar included.
            .ignoresSafeArea()
        }
    }
}

private typealias C = ArcMetrics.CommandBar

/// Arc 1.169's Site Search pieces, measured from a 2x capture of its command bar.
private enum S {
    // Sizes are tuned so a capture of Kite measures like one of Arc: drawn edges
    // anti-alias about half a point inside their frames.
    static let faviconSize: CGFloat = 18
    static let faviconOffset: CGFloat = 1.5
    /// From the text field's start; Arc's chip starts 1.5pt right of Kite's text.
    static let chipOffset: CGFloat = 1.5
    static let chipHeight: CGFloat = 24
    static let chipLeading: CGFloat = 10
    static let chipTrailing: CGFloat = 9.5
    static let chipFontSize: CGFloat = 13
    /// A brand-colour glow around the chip, visible ~2pt above and ~10pt below it.
    static let glowOpacity: Double = 0.38
    static let glowRadius: CGFloat = 6
    static let glowY: CGFloat = 1.5
    static let chipToText: CGFloat = 9.5
    /// "Search YouTube" (#727272 on the #212121 bar), then the Tab keycap.
    static let hintOpacity: Double = 0.36
    static let hintToKey: CGFloat = 10
    static let keySize = CGSize(width: 31, height: 22)
    static let keyCornerRadius: CGFloat = 5
    static let keyFontSize: CGFloat = 13
    static let keyTextOpacity: Double = 0.8
    /// Captures as Arc's #4A4A4A.
    static let keyFill = Color(red: 0x3D / 255, green: 0x3D / 255, blue: 0x3D / 255)
    /// From the keycap's right edge to the bar's.
    static let keyTrailing: CGFloat = 21
    /// For a site with no brand colour and no usable favicon colour.
    static let fallbackColor = keyFill
}

/// The capsule after Tab, filled with the site's brand colour: Arc's for its defaults,
/// otherwise the favicon's dominant colour.
private struct SiteSearchChip: View {
    let site: SiteSearch
    @State private var faviconColor: Color?

    private var color: Color {
        site.color.flatMap(Color.init(hex:)) ?? faviconColor ?? S.fallbackColor
    }

    var body: some View {
        Text(site.name)
            .font(.system(size: S.chipFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.leading, S.chipLeading)
            .padding(.trailing, S.chipTrailing)
            .frame(height: S.chipHeight)
            .background(color, in: Capsule())
            .shadow(color: color.opacity(S.glowOpacity), radius: S.glowRadius, y: S.glowY)
            .task(id: site.id) {
                guard site.color == nil, let page = site.url(for: ""), let host = page.host(),
                      let icon = URL(string: "https://\(host)/favicon.ico"),
                      let image = await FaviconCache.shared.image(for: icon) else { return }
                faviconColor = image.dominantColor.map(Color.init(nsColor:))
            }
    }
}

private extension Color {
    /// "RRGGBB", in Display P3 like Arc's chips (sRGB FF0000 captures far less saturated than Arc's).
    init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(.displayP3, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

private extension NSImage {
    /// The most common saturated hue in the icon, averaged; nil for a grey or empty icon.
    var dominantColor: NSColor? {
        let side = 16
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var bins: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5,
                      pixel.saturationComponent > 0.25, pixel.brightnessComponent > 0.15 else { continue }
                let bin = Int(pixel.hueComponent * 12) % 12
                let sum = bins[bin, default: (0, 0, 0, 0)]
                bins[bin] = (sum.count + 1, sum.r + pixel.redComponent, sum.g + pixel.greenComponent, sum.b + pixel.blueComponent)
            }
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = CGFloat(top.count)
        return NSColor(srgbRed: top.r / n, green: top.g / n, blue: top.b / n, alpha: 1)
    }
}

private struct CommandBarView: View {
    let store: BrowserStore
    let mode: CommandBarMode
    let width: CGFloat
    let onCommit: (CommandSuggestion) -> Void

    @State private var query: String
    @State private var highlighted = 0
    /// Set by Tab after a Site Search shortcut; the query then searches that site.
    @State private var site: SiteSearch?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    /// Catches Backspace on an empty field, which the field editor swallows before onKeyPress.
    @State private var backspaceMonitor: Any?
    /// What the user typed, without the inline completion after it.
    @State private var typed = ""
    /// The field's text while it shows an inline completion.
    @State private var completed: String?

    init(store: BrowserStore, mode: CommandBarMode, width: CGFloat, onCommit: @escaping (CommandSuggestion) -> Void) {
        self.store = store
        self.mode = mode
        self.width = width
        self.onCommit = onCommit
        let current = mode == .editCurrent ? store.state.selectedTab?.url?.absoluteString : nil
        _query = State(initialValue: current ?? "")
        _typed = State(initialValue: current ?? "")
    }

    private var suggestions: [CommandSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let state = store.state
        if let site {
            return site.url(for: text).map { [.siteSearch(site, text, $0)] } ?? []
        }
        let tabs = TabSearch.rank(text, in: state, limit: 5)
            .filter { mode == .newTab || $0.tab.id != state.selectedTab?.id }
            .map { CommandSuggestion.switchTab($0.tab) }
        let search = CommandSuggestion.search(text, state.searchEngine.searchURL(for: text))
        // Pages visited before, minus any already open as a tab.
        let openURLs = Set(TabSearch.rank(text, in: state, limit: 5).compactMap(\.tab.url))
        let visited = (store.history?.search(text, limit: 6) ?? [])
            .filter { !openURLs.contains($0.url) }
            .prefix(3)
        if URLInput.looksLikeURL(text), let url = URLInput.resolve(text, engine: state.searchEngine) {
            return [.open(url)] + tabs + visited.filter { $0.url != url }.map(CommandSuggestion.history) + [search]
        }
        let history = visited.map(CommandSuggestion.history)
        // Menu commands, Arc-style. A strong match ("copy url") goes above the web search.
        let commands = mode == .newTab ? MenuCommand.search(text, in: NSApp.mainMenu) : []
        let strong = commands.filter { $0.score >= 80 }.map { CommandSuggestion.command($0.command) }
        let weak = commands.filter { $0.score < 80 }.map { CommandSuggestion.command($0.command) }
        return strong + [search] + tabs + history + weak
    }

    /// The site Tab would switch to for what's typed so far.
    private var tabTarget: SiteSearch? {
        site == nil ? SiteSearch.match(query, in: store.state.siteSearches) : nil
    }

    var body: some View {
        let items = suggestions
        let accent = store.state.selectedSpace.theme.accent
        let tabTarget = tabTarget
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    // Like Arc: the site's icon while Tab would enter its Site Search.
                    if let tabTarget {
                        FaviconView(page: tabTarget.url(for: ""), size: S.faviconSize)
                            .offset(x: S.faviconOffset)
                    } else {
                        Magnifier()
                            .stroke(scheme == .dark ? Color.white : Color.black, style: StrokeStyle(lineWidth: C.magnifierStroke, lineCap: .round))
                    }
                }
                .frame(width: C.iconSize, height: C.iconSize)
                .padding(.leading, C.iconX)
                .padding(.trailing, C.textX - C.iconX - C.iconSize)
                if let site {
                    SiteSearchChip(site: site)
                        .padding(.leading, S.chipOffset)
                        .padding(.trailing, S.chipToText)
                }
                TextField("", text: $query, prompt: Text(site == nil ? "Search or Enter URL..." : "Search...").foregroundStyle(.primary.opacity(C.placeholderOpacity)))
                    .textFieldStyle(.plain)
                    .font(.system(size: C.fieldFontSize, weight: .medium))
                    .offset(y: -C.fieldTextLift)
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
                    // Arc: "Press Shift + Enter for any web search to instantly open the top result."
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers == .shift, site == nil, InstantLinksController.isEnabled,
                              InstantLinks.applies(to: query) else { return .ignored }
                        onCommit(.instantLinks(query.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard let tabTarget else { return .ignored }
                        site = tabTarget
                        query = ""
                        return .handled
                    }
                    .onExitCommand { store.hideCommandBar() }
                if let tabTarget {
                    HStack(spacing: S.hintToKey) {
                        Text("Search \(tabTarget.name)")
                            .font(.system(size: C.rowFontSize))
                            .opacity(S.hintOpacity)
                        Text("Tab")
                            .font(.system(size: S.keyFontSize, weight: .semibold))
                            .foregroundStyle(.white.opacity(S.keyTextOpacity))
                            .frame(width: S.keySize.width, height: S.keySize.height)
                            .background(S.keyFill, in: RoundedRectangle(cornerRadius: S.keyCornerRadius, style: .continuous))
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 8)
                }
                Spacer().frame(width: tabTarget == nil ? C.iconX : S.keyTrailing)
            }
            .frame(height: C.fieldHeight)

            if !items.isEmpty {
                Rectangle()
                    .fill((scheme == .dark ? Color.white : Color.black).opacity(C.dividerOpacity))
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
        .frame(width: width)
        .modifier(CommandBarPanel())
        .onAppear {
            focused = true
            installBackspaceMonitor()
        }
        .onDisappear {
            if let backspaceMonitor { NSEvent.removeMonitor(backspaceMonitor) }
            backspaceMonitor = nil
        }
        .onChange(of: query) { old, new in
            highlighted = 0
            autocomplete(from: old, to: new)
        }
    }

    /// Arc completes a Site Search shortcut inline as you type ("you" → "you" + selected
    /// "tube.com"), so Return opens the site and Tab searches it. Only when typing forward:
    /// deleting the completion leaves what was typed.
    private func autocomplete(from old: String, to new: String) {
        if new == completed { return }
        if let completed, new.hasPrefix(completed) {
            // Keys typed before the completion got selected belong after what was typed.
            self.completed = nil
            query = typed + new.dropFirst(completed.count)
            return
        }
        completed = nil
        let previous = typed
        typed = new
        guard site == nil, new.count > previous.count, new.hasPrefix(previous), !new.contains(" "),
              let match = store.state.siteSearches.first(where: {
                  $0.shortcut.count > new.count && $0.shortcut.lowercased().hasPrefix(new.lowercased())
              })
        else { return }
        let text = new + match.shortcut.dropFirst(new.count)
        completed = text
        query = text
        let typedLength = (new as NSString).length
        let completionLength = (text as NSString).length - typedLength
        // After SwiftUI has put the new text in the field editor.
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text else { return }
            editor.setSelectedRange(NSRange(location: typedLength, length: completionLength))
        }
    }

    /// Backspace on an empty field leaves Site Search, like Chromium's keyword mode.
    private func installBackspaceMonitor() {
        let site = $site, query = $query
        backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isBackspace = event.keyCode == 51
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
            guard isBackspace else { return event }
            // Local monitors run on the main thread.
            let leave = MainActor.assumeIsolated {
                guard site.wrappedValue != nil, query.wrappedValue.isEmpty else { return false }
                site.wrappedValue = nil
                return true
            }
            return leave ? nil : event
        }
    }

    private func commit(_ items: [CommandSuggestion]) {
        guard items.indices.contains(highlighted) else { return }
        onCommit(items[highlighted])
    }
}

/// Arc's panel: a dark tint over the blurred page, a hairline border, a wide soft shadow.
/// ⌘J's Claude bar uses the same panel with `accent` set: the border and a faint glow
/// take that colour instead of white.
struct CommandBarPanel: ViewModifier {
    var accent: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: C.cornerRadius, style: .circular)
        content
            .background {
                ZStack {
                    PanelMaterial(material: scheme == .dark ? .hudWindow : .popover)
                    Color(white: scheme == .dark ? C.darkTint : C.lightTint).opacity(C.tintOpacity)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            // A black hairline just outside the border, which shows on light pages.
            .overlay(
                RoundedRectangle(cornerRadius: C.cornerRadius + C.outlineWidth, style: .circular)
                    .strokeBorder(Color.black, lineWidth: C.outlineWidth)
                    .padding(-C.outlineWidth)
            )
            .shadow(color: .black.opacity(C.shadowOpacity), radius: C.shadowRadius, y: C.shadowY)
            .shadow(color: (accent ?? .clear).opacity(C.accentGlowOpacity), radius: C.accentGlowRadius)
    }

    private var border: Color {
        if let accent { return accent.opacity(C.accentBorderOpacity) }
        return scheme == .dark ? Color.white.opacity(C.borderOpacity) : Color.black.opacity(0.12)
    }
}

/// Arc's field icon: a ring with a short, thin handle, the same stroke all round. It is
/// not SF Symbols' magnifyingglass, whose handle is longer and heavier.
private struct Magnifier: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.minX + C.magnifierCenter.x, y: rect.minY + C.magnifierCenter.y)
        let diagonal = CGFloat(0.5).squareRoot()
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - C.magnifierRadius, y: center.y - C.magnifierRadius,
                                   width: C.magnifierRadius * 2, height: C.magnifierRadius * 2))
        path.move(to: CGPoint(x: center.x + C.magnifierRadius * diagonal, y: center.y + C.magnifierRadius * diagonal))
        path.addLine(to: CGPoint(x: center.x + C.magnifierHandleEnd * diagonal, y: center.y + C.magnifierHandleEnd * diagonal))
        return path
    }
}

/// The blurred page under the panel. Within-window blending samples the web view too,
/// since the window server composites Chromium's layers into the backdrop.
private struct PanelMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
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
            // Arc's "Title — url" rows: the part after the dash is dimmer.
            (Text(title) + Text(subtitle.map { " — " + $0 } ?? "").foregroundColor(highlighted ? .white.opacity(0.7) : .primary.opacity(0.5)))
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
        case .search, .siteSearch, .instantLinks: Image(systemName: "magnifyingglass").resizable().scaledToFit()
        case .switchTab(let tab): FaviconView(tab: tab, size: C.rowIconSize)
        case .history(let entry): FaviconView(page: entry.url, size: C.rowIconSize)
        case .command: Image(systemName: "command").resizable().scaledToFit()
        }
    }

    private var title: String {
        switch suggestion {
        case .open(let url): url.absoluteString
        case .search(let query, _), .siteSearch(_, let query, _), .instantLinks(let query): query
        case .switchTab(let tab): tab.displayTitle
        case .history(let entry): entry.displayTitle
        case .command(let command): command.title
        }
    }

    /// Arc's dim label before the arrow: what Return will do.
    private var detail: String? {
        switch suggestion {
        case .open: "Open"
        case .search: "Search \(engine.displayName)"
        case .siteSearch(let site, _, _): "Search \(site.name)"
        case .switchTab: "Switch to Tab"
        case .history, .instantLinks: nil
        case .command(let command): command.shortcut ?? command.path
        }
    }

    /// Shown after the title, like Arc's "The Browser Company — youtube.com/c/thebrowsercompany".
    private var subtitle: String? {
        guard case .history(let entry) = suggestion, !entry.title.isEmpty else { return nil }
        let url = entry.url
        let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        let path = url.path() == "/" ? "" : url.path()
        return host + path
    }
}

private extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: Double(color.r), green: Double(color.g), blue: Double(color.b))
    }
}
