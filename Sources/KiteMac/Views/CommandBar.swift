import AppKit
import KiteCore
import SwiftUI

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
    static let keyFill = NSColor(srgbRed: 0x3D / 255, green: 0x3D / 255, blue: 0x3D / 255, alpha: 1)
    /// From the keycap's right edge to the bar's.
    static let keyTrailing: CGFloat = 21
    /// For a site with no brand colour and no usable favicon colour.
    static let fallbackColor = keyFill
}

/// The command bar over the window, like Arc's: no dimming, a click outside closes it. The panel is made
/// fresh each time the bar opens, so its field starts empty (or with the page's URL) and focused.
@MainActor
final class CommandBarOverlayView: NSView {
    private let store: BrowserStore
    private let onCommit: (CommandSuggestion, CommandBarMode) -> Void
    private var panel: CommandBarPanelView?
    private var updateScheduled = false

    init(store: BrowserStore, onCommit: @escaping (CommandSuggestion, CommandBarMode) -> Void) {
        self.store = store
        self.onCommit = onCommit
        super.init(frame: .zero)
        wantsLayer = true
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func update() {
        withObservationTracking {
            let mode = store.commandBar
            if let mode {
                if panel == nil || panel?.mode != mode {
                    panel?.close()
                    panel?.removeFromSuperview()
                    let panel = CommandBarPanelView(store: store, mode: mode) { [weak self] suggestion in
                        self?.onCommit(suggestion, mode)
                    }
                    addSubview(panel)
                    self.panel = panel
                    needsLayout = true
                }
            } else if let panel {
                panel.close()
                panel.removeFromSuperview()
                self.panel = nil
            }
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // Before the next key event: the bar's field has to exist when ⌘T's typing arrives.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateScheduled = false
                self.update()
            }
        }
    }

    /// Opens the bar now if the store says so (the window controller focuses its field straight after).
    func syncNow() {
        if updateScheduled {
            updateScheduled = false
            update()
        }
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let panel else { return }
        // Arc's 765pt, but never past the window's edges: the window can be 640 wide. Measured from the window's
        // top edge, titlebar included.
        let width = min(C.width, bounds.width - 2 * C.minimumWindowMargin)
        let height = panel.height
        // Centred like SwiftUI's ZStack (on the half point, not rounded to a whole one).
        panel.frame = CGRect(x: ((bounds.width - width) / 2 * 2).rounded() / 2, y: (bounds.height * C.topFraction).rounded(),
                             width: width, height: height)
    }

    /// A click outside the panel closes the bar.
    override func mouseDown(with event: NSEvent) { store.hideCommandBar() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }
}

/// Arc's command bar panel: the field (magnifier or the site's icon, the Site Search chip, the text, the "Search
/// <site>" hint with its Tab keycap) and, while there's text, the suggestions under a hairline.
@MainActor
final class CommandBarPanelView: NSView, NSTextFieldDelegate {
    let mode: CommandBarMode
    private let store: BrowserStore
    private let onCommit: (CommandSuggestion) -> Void
    private let background = CommandBarPanelBackground()
    private let magnifier = CAShapeLayer()
    private let magnifierView = SidebarFlippedView()
    private let siteIcon = FaviconImageView(side: S.faviconSize)
    private let chip = SiteSearchChipView()
    let field = CommandBarField()
    private let hint = SidebarLabel(size: C.rowFontSize, weight: .regular, opacity: S.hintOpacity)
    private let keycap = KeycapView()
    private let divider = FillView()
    private var rows: [SuggestionRowView] = []

    private var items: [CommandSuggestion] = []
    private var highlighted = 0 { didSet { if highlighted != oldValue { applyHighlight() } } }
    /// Set by Tab after a Site Search shortcut; the query then searches that site.
    private var site: SiteSearch? { didSet { siteChanged() } }
    /// What the user typed, without the inline completion after it.
    private var typed = ""
    /// The field's text while it shows an inline completion.
    private var completed: String?
    /// The search engine's suggestions, and the text they were for.
    private var engineSuggestions: (query: String, items: [String]) = ("", [])
    private var fetch: Task<Void, Never>?
    private var lastRequest: (text: String, inSiteSearch: Bool)?
    private var updateScheduled = false

