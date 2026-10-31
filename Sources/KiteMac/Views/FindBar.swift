import AppKit

/// Find in page (⌘F), matching Arc 1.169: a 300×32 navy bar at the content
/// card's top-right corner with a magnifier, the query, an n/N counter,
/// previous / next arrows, a divider and close. Return / ⇧Return step through matches; Esc closes it.
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    /// Measured from Arc in points; x positions are from the bar's leading edge at its full 300pt
    /// (everything right of the query is laid out from the trailing edge, so it holds when narrower).
    enum Metrics {
        static let size = NSSize(width: 300, height: 32)
        static let cornerRadius: CGFloat = 6
        /// Gap to the content card's top and trailing edges.
        static let inset: CGFloat = 10
        /// The symbol image has ~2.5pt of side bearing, so the glyph lands at 10 like Arc's.
        static let iconX: CGFloat = 8.5
        static let textX: CGFloat = 32
        static let counterTrailingX: CGFloat = 207
        static let previousCenterX: CGFloat = 225.5
        static let nextCenterX: CGFloat = 252
        static let dividerX: CGFloat = 270
        static let closeCenterX: CGFloat = 283.5
        // Colours are tuned so a screen capture of Kite reads the same as one of Arc:
        // captures in the display profile read ~10–15 levels lighter once converted
        // to sRGB, so Arc's captured #1B263F fill is really about #141D32.
        static let fill = NSColor(srgbRed: 0x14 / 255, green: 0x1D / 255, blue: 0x32 / 255, alpha: 1)
        static let divider = NSColor(srgbRed: 0x0D / 255, green: 0x15 / 255, blue: 0x2A / 255, alpha: 1)
        static let text = NSColor(srgbRed: 0xD2 / 255, green: 0xD4 / 255, blue: 0xD8 / 255, alpha: 1)
        static let icon = NSColor(srgbRed: 0x96 / 255, green: 0x9B / 255, blue: 0xA4 / 255, alpha: 1)
        static let counter = NSColor(srgbRed: 0xE8 / 255, green: 0xEA / 255, blue: 0xEF / 255, alpha: 1)
        static let caret = NSColor(srgbRed: 0x11 / 255, green: 0x7A / 255, blue: 0xFD / 255, alpha: 1)
    }

    var onSearch: ((_ text: String, _ forward: Bool, _ findNext: Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private var lastQuery = ""

    init() {
        super.init(frame: NSRect(origin: .zero, size: Metrics.size))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Metrics.fill.cgColor
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .circular
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        self.shadow = shadow

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Metrics.icon
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)

        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Metrics.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Find on page")

        countLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        countLabel.textColor = Metrics.counter
        countLabel.alignment = .right

        let previous = Self.button("arrow.up", "Previous (⇧⌘G)") { [weak self] in self?.step(forward: false) }
        let next = Self.button("arrow.down", "Next (⌘G)") { [weak self] in self?.step(forward: true) }
        let done = Self.button("xmark", "Done (Esc)") { [weak self] in self?.onClose?() }
        // The close glyph already matched Arc at the old size; only the arrows grew.
        done.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Metrics.divider

        for view in [icon, field, countLabel, previous, next, divider, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Arc's 300pt, but never wider than the card leaves room for (the window can be narrow
        // enough since the card can be under 320pt): the query field gives up the width. Kept
        // below the window's size priorities (490/500) so it never holds the window open.
        field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        // And doesn't hug its text, which would otherwise shrink the bar to fit the query.
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        let preferredWidth = widthAnchor.constraint(equalToConstant: Metrics.size.width)
        preferredWidth.priority = NSLayoutConstraint.Priority(240)
        let w = Metrics.size.width
        NSLayoutConstraint.activate([
            preferredWidth,
            widthAnchor.constraint(lessThanOrEqualToConstant: w),
            heightAnchor.constraint(equalToConstant: Metrics.size.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.iconX),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.counterTrailingX - w),
            previous.centerXAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.previousCenterX - w),
            next.centerXAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.nextCenterX - w),
            divider.leadingAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.dividerX - w),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            done.centerXAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.closeCenterX - w),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    func show(_ result: FindResult) {
        if let matches = result.matches {
            countLabel.stringValue = matches == 0 ? "0/0" : "\(result.activeMatch ?? 0)/\(matches)"
        } else {
            countLabel.stringValue = result.found ? "" : "0/0"
        }
    }

    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        // A changed query starts a new search; the same one moves to the next match.
        onSearch?(query, forward, query == lastQuery)
        lastQuery = query
    }

    private func search() {
        lastQuery = ""
        countLabel.stringValue = ""
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
            step(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    private static func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.contentTintColor = Metrics.counter
        button.isBordered = false
        button.toolTip = help
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
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
