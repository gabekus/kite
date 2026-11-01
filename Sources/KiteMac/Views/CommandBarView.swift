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
    /// The search engine's suggestions, and the text they were for.
    @State private var engineSuggestions: (query: String, items: [String]) = ("", [])

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
        // The engine's suggestions follow the typed search, while they're for this text.
        let engine = engineSuggestions.query == text ? engineSuggestions.items.map {
            CommandSuggestion.search($0, state.searchEngine.searchURL(for: $0))
        } : []
        return strong + [search] + engine + tabs + history + weak
    }

    /// Arc's privacy banner: while the list has the engine's suggestions, until Dismiss.
    private var showsPrivacyBanner: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasEngineSuggestions = site == nil && !text.isEmpty && engineSuggestions.query == text
            && !engineSuggestions.items.isEmpty
        return SearchSuggestions.showsPrivacyBanner(hasEngineSuggestions: hasEngineSuggestions,
                                                    dismissed: store.state.hasDismissedSearchSuggestionsPrivacy)
    }

    /// The site Tab would switch to for what's typed so far.
    private var tabTarget: SiteSearch? {
        site == nil ? SiteSearch.match(query, in: store.state.activeSiteSearches) : nil
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
            if showsPrivacyBanner {
                SearchSuggestionsPrivacyBanner(
                    onSettings: {
                        store.hideCommandBar()
                        SettingsWindowController.shared.show(.profiles)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            store.mutate { $0.hasDismissedSearchSuggestionsPrivacy = true }
                        }
                    },
                    onLearnMore: { onCommit(.open(SearchSuggestionsPrivacyBanner.learnMoreURL)) }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: SearchSuggestionsPrivacyBanner.M.springResponse, dampingFraction: 1), value: showsPrivacyBanner)
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
        .task(id: SuggestionRequest(text: query.trimmingCharacters(in: .whitespacesAndNewlines), inSiteSearch: site != nil)) {
            await fetchEngineSuggestions()
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
              let match = store.state.activeSiteSearches.first(where: {
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

    private struct SuggestionRequest: Equatable {
        var text: String
        var inSiteSearch: Bool
    }

    /// Profile settings › "Include search engine suggestions", for the current space's profile.
    private func fetchEngineSuggestions() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = store.state
        guard SearchSuggestions.shouldFetch(text, settings: state.settings(ofProfile: state.selectedProfileDirectory),
                                            inSiteSearch: site != nil)
        else { return engineSuggestions = ("", []) }
        // Wait out fast typing; a newer keystroke cancels this one.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        let items = await SearchSuggestionFetcher.suggestions(for: text, engine: state.searchEngine)
        guard !Task.isCancelled else { return }
        engineSuggestions = (text, items)
    }

    private func commit(_ items: [CommandSuggestion]) {
        guard items.indices.contains(highlighted) else { return }
        onCommit(items[highlighted])
    }
}

/// Arc's `SearchSuggestionsPrivacyView` (CommandBar/SearchSuggestionsPrivacyView.swift), in its wide
/// layout: one 60pt row at the panel's foot, 1pt in from its edges, the bottom corners rounded 12.
/// An info.circle, "We talk to your search engine…" in bold over "Learn more about your data on
/// Arc here." ("here" underlined, a link), then "Search Settings…" and "Dismiss". Measured from
/// Arc 1.171's binary and asset catalogs; see docs/arc-visual-spec.md.
struct SearchSuggestionsPrivacyBanner: View {
    let onSettings: () -> Void
    let onDismiss: () -> Void
    let onLearnMore: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// Kite has no privacy policy page; its home page says what it sends where.
    static let learnMoreURL = URL(string: "https://github.com/gabekus/kite")!

    enum M {
        static let height: CGFloat = 60
        static let edgeInset: CGFloat = 1
        static let cornerRadius: CGFloat = 12
        static let leading: CGFloat = 16
        static let trailing: CGFloat = 10
        static let iconToText: CGFloat = 14
        static let titleToSubtitle: CGFloat = 2
        static let buttonSpacing: CGFloat = 10
        static let shadowOpacity: Double = 0.15
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = 4
        /// CASpringAnimation from damping ratio 1, response 0.3 (Arc's FUN_100a05154), sliding up by its height.
        static let springResponse: Double = 0.3
        static let buttonHPadding: CGFloat = 12
        static let buttonVPadding: CGFloat = 6
        static let buttonCornerRadius: CGFloat = 8
    }

    private var dark: Bool { scheme == .dark }
    /// ARCUI's Gray12 and Gray10.
    private var titleColor: Color { Color(white: dark ? 0.93 : 0.09) }
    private var detailColor: Color { Color(white: dark ? 0.494 : 0.523) }
    /// CommandBar's CommandBarBannerBackground.
    private var background: Color {
        dark ? Color(white: 0.086) : Color(red: 0.992, green: 0.992, blue: 0.996)
    }

    var body: some View {
        HStack(alignment: .center, spacing: M.iconToText) {
            Image(systemName: "info.circle").foregroundStyle(detailColor)
            VStack(alignment: .leading, spacing: M.titleToSubtitle) {
                Text("We talk to your search engine to help us suggest results.")
                    .bold()
                    .foregroundStyle(titleColor)
                HStack(spacing: 0) {
                    Text("Learn more about your data on Kite ")
                    Button(action: onLearnMore) { Text("here").underline() }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchPrivacyLearnMore")
                    Text(".")
                }
                .foregroundStyle(detailColor)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: M.buttonSpacing) {
                BannerButton(title: "Search Settings…", action: onSettings)
                    .accessibilityIdentifier("searchPrivacySettings")
                BannerButton(title: "Dismiss", action: onDismiss)
                    .accessibilityIdentifier("searchPrivacyDismiss")
            }
        }
        .font(.system(size: 13))
        .padding(.leading, M.leading)
        .padding(.trailing, M.trailing)
        .frame(height: M.height)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: M.cornerRadius, bottomTrailingRadius: M.cornerRadius, style: .circular)
                .fill(background)
                .shadow(color: .black.opacity(M.shadowOpacity), radius: M.shadowRadius, y: M.shadowY)
        )
        .padding([.horizontal, .bottom], M.edgeInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchSuggestionsPrivacy")
    }

    /// The banner's secondary buttons (CommandBarBannerSecondaryButton* colours): a filled rounded
    /// rectangle with a 1pt edge.
    private struct BannerButton: View {
        let title: String
        let action: () -> Void
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            let dark = scheme == .dark
            let shape = RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous)
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(dark ? Color.white : Color(white: 0.09))
                    .padding(.horizontal, M.buttonHPadding)
                    .padding(.vertical, M.buttonVPadding)
                    .background(shape.fill(dark ? Color(white: 0.137) : Color.white))
                    .overlay(shape.strokeBorder(Color(white: dark ? 0.435 : 0.859), lineWidth: 1))
                    .brightness(hovering ? (dark ? 0.05 : -0.03) : 0)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
        }
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