    init(store: BrowserStore, mode: CommandBarMode, onCommit: @escaping (CommandSuggestion) -> Void) {
        self.store = store
        self.mode = mode
        self.onCommit = onCommit
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(background)
        magnifier.fillColor = nil
        magnifier.lineWidth = C.magnifierStroke
        magnifier.lineCap = .round
        magnifierView.layer?.addSublayer(magnifier)
        addSubview(magnifierView)
        addSubview(siteIcon)
        addSubview(chip)
        field.delegate = self
        field.panel = self
        addSubview(field)
        addSubview(hint)
        addSubview(keycap)
        divider.cornerRadius = 0
        addSubview(divider)
        let current = mode == .editCurrent ? store.state.selectedTab?.url?.absoluteString : nil
        field.stringValue = current ?? ""
        typed = current ?? ""
        siteChanged()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    func close() {
        fetch?.cancel()
        fetch = nil
    }

    var query: String { field.stringValue }

    var height: CGFloat {
        guard !items.isEmpty else { return C.fieldHeight }
        return C.fieldHeight + 0.5 + C.listTopGap + CGFloat(items.count) * C.rowPitch + C.listBottomGap
    }

    // MARK: Suggestions

    /// Rebuilds the suggestions from the query, watching the store and history they read.
    private func refresh() {
        let next = withObservationTracking { computeSuggestions() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        let changed = next != items
        items = next
        if changed {
            rebuildRows()
            superview?.needsLayout = true
        }
        updateTabTarget()
        requestEngineSuggestions()
    }

    private func scheduleRefresh() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.refresh()
        }
    }

    private func computeSuggestions() -> [CommandSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let state = store.state
        if let site {
            return site.url(for: text).map { [.siteSearch(site, text, $0)] } ?? []
        }
        let matches = TabSearch.switchTargets(text, in: state)
        let looksLikeURL = URLInput.looksLikeURL(text)
        // The tab above the rest, from what was typed, not a Site Search completion after it ("gi" + "thub.com").
        let typedText = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // When the leader comes from outside the five tab rows, it makes a sixth.
        let lead = mode == .newTab
            ? CommandBarOrder.leader(typedText, shown: text, in: state,
                                     typedMatches: typedText == text ? matches : TabSearch.switchTargets(typedText, in: state),
                                     looksLikeURL: looksLikeURL)
            : nil
        let leader = lead.map(CommandSuggestion.switchTab)
        let tabs = matches.filter { $0.tab.id != lead?.id }.map { CommandSuggestion.switchTab($0.tab) }
        let search = CommandSuggestion.search(text, state.searchEngine.searchURL(for: text))
        // Pages visited before, minus any already shown as a tab and the page you're on (Arc showed neither).
        let shownTabs = matches.map(\.tab) + [lead, state.selectedTab].compactMap { $0 }
        let openURLs = Set(shownTabs.compactMap(\.url) + [lead?.pinnedURL].compactMap { $0 })
        let visited = (store.history?.search(text, limit: 6) ?? [])
            .filter { !openURLs.contains($0.url) }
            .prefix(3)
        if looksLikeURL, let url = URLInput.resolve(text, engine: state.searchEngine) {
            let history = visited.filter { $0.url != url }.map(CommandSuggestion.history)
            return CommandBarOrder.arrangeURL(leader: leader, open: .open(url), tabs: tabs, history: history, search: search)
        }
        let history = visited.map(CommandSuggestion.history)
        // Menu commands, Arc-style. A strong match ("copy url") goes above the web search.
        let commands = mode == .newTab ? MenuCommand.search(text, in: NSApp.mainMenu) : []
        let strong = commands.filter { $0.score >= 80 }.map { CommandSuggestion.command($0.command) }
        let weak = commands.filter { $0.score < 80 }.map { CommandSuggestion.command($0.command) }
        // The engine's suggestions follow the typed search. The last answer stays up while the
        // next one is on its way (Chromium's autocomplete keeps old matches to avoid flicker).
        let engine = SearchSuggestions.lingering(engineSuggestions.items, for: text).map {
            CommandSuggestion.search($0, state.searchEngine.searchURL(for: $0))
        }
        // Arc's ⌘T order; editing the address keeps tabs under the engine's suggestions (not observed in Arc).
        guard mode == .newTab else { return [search] + engine + tabs + history }
        return CommandBarOrder.arrange(leader: leader, strongCommands: strong, search: search, tabs: tabs,
                                       engine: engine, history: history, weakCommands: weak)
    }

