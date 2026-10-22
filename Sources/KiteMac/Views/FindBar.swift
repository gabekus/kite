import AppKit

/// Find in page (⌘F): a small floating bar at the top right of the page.
/// Return / ⇧Return step through matches; Esc closes it.
@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearch: ((_ text: String, _ forward: Bool, _ findNext: Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var lastQuery = ""

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = .black.withAlphaComponent(0.2)
        self.shadow = shadow

        field.placeholderString = "Find on page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let previous = Self.button("chevron.up", "Previous (⇧⌘G)") { [weak self] in self?.step(forward: false) }
        let next = Self.button("chevron.down", "Next (⌘G)") { [weak self] in self?.step(forward: true) }
        let done = Self.button("xmark", "Done (Esc)") { [weak self] in self?.onClose?() }

        let stack = NSStackView(views: [field, countLabel, previous, next, done])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var query: String { field.stringValue }

    func setQuery(_ text: String) {
        field.stringValue = text
        search()
    }

    func show(_ result: FindResult) {
        if let matches = result.matches {
            countLabel.stringValue = matches == 0 ? "0/0" : "\(result.activeMatch ?? 0)/\(matches)"
        } else {
            countLabel.stringValue = result.found ? "" : "Not found"
        }
        countLabel.textColor = result.found ? .secondaryLabelColor : .systemRed
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

    // MARK: NSSearchFieldDelegate

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
        button.isBordered = false
        button.toolTip = help
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
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
