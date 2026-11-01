import AppKit
import KiteCore

/// Find in page (⌘F), matching Arc 1.171's two bars (`FindBarStyle`):
/// - Ask on Page off, Arc's `FindInPageView`: a 300×32 bar 10pt from the content card's top-right
///   corner with a magnifier, the query, an n/N counter ("Not Found" in red when nothing is found),
///   previous / next arrows, a divider and close. It appears and goes without animation.
/// - Ask on Page on, Arc's `AskInPageView`: a 400pt card 20pt from the corner reading "Find or ask…",
///   where Return on a query the page has no match for asks Claude (`onAsk`). The conversation
///   (`AskOnPagePanel`) sits in the card above the field; the card slides in from above and back up.
/// Return / ⇧Return step through matches; Esc closes it.
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    /// Measured from Arc in points; x positions are from the find bar's leading edge at its full
    /// 300pt (everything right of the query is laid out from the trailing edge, so it holds when
    /// narrower).
    enum Metrics {
        static let size = NSSize(width: FindBarStyle.find.width, height: 32)
        /// The symbol image has ~2.5pt of side bearing, so the glyph lands at 10 like Arc's.
        static let iconX: CGFloat = 8.5
        /// `FindInPageView.leftTitleMargin`.
        static let textX: CGFloat = 32
        static let counterTrailingX: CGFloat = 207
        static let previousCenterX: CGFloat = 225.5
        static let nextCenterX: CGFloat = 252
        /// `FindInPageView.layout`: 1.5pt left of the close button (26pt wide, 3pt from the edge).
        static let dividerX: CGFloat = 269.5
        static let closeCenterX: CGFloat = 283.5

        /// Ask card (`AskInPageInputView`): 12pt padding all round plus 6 more before the field.
        static let askPadding: CGFloat = 12
        static let askFieldX: CGFloat = 18
        static let askSpacing: CGFloat = 8
        /// In a conversation the field sits in a 4pt rounded fill, 6pt inside the card.
        static let askPillInset: CGFloat = 6
        static let askPillRadius: CGFloat = 4

        // Arc's named colours (Assets.car), light and dark.
        /// `PopoverBackground`.
        static let fill = dynamic(light: srgb(0xFA, 0xFB, 0xFF), dark: srgb(0x15, 0x1C, 0x30))
        /// `FindInPageSeparator`, both appearances.
        static let divider = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1)
        /// `ForegroundPrimary`: the query.
        static let text = dynamic(light: srgb(0x0E, 0x0F, 0x10, 0.9), dark: NSColor(white: 1, alpha: 0.8))
        /// `ForegroundSecondary`: the magnifier and placeholder.
        static let icon = dynamic(light: NSColor(white: 0, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.5))
        /// `PopoverInputText`: the arrows, close and counter.
        static let counter = dynamic(light: srgb(0x0E, 0x0F, 0x10, 0.8), dark: srgb(0xFA, 0xFB, 0xFF, 0.9))
        /// `FindInPageError`: "Not Found".
        static let error = NSColor(displayP3Red: 0.788, green: 0.2, blue: 0.2, alpha: 1)
        /// `PopoverShadow`.
        static let shadow = dynamic(light: srgb(0x15, 0x1C, 0x32, 0.3), dark: srgb(0x15, 0x1C, 0x32, 0.8))
        /// The ask card's 0.5pt edge and the conversation field's fill.
        static let askBorder = dynamic(light: NSColor(white: 0, alpha: 0.2), dark: NSColor(white: 1, alpha: 0.2))
        static let askPill = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.1))
        static let caret = srgb(0x11, 0x7A, 0xFD)

        private static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
        }

        private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
    }

    var onSearch: ((_ text: String, _ forward: Bool, _ findNext: Bool) -> Void)?
    var onClose: (() -> Void)?
    /// Return on a question (Ask on Page).
    var onAsk: ((String) -> Void)?
    /// The style changed (the controller moves the bar to its inset).
    var onStyleChange: ((FindBarStyle) -> Void)? {
        didSet { onStyleChange?(style) }
    }

    /// Ask on Page is on (read from the Kite menu's toggle each time the bar opens); it picks the style.
    var askEnabled = false {
        didSet {
            style = FindBarStyle(askEnabled: askEnabled)
            updatePlaceholder()
        }
    }
    private(set) var style: FindBarStyle = .find {
        didSet { if style != oldValue { applyStyle() } }
    }
    /// The conversation in the ask card; while it has questions every query is one.
    private(set) weak var askPanel: AskOnPagePanel?
    var inConversation: Bool { askPanel?.inConversation ?? false }
    /// Matches for the current query once its search came back (WebKit only says found or not).
    private var matches: Int?

    let field = NSTextField()
    private let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
    private let countLabel = NSTextField(labelWithString: "")
    private var previous: NSButton!
    private var next: NSButton!
    private var done: NSButton!
    private let divider = NSView()
    /// Ask card: "Ask" (tooltip "Submit"), shown while Return would ask.
    private var askButton: AskPillButton!
    /// Ask card: the conversation above the field.
    private let slot = NSView()
    /// The field's row.
    private let row = NSView()
    private let pill = NSView()
    private let trailing = NSStackView()
    private var styleConstraints: [NSLayoutConstraint] = []
    private var rowHeight: NSLayoutConstraint!
    private var preferredWidth: NSLayoutConstraint!
    private var maxWidth: NSLayoutConstraint!
    private var lastQuery = ""
    /// Bumped on each show and hide, so a slide that's overtaken doesn't hide the bar after.
    private var motion = 0

    init() {
        super.init(frame: NSRect(origin: .zero, size: Metrics.size))
        // Hidden until `reveal()`, so the ask card's first showing slides in too.
        isHidden = true
        wantsLayer = true
        layer?.masksToBounds = false

        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)

        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Find on page")

        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previous = Self.button("arrow.up", "Previous (⇧⌘G)") { [weak self] in self?.step(forward: false) }
        next = Self.button("arrow.down", "Next (⌘G)") { [weak self] in self?.step(forward: true) }
        done = Self.button("xmark", "Done (Esc)") { [weak self] in self?.onClose?() }
        // The close glyph already matched Arc at the old size; only the arrows grew.
        done.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        askButton = AskPillButton { [weak self] in self?.submit() }

        divider.wantsLayer = true
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Metrics.askPillRadius
        pill.layer?.cornerCurve = .continuous

        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = Metrics.askSpacing
        trailing.setHuggingPriority(.required, for: .horizontal)

        for view in [slot, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(pill)
        // The query field gives up width first: kept below the window's size priorities (490/500)
        // so the bar never holds the window open, and not hugging its text, which would shrink it.
        field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)

        rowHeight = row.heightAnchor.constraint(equalToConstant: Metrics.size.height)
        preferredWidth = widthAnchor.constraint(equalToConstant: Metrics.size.width)
        preferredWidth.priority = NSLayoutConstraint.Priority(240)
        maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.size.width)
        // Nothing in the slot until a conversation is embedded.
        let emptySlot = slot.heightAnchor.constraint(equalToConstant: 0)
        emptySlot.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferredWidth, maxWidth, rowHeight, emptySlot,
            slot.topAnchor.constraint(equalTo: topAnchor),
            slot.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: slot.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.askPillInset),
            pill.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Metrics.askPillInset),
            pill.topAnchor.constraint(equalTo: row.topAnchor),
            pill.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Metrics.askPillInset),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Style

    /// Lays the row out as Arc's find view or its ask card.
    private func applyStyle() {
        NSLayoutConstraint.deactivate(styleConstraints)
        styleConstraints = []
        let views: [NSView] = [icon, field, countLabel, previous, next, done, divider, askButton, trailing]
        for view in views { view.removeFromSuperview() }
        let w = CGFloat(style.width)
        preferredWidth.constant = w
        maxWidth.constant = w
        layer?.cornerRadius = CGFloat(style.cornerRadius)
        layer?.cornerCurve = style == .find ? .circular : .continuous
        layer?.borderWidth = style == .find ? 0 : 0.5

        func add(_ views: [NSView]) {
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(view)
            }
        }
        switch style {
        case .find:
            let parts: [NSView] = [icon, field, countLabel, previous, next, divider, done]
            add(parts)
            countLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            styleConstraints = parts.map { $0.centerYAnchor.constraint(equalTo: row.centerYAnchor) }
            styleConstraints += [
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.iconX),
                field.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.textX),
                field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),
                countLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: Metrics.counterTrailingX - w),
                previous.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: Metrics.previousCenterX - w),
                next.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: Metrics.nextCenterX - w),
                divider.leadingAnchor.constraint(equalTo: row.trailingAnchor, constant: Metrics.dividerX - w),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: CGFloat(FindBarStyle.dividerHeight(barHeight: Double(Metrics.size.height)))),
                done.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: Metrics.closeCenterX - w),
            ]
        case .ask:
            add([field, trailing])
            trailing.setViews([countLabel, previous, next, askButton, done], in: .trailing)
            // Arc: "No matches" and n/N are 13pt medium rounded, with 6pt more before the arrows.
            countLabel.font = Self.rounded(13, .medium)
            trailing.setCustomSpacing(Metrics.askSpacing + 6, after: countLabel)
            styleConstraints = [
                field.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.askFieldX),
                field.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -Metrics.askSpacing),
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Metrics.askPadding),
                field.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                trailing.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(styleConstraints)
        updateConversationLook()
        updateColors()
        onStyleChange?(style)
    }

    /// The field's size and fill: Arc's ask field is 16pt medium, 14pt in a rounded fill once a
    /// conversation has started; the find field is 13pt.
    private func updateConversationLook() {
        let talking = style == .ask && inConversation
        let size: CGFloat = style == .find ? 13 : (talking ? 14 : 16)
        field.font = .systemFont(ofSize: size, weight: style == .find ? .regular : .medium)
        pill.isHidden = !talking
        // The row: the find bar's 32pt, or the ask field's line with 12pt above and below (and
        // the fill's 6pt inset under it in a conversation).
        let line = ceil(field.intrinsicContentSize.height)
        rowHeight.constant = style == .find ? Metrics.size.height
            : line + 2 * Metrics.askPadding + (talking ? Metrics.askPillInset : 0)
        // In a conversation Arc's row drops the counter, arrows and close (the conversation has its own).
        for view in [countLabel, previous!, next!, done!] as [NSView] { view.isHidden = talking }
        updateAskButton()
        updatePlaceholder()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Metrics.fill.cgColor
            layer?.borderColor = Metrics.askBorder.cgColor
            divider.layer?.backgroundColor = Metrics.divider.cgColor
            pill.layer?.backgroundColor = Metrics.askPill.cgColor
            // `FindInPageView`'s NSShadow: blur 5, 3pt down, `PopoverShadow`.
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowColor = Metrics.shadow
            self.shadow = shadow
        }
        icon.contentTintColor = Metrics.icon
        field.textColor = Metrics.text
        for button in [previous!, next!, done!] { button.contentTintColor = Metrics.counter }
        updateCountColor()
        updatePlaceholder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateCountColor() {
        let notFound = countLabel.stringValue == AskOnPage.notFoundLabel
        countLabel.textColor = notFound ? Metrics.error
            : style == .ask ? Metrics.counter.withAlphaComponent(0.5) : Metrics.counter
    }

    // MARK: Conversation

    /// Puts a conversation in the ask card, above the field.
    func embed(_ panel: AskOnPagePanel) {
        if askPanel !== panel { askPanel?.removeFromSuperview() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: slot.topAnchor),
            panel.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
        ])
        panel.onChange = { [weak self] in self?.updateConversationLook() }
        askPanel = panel
        updateConversationLook()
    }

    // MARK: Showing

    /// Shows the bar: the find bar just appears, the ask card slides down from above (Arc's
    /// `CASpringAnimation`, response 0.28 s, damping fraction 0.63).
    func reveal() {
        motion += 1
        layer?.removeAnimation(forKey: "slide")
        let wasHidden = isHidden
        isHidden = false
        guard wasHidden, style.slides else { return }
        slide(from: CGFloat(FindBarStyle.askShowOffset), to: 0)
    }

    /// Hides the bar; the ask card slides back up first when `animated` (closing it, not
    /// switching tabs, where Arc drops it at once).
    func conceal(animated: Bool, completion: (() -> Void)? = nil) {
        motion += 1
        layer?.removeAnimation(forKey: "slide")
        guard animated, style.slides, !isHidden, window != nil else {
            isHidden = true
            completion?()
            return
        }
        let token = motion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.motion == token else { return }
                self.isHidden = true
                self.layer?.removeAnimation(forKey: "slide")
                completion?()
            }
        }
        slide(from: 0, to: CGFloat(FindBarStyle.askHiddenOffset(height: Double(frame.height))), holds: true)
        CATransaction.commit()
    }

    /// A vertical spring on the layer; positive is up (the bar's layer isn't flipped).
    private func slide(from: CGFloat, to: CGFloat, holds: Bool = false) {
        guard let layer else { return }
        let spring = FindBarStyle.spring
        let animation = CASpringAnimation(keyPath: "transform.translation.y")
        animation.mass = CGFloat(spring.mass)
        animation.stiffness = CGFloat(spring.stiffness)
        animation.damping = CGFloat(spring.damping)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        if holds {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: "slide")
    }

    // MARK: Query

    var query: String { field.stringValue }

    /// Focuses the field with Arc's blue caret.
    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Metrics.caret
    }

    func setQuery(_ text: String) {
        field.stringValue = text
        search()
    }

    var isAskMode: Bool {
        AskOnPage.isAskMode(enabled: askEnabled, query: query, matches: matches, inConversation: inConversation)
    }

    func updatePlaceholder() {
        let placeholder = NSAttributedString(
            string: AskOnPage.placeholder(enabled: askEnabled, inConversation: inConversation),
            attributes: [.foregroundColor: Metrics.icon, .font: field.font ?? .systemFont(ofSize: 13)])
        field.placeholderAttributedString = placeholder
        // While the field is being edited its field editor draws the placeholder it copied when
        // editing began; give it the new one too.
        if let editor = field.currentEditor() as? NSTextView,
           editor.responds(to: NSSelectorFromString("setPlaceholderAttributedString:")) {
            editor.setValue(placeholder, forKey: "placeholderAttributedString")
            editor.needsDisplay = true
        }
        if inConversation { countLabel.stringValue = "" }
    }

    /// Arc's "Ask" (tooltip "Submit") shows in the ask card while Return would ask, dimmed while
    /// there's nothing to send.
    private func updateAskButton() {
        guard let askButton else { return }
        askButton.isHidden = !(style == .ask && isAskMode)
        askButton.isEnabled = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clears the field after a question is sent, so the placeholder reads "Ask a question…".
    func clearQuery() {
        field.stringValue = ""
        lastQuery = ""
        matches = nil
        countLabel.stringValue = ""
        updateAskButton()
    }

    func show(_ result: FindResult) {
        matches = result.matches ?? (result.found ? 1 : 0)
        // In the counter's place: Arc's "No matches" (Ask on Page on) or "Not Found" (off).
        countLabel.stringValue = AskOnPage.matchLabel(query: query, found: result.found, matches: result.matches,
                                                      activeMatch: result.activeMatch, askEnabled: askEnabled)
        updateCountColor()
        updateAskButton()
    }

    /// The query field is being typed in (Arc's `CommandFTextField` takes ⌘F only then).
    var fieldHasFocus: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        // A changed query starts a new search; the same one moves to the next match.
        onSearch?(query, forward, query == lastQuery)
        lastQuery = query
    }

    private func submit() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAskMode, !question.isEmpty { onAsk?(question) }
    }

    private func search() {
        lastQuery = ""
        matches = nil
        countLabel.stringValue = ""
        updateAskButton()
        // In a conversation the field only takes questions.
        if inConversation { return }
        if query.isEmpty {
            onSearch?("", true, false)
        } else {
            step(forward: true)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if isAskMode {
                submit()
                return true
            }
            step(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    private static func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.isBordered = false
        button.toolTip = help
        // The image's description alone leaves the button reading as "Button".
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}

/// Arc's ask card "Ask" button (`0x10215b874`, tooltip "Submit"): callout semibold, 6pt above and
/// below and 12pt either side, on the theme colour (20% in dark, solid in light), half opacity
/// while disabled. Kite uses the system accent for Arc's theme colour.
@MainActor
final class AskPillButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
        attributedTitle = NSAttributedString(string: "Ask", attributes: [.font: font!, .foregroundColor: NSColor.white])
        toolTip = "Submit"
        setAccessibilityLabel("Ask")
        target = self
        self.action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 24, height: ceil(text.height) + 12)
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.2 : 1).cgColor
        }
    }

    @objc private func fire() { handler() }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