    /// Profile settings › "Include search engine suggestions", for the current space's profile.
    private func requestEngineSuggestions() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = (text: text, inSiteSearch: site != nil)
        if let last = lastRequest, last == request { return }
        lastRequest = request
        fetch?.cancel()
        let state = store.state
        guard SearchSuggestions.shouldFetch(text, settings: state.settings(ofProfile: state.selectedProfileDirectory),
                                            inSiteSearch: site != nil)
        else {
            if !engineSuggestions.items.isEmpty {
                engineSuggestions = ("", [])
                refresh()
            }
            return
        }
        let engine = state.searchEngine
        fetch = Task { [weak self] in
            // Wait out fast typing; a newer keystroke cancels this one.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            // A failed request keeps what's showing rather than blanking the list.
            guard let items = await SearchSuggestionFetcher.suggestions(for: text, engine: engine), !Task.isCancelled,
                  let self else { return }
            self.engineSuggestions = (text, items)
            self.refresh()
        }
    }

    /// Reuses the rows there are, reconfiguring only those whose suggestion changed (typing changes a few).
    private func rebuildRows() {
        let accent = store.state.selectedSpace.theme.accent
        let engine = store.state.searchEngine
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let row: SuggestionRowView
            if index < rows.count {
                row = rows[index]
            } else {
                row = SuggestionRowView()
                addSubview(row)
                rows.append(row)
            }
            row.configure(suggestion: item, engine: engine, accent: accent)
            row.onHover = { [weak self] in self?.highlighted = index }
            row.onClick = { [weak self] in self?.onCommit(item) }
        }
        if highlighted >= items.count { highlighted = 0 }
        applyHighlight()
        needsLayout = true
    }

    private func applyHighlight() {
        for (i, row) in rows.enumerated() { row.highlighted = i == highlighted }
    }

    /// The site Tab would switch to for what's typed so far.
    private var tabTarget: SiteSearch? {
        site == nil ? SiteSearch.match(query, in: store.state.activeSiteSearches) : nil
    }

    private func updateTabTarget() {
        let target = tabTarget
        // Like Arc: the site's icon while Tab would enter its Site Search.
        magnifierView.isHidden = target != nil
        siteIcon.isHidden = target == nil
        if let target { siteIcon.show(page: target.url(for: ""), icon: nil) }
        hint.isHidden = target == nil
        keycap.isHidden = target == nil
        if let target { hint.stringValue = "Search \(target.name)" }
        needsLayout = true
    }

    private func siteChanged() {
        chip.isHidden = site == nil
        if let site { chip.show(site) }
        field.placeholder = site == nil ? "Search or Enter URL..." : "Search..."
        needsLayout = true
    }

    // MARK: Typing

    func controlTextDidChange(_ notification: Notification) {
        let new = field.stringValue
        highlighted = 0
        autocomplete(to: new)
        refresh()
    }

    /// Arc completes a Site Search shortcut inline as you type ("you" → "you" + selected "tube.com"), so Return
    /// opens the site and Tab searches it. Only when typing forward: deleting the completion leaves what was typed.
    private func autocomplete(to new: String) {
        // Not mid-composition (an input method's marked text): setting the text would break it.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        if new == completed { return }
        if let completed, new.hasPrefix(completed) {
            // Typed after the completion rather than over it: the caret had left it (→, ⌥→, a click), so it's
            // accepted, as Arc ("you" → "youtube.com", → then "/" → "youtube.com/").
            self.completed = nil
            typed = new
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
        field.stringValue = text
        let typedLength = (new as NSString).length
        let completionLength = (text as NSString).length - typedLength
        field.currentEditor()?.selectedRange = NSRange(location: typedLength, length: completionLength)
    }

    private func setText(_ text: String) {
        field.stringValue = text
        typed = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlighted = min(highlighted + 1, max(items.count - 1, 0))
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveForward(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)):
            // →, ⌥→, ^F and ^E accept the inline completion at once, so the rows follow it before the next key.
            if let completed {
                typed = completed
                self.completed = nil
                highlighted = 0
                refresh()
            }
            return false
        case #selector(NSResponder.moveUp(_:)):
            highlighted = max(highlighted - 1, 0)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Arc: "Press Shift + Enter for any web search to instantly open the top result."
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, site == nil, InstantLinksController.isEnabled,
               InstantLinks.applies(to: query) {
                onCommit(.instantLinks(query.trimmingCharacters(in: .whitespacesAndNewlines)))
                return true
            }
            if items.indices.contains(highlighted) { onCommit(items[highlighted]) }
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard let target = tabTarget else { return true }
            site = target
            completed = nil
            setText("")
            refresh()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            store.hideCommandBar()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Backspace on an empty field leaves Site Search, like Chromium's keyword mode.
            if site != nil, query.isEmpty {
                site = nil
                refresh()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        background.frame = bounds
        let fieldH = C.fieldHeight
        // SwiftUI centres the 18pt icon in the 63.5pt row and rounds it to the pixel grid, downward (23, not 22.75).
        let iconY = ((fieldH - C.iconSize) / 2 * 2).rounded(.up) / 2
        magnifierView.frame = CGRect(x: C.iconX, y: iconY, width: C.iconSize, height: C.iconSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifier.frame = magnifierView.bounds
        let path = CGMutablePath()
        let center = C.magnifierCenter
        let diagonal = CGFloat(0.5).squareRoot()
        path.addEllipse(in: CGRect(x: center.x - C.magnifierRadius, y: center.y - C.magnifierRadius,
                                   width: C.magnifierRadius * 2, height: C.magnifierRadius * 2))
        path.move(to: CGPoint(x: center.x + C.magnifierRadius * diagonal, y: center.y + C.magnifierRadius * diagonal))
        path.addLine(to: CGPoint(x: center.x + C.magnifierHandleEnd * diagonal, y: center.y + C.magnifierHandleEnd * diagonal))
        magnifier.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance {
            magnifier.strokeColor = (isDarkAppearance ? NSColor.white : NSColor.black).cgColor
        }
        CATransaction.commit()
        siteIcon.frame = CGRect(x: C.iconX + (C.iconSize - S.faviconSize) / 2 + S.faviconOffset, y: (fieldH - S.faviconSize) / 2,
                                width: S.faviconSize, height: S.faviconSize)
        var x = C.textX
        if site != nil {
            let chipWidth = chip.fittingWidth
            chip.frame = CGRect(x: x + S.chipOffset, y: (fieldH - S.chipHeight) / 2, width: chipWidth, height: S.chipHeight)
            x += S.chipOffset + chipWidth + S.chipToText
        }
        var end = w - (tabTarget == nil ? C.iconX : S.keyTrailing)
        if !keycap.isHidden {
            end -= S.keySize.width
            keycap.frame = CGRect(x: end, y: (fieldH - S.keySize.height) / 2, width: S.keySize.width, height: S.keySize.height)
            end -= S.hintToKey
            let line = hint.lineHeight
            let hw = hint.naturalWidth
            end -= hw
            hint.place(textRect: CGRect(x: end, y: ((fieldH - line) / 2).rounded(.down), width: hw, height: line))
            end -= 8
        }
        field.frame = field.frameForText(x: x, width: max(end - x, 0), rowHeight: fieldH, lift: C.fieldTextLift)
        divider.isHidden = items.isEmpty
        divider.fill = { dark in (dark ? NSColor.white : NSColor.black).withAlphaComponent(C.dividerOpacity) }
        divider.frame = CGRect(x: C.dividerInset, y: fieldH, width: w - 2 * C.dividerInset, height: 0.5)
        var y = fieldH + 0.5 + C.listTopGap
        for row in rows {
            row.frame = CGRect(x: C.rowInset, y: y, width: w - 2 * C.rowInset, height: C.rowPitch)
            y += C.rowPitch
        }
    }
}

/// The bar's text field: 18pt medium, the placeholder at 25%.
@MainActor
final class CommandBarField: NSTextField {
    weak var panel: CommandBarPanelView?
    var placeholder = "" { didSet { updatePlaceholder() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: C.fieldFontSize, weight: .medium)
        textColor = .labelColor
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        setAccessibilityIdentifier("CommandBarField")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: C.fieldFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(C.placeholderOpacity),
        ])
    }

    /// The field's frame for text whose line box sits centred in the row, lifted by `lift`.
    func frameForText(x: CGFloat, width: CGFloat, rowHeight: CGFloat, lift: CGFloat) -> CGRect {
        let font = self.font ?? .systemFont(ofSize: C.fieldFontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        // NSTextField's cell draws its text 1.5pt above where SwiftUI's TextField does in the same box (measured
        // against captures of the SwiftUI bar, 3 Nov 2026).
        let y = ((rowHeight - line) / 2).rounded(.down) - lift + 1.5
        return CGRect(x: x - SidebarLabel.cellInset, y: y, width: width + 2 * SidebarLabel.cellInset, height: line)
    }
}

