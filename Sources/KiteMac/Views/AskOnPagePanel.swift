import AppKit
import KiteCore

/// Ask on Page's conversation, under the find bar (Arc's `AskInPageConversationView`): each
/// question with Claude's answer, the page's quotes as buttons that find them on the page.
@MainActor
final class AskOnPagePanel: NSView {
    enum Metrics {
        /// Gap between the find bar and the panel. Not measured in Arc (its panel was never opened here).
        static let gap: CGFloat = 6
        static let padding: CGFloat = 12
        static let spacing: CGFloat = 8
        static let maxHeight: CGFloat = 420
        static let dim = NSColor(srgbRed: 0x96 / 255, green: 0x9B / 255, blue: 0xA4 / 255, alpha: 1)
        static let quoteBar = NSColor(srgbRed: 0x11 / 255, green: 0x7A / 255, blue: 0xFD / 255, alpha: 1)
        static let warning = NSColor(srgbRed: 0xF5 / 255, green: 0xC2 / 255, blue: 0x4C / 255, alpha: 1)
    }

    private(set) var exchanges: [AskOnPage.Exchange] = []
    /// Set on the first answer to a page that had to be cut.
    private var longPageNote: String?
    /// Searches the page for a quote; reports whether it was found.
    var onFindQuote: ((_ quote: String, _ found: @escaping (Bool) -> Void) -> Void)?

    let claude = AskOnPageClaude()
    private let scrollView = NSScrollView()
    private let stack = FlippedStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var notFoundQuotes: Set<String> = []

    var inConversation: Bool { !exchanges.isEmpty }

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = FindBar.Metrics.fill.cgColor
        layer?.cornerRadius = FindBar.Metrics.cornerRadius
        layer?.cornerCurve = .circular
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        self.shadow = shadow
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ask on Page")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.spacing
        stack.edgeInsets = NSEdgeInsets(top: Metrics.padding, left: Metrics.padding, bottom: Metrics.padding, right: Metrics.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The panel takes the find bar's width; a stack hugging its content would narrow the bar.
        stack.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            heightConstraint,
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Starts an exchange; returns its index for `answer(_:at:)`.
    func begin(_ question: String) -> Int {
        exchanges.append(AskOnPage.Exchange(question: question))
        rebuild()
        return exchanges.count - 1
    }

    func answer(_ answer: String?, at index: Int, longPage fraction: Double? = nil) {
        guard exchanges.indices.contains(index) else { return }
        if let answer {
            exchanges[index].answer = answer
        } else {
            exchanges[index].failed = true
        }
        if let fraction, longPageNote == nil { longPageNote = AskOnPage.longPageNote(fractionRead: fraction) }
        rebuild()
    }

    /// Back to plain find: drops the conversation and any answer still coming.
    func reset() {
        claude.cancel()
        exchanges = []
        longPageNote = nil
        notFoundQuotes = []
        rebuild()
    }

    // MARK: Layout

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        isHidden = exchanges.isEmpty
        guard !exchanges.isEmpty else { heightConstraint.constant = 0; return }
        let width = FindBar.Metrics.size.width - 2 * Metrics.padding
        if let longPageNote { stack.addArrangedSubview(label(longPageNote, size: 11, color: Metrics.dim, width: width)) }
        for exchange in exchanges {
            stack.addArrangedSubview(label(exchange.question, size: 13, weight: .semibold, color: FindBar.Metrics.counter, width: width))
            if exchange.failed {
                stack.addArrangedSubview(warningRow(AskOnPage.errorMessage, width: width))
            } else if let answer = exchange.answer {
                for part in AskOnPage.parts(of: answer) {
                    switch part {
                    case .text(let text):
                        stack.addArrangedSubview(markdownLabel(text, width: width))
                    case .quote(let quote):
                        stack.addArrangedSubview(quoteButton(quote, width: width))
                        if notFoundQuotes.contains(quote) {
                            stack.addArrangedSubview(warningRow(AskOnPage.quoteNotFoundMessage, width: width))
                        }
                    }
                }
            } else {
                stack.addArrangedSubview(PulsingLabel(width: width))
            }
        }
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        heightConstraint.constant = min(height, Metrics.maxHeight)
        stack.frame.size.height = height
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = scrollView.documentView else { return }
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scrollView.contentView.bounds.height)))
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        label.isSelectable = true
        return label
    }

    private func markdownLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = self.label(text, size: 13, color: FindBar.Metrics.text, width: width)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? NSMutableAttributedString(markdown: text, options: options) else { return label }
        let font = NSFont.systemFont(ofSize: 13)
        let whole = NSRange(location: 0, length: parsed.length)
        parsed.addAttribute(.foregroundColor, value: FindBar.Metrics.text, range: whole)
        parsed.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 13) ?? font
            parsed.addAttribute(.font, value: intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : styled, range: range)
            if intent.contains(.stronglyEmphasized) { parsed.addAttribute(.foregroundColor, value: FindBar.Metrics.counter, range: range) }
        }
        label.attributedStringValue = parsed
        return label
    }

    private func quoteButton(_ quote: String, width: CGFloat) -> NSView {
        let button = QuoteButton(quote: quote, width: width) { [weak self] in self?.find(quote) }
        return button
    }

    private func warningRow(_ text: String, width: CGFloat) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Metrics.warning
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        let text = label(text, size: 12, color: Metrics.warning, width: width - 18)
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 5
        return row
    }

    private func find(_ quote: String) {
        let terms = AskOnPage.searchTerms(forQuote: quote)
        func attempt(_ index: Int) {
            guard index < terms.count else {
                notFoundQuotes.insert(quote)
                return rebuild()
            }
            onFindQuote?(terms[index]) { [weak self] found in
                guard let self else { return }
                if found {
                    if notFoundQuotes.remove(quote) != nil { rebuild() }
                } else {
                    attempt(index + 1)
                }
            }
        }
        attempt(0)
    }
}

/// A quote from the page; clicking it finds it there (Arc's `QuoteView` / `FindQuoteButton`).
@MainActor
private final class QuoteButton: NSView {
    private let action: () -> Void

    init(quote: String, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let bar = NSBox()
        bar.boxType = .custom
        bar.borderWidth = 0
        bar.fillColor = AskOnPagePanel.Metrics.quoteBar
        let text = NSTextField(wrappingLabelWithString: "“\(quote)”")
        text.font = NSFontManager.shared.convert(.systemFont(ofSize: 12.5), toHaveTrait: .italicFontMask)
        text.textColor = FindBar.Metrics.text
        text.preferredMaxLayoutWidth = width - 10
        for view in [bar, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 2),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
        toolTip = "Find on Page"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Find on Page: \(quote)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// "…" pulsing while Claude answers (Arc's `PulseModifier`).
@MainActor
private final class PulsingLabel: NSTextField {
    convenience init(width: CGFloat) {
        self.init(labelWithString: "Thinking…")
        font = .systemFont(ofSize: 13)
        textColor = AskOnPagePanel.Metrics.dim
        wantsLayer = true
        setAccessibilityLabel("Answering")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
