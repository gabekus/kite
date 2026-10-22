import AppKit

/// Find in page (⌘F), matching Arc 1.169: a 300×32 navy bar at the content
/// card's top-right corner with a magnifier, the query, an n/N counter, and
/// previous / next / close. Return / ⇧Return step through matches; Esc closes it.
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    /// Measured from Arc in points; x positions are from the bar's leading edge.
    enum Metrics {
        static let size = NSSize(width: 300, height: 32)
        static let cornerRadius: CGFloat = 6
        /// Gap to the content card's top and trailing edges.
        static let inset: CGFloat = 10
        static let iconX: CGFloat = 10
        static let textX: CGFloat = 33
        static let counterTrailingX: CGFloat = 205
        static let previousCenterX: CGFloat = 225.5
        static let nextCenterX: CGFloat = 251.5
        static let closeCenterX: CGFloat = 283.5
        static let fill = NSColor(srgbRed: 0x1B / 255, green: 0x26 / 255, blue: 0x3F / 255, alpha: 1)
        static let text = NSColor(srgbRed: 0xD9 / 255, green: 0xDB / 255, blue: 0xDE / 255, alpha: 1)
        static let counter = NSColor(srgbRed: 0xE8 / 255, green: 0xEA / 255, blue: 0xEF / 255, alpha: 1)
        static let caret = NSColor(srgbRed: 0x41 / 255, green: 0x8F / 255, blue: 0xF8 / 255, alpha: 1)
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
        layer?.cornerCurve = .continuous
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        self.shadow = shadow

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Metrics.text
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)

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

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = Metrics.counter
        countLabel.alignment = .right

        let previous = Self.button("chevron.up", "Previous (⇧⌘G)") { [weak self] in self?.step(forward: false) }
        let next = Self.button("chevron.down", "Next (⌘G)") { [weak self] in self?.step(forward: true) }
        let done = Self.button("xmark", "Done (Esc)") { [weak self] in self?.onClose?() }

        for view in [icon, field, countLabel, previous, next, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.size.width),
            heightAnchor.constraint(equalToConstant: Metrics.size.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.iconX),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.counterTrailingX),
            previous.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.previousCenterX),
            next.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.nextCenterX),
            done.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.closeCenterX),
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
        button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
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