/// Arc's panel (SwiftUI's `CommandBarPanel`): a dark tint over the blurred page, a hairline border, a black
/// hairline just outside it, and a wide soft shadow.
@MainActor
final class CommandBarPanelBackground: NSView {
    private let material = NSVisualEffectView()
    private let tint = FillView()
    private let border = SidebarFlippedView()
    private let outline = SidebarFlippedView()
    /// A plain layer under the views (AppKit manages a view's own layer and resets its shadow).
    private let shadowLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Float(C.shadowOpacity)
        shadowLayer.shadowRadius = Self.shadowBlur
        // The view is flipped, so its layer's y runs down: +y is down the screen.
        shadowLayer.shadowOffset = CGSize(width: 0, height: C.shadowY)
        layer?.insertSublayer(shadowLayer, at: 0)
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = C.cornerRadius
        material.layer?.masksToBounds = true
        addSubview(material)
        tint.cornerRadius = C.cornerRadius
        addSubview(tint)
        border.layer?.cornerRadius = C.cornerRadius
        border.layer?.borderWidth = 1
        addSubview(border)
        outline.layer?.cornerRadius = C.cornerRadius + C.outlineWidth
        outline.layer?.borderWidth = C.outlineWidth
        outline.layer?.borderColor = NSColor.black.cgColor
        addSubview(outline)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI's shadow radius as Core Animation's blur.
    static var shadowBlur: CGFloat { C.shadowRadius }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func layout() {
        super.layout()
        let dark = isDarkAppearance
        material.material = dark ? .hudWindow : .popover
        material.frame = bounds
        tint.frame = bounds
        tint.fill = { dark in NSColor(white: dark ? C.darkTint : C.lightTint, alpha: C.tintOpacity) }
        border.frame = bounds
        border.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(C.borderOpacity) : NSColor.black.withAlphaComponent(0.12)).cgColor
        outline.frame = bounds.insetBy(dx: -C.outlineWidth, dy: -C.outlineWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: C.cornerRadius, cornerHeight: C.cornerRadius, transform: nil)
        if shadowLayer.superlayer !== layer { layer?.insertSublayer(shadowLayer, at: 0) }
        CATransaction.commit()
    }
}

/// The capsule after Tab, filled with the site's brand colour: Arc's for its defaults, otherwise the favicon's
/// dominant colour; with a soft glow of it.
@MainActor
final class SiteSearchChipView: SidebarFlippedView {
    private let label = SidebarLabel(size: S.chipFontSize, weight: .semibold, opacity: 1)
    private var siteID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerCurve = .continuous
        label.textColor = .white
        addSubview(label)
        layer?.shadowRadius = S.glowRadius / 2
        layer?.shadowOffset = CGSize(width: 0, height: -S.glowY)
        layer?.shadowOpacity = Float(S.glowOpacity)
    }

    var fittingWidth: CGFloat { S.chipLeading + label.naturalWidth + S.chipTrailing }

    func show(_ site: SiteSearch) {
        label.stringValue = site.name
        siteID = site.id
        setColor(site.color.flatMap(Self.color(hex:)) ?? S.fallbackColor)
        guard site.color == nil, let page = site.url(for: ""), let host = page.host(),
              let icon = URL(string: "https://\(host)/favicon.ico") else { return }
        Task { [weak self] in
            guard let image = await FaviconCache.shared.image(for: icon), let color = image.dominantColor,
                  let self, self.siteID == site.id else { return }
            self.setColor(color)
        }
    }

    private func setColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
        layer?.shadowColor = color.cgColor
    }

    /// "RRGGBB", in Display P3 like Arc's chips (sRGB FF0000 captures far less saturated than Arc's).
    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(displayP3Red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let line = label.lineHeight
        label.place(textRect: CGRect(x: S.chipLeading, y: ((bounds.height - line) / 2).rounded(.down), width: label.naturalWidth, height: line))
    }
}

/// The Tab keycap beside "Search <site>".
@MainActor
final class KeycapView: SidebarFlippedView {
    private let label = CenteredLabel(size: S.keyFontSize, weight: .semibold, opacity: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = S.keyCornerRadius
        layer?.backgroundColor = S.keyFill.cgColor
        label.text = "Tab"
        label.color = NSColor.white.withAlphaComponent(S.keyTextOpacity)
        addSubview(label)
    }

    override func layout() {
        super.layout()
        let line = label.lineHeight
        label.frame = CGRect(x: 0, y: ((bounds.height - line) / 2).rounded(.down), width: bounds.width, height: line)
    }
}

/// One suggestion (SwiftUI's `SuggestionRow`): an icon on a tile, "Title — url" with the part after the dash
/// dimmer, what Return will do, and the arrow box; on the space's accent colour while highlighted.
@MainActor
final class SuggestionRowView: SidebarFlippedView {
    private(set) var suggestion: CommandSuggestion = .instantLinks("")
    private var engine: SearchEngine?
    private var accent: NSColor = .controlAccentColor
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var highlighted = false { didSet { if highlighted != oldValue { apply() } } }

    private let fill = FillView()
    private let iconTile = FillView()
    private let symbol = SidebarImageView()
    private let favicon = FaviconImageView(side: C.rowIconSize)
    private let title = NSTextField(labelWithString: "")
    private let detailLabel = SidebarLabel(size: C.rowFontSize, weight: .medium, opacity: 1)
    private let arrowBox = FillView()
    private let arrow = SidebarImageView()
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.cornerRadius = C.rowCornerRadius
        addSubview(fill)
        iconTile.cornerRadius = 6
        addSubview(iconTile)
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        addSubview(favicon)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        title.wantsLayer = true
        addSubview(title)
        addSubview(detailLabel)
        arrowBox.cornerRadius = 6
        addSubview(arrowBox)
        arrow.image = symbolImage("arrow.right", pointSize: 13, weight: .semibold, box: NSSize(width: C.actionBoxSize, height: C.actionBoxSize),
                                  placement: .center)
        addSubview(arrow)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func configure(suggestion: CommandSuggestion, engine: SearchEngine, accent: ThemeColor) {
        let accentColor = NSColor(srgbRed: CGFloat(accent.r), green: CGFloat(accent.g), blue: CGFloat(accent.b), alpha: 1)
        guard suggestion != self.suggestion || engine != self.engine || accentColor != self.accent else { return }
        self.suggestion = suggestion
        self.engine = engine
        self.accent = accentColor
        switch suggestion {
        case .switchTab(let tab):
            favicon.isHidden = false
            favicon.show(tab: tab)
            symbol.isHidden = true
        case .history(let entry):
            favicon.isHidden = false
            favicon.show(page: entry.url, icon: nil)
            symbol.isHidden = true
        default:
            favicon.isHidden = true
            symbol.isHidden = false
            symbol.image = symbolImage(symbolName, box: NSSize(width: C.rowIconSize, height: C.rowIconSize), placement: .fit)
        }
        setAccessibilityLabel(titleText)
        apply()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private var symbolName: String {
        switch suggestion {
        case .open: "globe"
        case .search, .siteSearch, .instantLinks: "magnifyingglass"
        case .command: "command"
        default: "globe"
        }
    }

    private var titleText: String {
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
        case .search: "Search \(engine?.displayName ?? "")"
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

    private func apply() {
        let h = highlighted, accent = self.accent
        fill.fill = { _ in h ? accent : .clear }
        iconTile.fill = { _ in h ? .white : .clear }
        symbol.contentTintColor = h ? accent : .labelColor
        arrow.contentTintColor = h ? accent : .labelColor
        arrowBox.fill = { _ in h ? .white : NSColor.labelColor.withAlphaComponent(0.06) }
        arrow.alphaValue = h ? 1 : 0.7
        arrowBox.alphaValue = h ? 1 : 0.7
        let font = NSFont.systemFont(ofSize: C.rowFontSize, weight: .medium)
        let primary: NSColor = h ? .white : .labelColor
        let text = NSMutableAttributedString(string: titleText, attributes: [.font: font, .foregroundColor: primary])
        if let subtitle {
            let dim: NSColor = h ? NSColor.white.withAlphaComponent(0.7) : NSColor.labelColor.withAlphaComponent(0.5)
            text.append(NSAttributedString(string: " — " + subtitle, attributes: [.font: font, .foregroundColor: dim]))
        }
        title.attributedStringValue = text
        title.alphaValue = h ? 1 : C.rowTextOpacity
        detailLabel.isHidden = detail == nil
        detailLabel.stringValue = detail ?? ""
        detailLabel.textColor = primary
        detailLabel.alphaValue = h ? 0.8 : C.rowDetailOpacity
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let fillRect = CGRect(x: C.rowFillInset, y: C.rowFillInset, width: bounds.width - 2 * C.rowFillInset, height: C.rowFillHeight)
        fill.frame = fillRect
        let h = fillRect.height
        // SwiftUI centres each piece in the 44.5pt fill on the pixel grid, rounding up (14.25 → 14.5).
        func centred(_ size: CGFloat) -> CGFloat { fillRect.minY + ((h - size) / 2 * 2).rounded(.up) / 2 }
        let tile = CGRect(x: fillRect.minX + C.rowIconX, y: centred(C.rowIconTileSize),
                          width: C.rowIconTileSize, height: C.rowIconTileSize)
        iconTile.frame = tile
        let icon = CGRect(x: tile.minX + (tile.width - C.rowIconSize) / 2, y: tile.minY + (tile.height - C.rowIconSize) / 2,
                          width: C.rowIconSize, height: C.rowIconSize)
        symbol.frame = icon
        favicon.frame = icon
        var end = fillRect.maxX - C.actionBoxTrailing - C.actionBoxSize
        let box = CGRect(x: end, y: centred(C.actionBoxSize), width: C.actionBoxSize, height: C.actionBoxSize)
        arrowBox.frame = box
        arrow.frame = box
        end -= C.actionGap
        let line = detailLabel.lineHeight
        if detail != nil {
            let w = detailLabel.naturalWidth
            end -= w
            detailLabel.place(textRect: CGRect(x: end, y: centred(line), width: w, height: line))
            end -= C.actionGap
        }
        let x = fillRect.minX + C.rowTitleX
        let natural = ceil(title.attributedStringValue.size().width)
        let titleLine = ceil(NSFont.systemFont(ofSize: C.rowFontSize, weight: .medium).ascender
                             - NSFont.systemFont(ofSize: C.rowFontSize, weight: .medium).descender)
        title.frame = CGRect(x: x - SidebarLabel.cellInset, y: centred(titleLine),
                             width: min(natural, max(end - x, 0)) + 2 * SidebarLabel.cellInset, height: titleLine)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
