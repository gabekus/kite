import AppKit
import KiteCore

/// Arc's Little Arc "Open In" menu (`LittleBrowserMoveMenuWindowController`): a borderless child window
/// of the Little Kite window, its top-trailing corner on the Open In box's, with a "Search Spaces…" field
/// and the spaces below it. Typing filters, ↑/↓ move the highlight, Return or a click moves the page,
/// Escape, a click outside or the window losing key closes it. Logic in `LittleKite.MoveMenu`.
@MainActor
final class LittleMoveMenuController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private typealias Menu = LittleKite.MoveMenu

    struct Option {
        let id: UUID
        let name: String
        let color: NSColor
    }

    private let options: [UUID: Option]
    private var menu: Menu
    private weak var parent: NSWindow?
    private weak var anchor: NSView?
    private let onSelect: (UUID) -> Void
    private let panel: LittleMoveMenuPanel
    private let content = LittleMoveMenuContent()
    private var clickMonitor: Any?
    private(set) var isOpen = false
    var didClose: (() -> Void)?

    init(parent: NSWindow, anchor: NSView, options: [Option], primaryID: UUID?, onSelect: @escaping (UUID) -> Void) {
        self.parent = parent
        self.anchor = anchor
        self.options = Dictionary(options.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        menu = Menu(options: options.map { .init(id: $0.id, name: $0.name) }, primaryID: primaryID)
        self.onSelect = onSelect
        panel = LittleMoveMenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = parent.appearance
        panel.title = "Open In"
        panel.delegate = self
        panel.contentView = content
        content.field.delegate = self
        content.onHover = { [weak self] id in
            self?.menu.hover(id)
            self?.refresh(resize: false)
        }
        content.onClick = { [weak self] id in self?.choose(id) }
    }

    func show() {
        guard let parent, !isOpen else { return }
        isOpen = true
        refresh(resize: true)
        parent.addChildWindow(panel, ordered: .above)
        // Key without ordering front: a background test window stays behind the user's windows.
        if UIDiagnostics.enabledByEnvironment { panel.makeKey() } else { panel.makeKeyAndOrderFront(nil) }
        panel.makeFirstResponder(content.field)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // A click on the chevron toggles the menu itself.
            if event.window !== self.panel, !self.isOnAnchor(event) { self.dismiss() }
            return event
        }
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        didClose?()
    }

    private func isOnAnchor(_ event: NSEvent) -> Bool {
        guard let anchor, event.window === anchor.window else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }

    private func choose(_ id: UUID) {
        dismiss()
        onSelect(id)
    }

    /// Redraws the rows; with `resize`, fits the panel to them, keeping its top-trailing corner on the anchor's.
    private func refresh(resize: Bool) {
        let rows = menu.results.compactMap { options[$0.id] }
        content.show(rows: rows, highlightedID: menu.highlightedID, primaryID: menu.primaryID)
        guard resize, let anchor, let window = anchor.window else { return }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = NSSize(width: Menu.width, height: menu.height)
        panel.setFrame(NSRect(x: anchorRect.maxX - size.width, y: anchorRect.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        menu.updateQuery(content.field.stringValue)
        refresh(resize: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            menu.selectNext()
        case #selector(NSResponder.moveUp(_:)):
            menu.selectPrevious()
        case #selector(NSResponder.insertNewline(_:)):
            if let id = menu.highlighted?.id { choose(id) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
        refresh(resize: false)
        content.scrollToHighlighted()
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        // A test window is never key in the first place; only a real resign closes it.
        if !UIDiagnostics.enabledByEnvironment { dismiss() }
    }
}

/// Borderless, but it takes keys for the search field.
private final class LittleMoveMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The menu's background, search row and rows, top-left origin.
private final class LittleMoveMenuContent: NSView {
    private typealias Menu = LittleKite.MoveMenu
    private typealias M = ArcMetrics.LittleWindow

    let field = NSTextField()
    var onHover: ((UUID) -> Void)?
    var onClick: ((UUID) -> Void)?

    private let background = NSVisualEffectView()
    private let icon = NSImageView()
    private let divider = NSView()
    private let scroll = NSScrollView()
    private let list = MoveMenuListView()
    private var rows: [LittleMoveMenuRow] = []
    private var highlightedID: UUID?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = M.openInCornerRadius + 3.5
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        addSubview(background)

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Menu.searchIconSize, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        icon.imageAlignment = .alignCenter
        addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: M.hostFontSize)
        field.placeholderString = Menu.placeholder
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Search Spaces")
        addSubview(field)

        divider.wantsLayer = true
        addSubview(divider)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Open In")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        background.layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
        divider.layer?.backgroundColor = ink.withAlphaComponent(0.1).cgColor
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let search = CGFloat(Menu.searchHeight)
        let frame = CGFloat(Menu.searchIconFrame)
        icon.frame = CGRect(x: 10, y: (search - frame) / 2, width: frame, height: frame)
        let fieldHeight: CGFloat = 17
        field.frame = CGRect(x: icon.frame.maxX + 4, y: (search - fieldHeight) / 2,
                             width: max(0, bounds.width - icon.frame.maxX - 16), height: fieldHeight)
        divider.frame = CGRect(x: 0, y: search - 0.5, width: bounds.width, height: 0.5)
        scroll.frame = CGRect(x: 0, y: search, width: bounds.width, height: max(0, bounds.height - search))
        let rowHeight = CGFloat(Menu.rowHeight)
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: rowHeight * CGFloat(rows.count))
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: rowHeight * CGFloat(i), width: list.bounds.width, height: rowHeight)
        }
        updateColors()
    }

    func show(rows options: [LittleMoveMenuController.Option], highlightedID: UUID?, primaryID: UUID?) {
        self.highlightedID = highlightedID
        if rows.map(\.id) != options.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = options.map { option in
                let row = LittleMoveMenuRow(option: option, isPrimary: option.id == primaryID)
                row.onHover = { [weak self] in self?.onHover?(option.id) }
                row.onClick = { [weak self] in self?.onClick?(option.id) }
                list.addSubview(row)
                return row
            }
            needsLayout = true
        }
        for row in rows { row.isHighlighted = row.id == highlightedID }
    }

    func scrollToHighlighted() {
        layoutSubtreeIfNeeded()
        guard let row = rows.first(where: { $0.id == highlightedID }) else { return }
        list.scrollToVisible(row.frame)
    }
}

/// One space: its colour, its name, and ⌘O on the space "Open in" names.
private final class LittleMoveMenuRow: NSView {
    private typealias M = ArcMetrics.LittleWindow

    let id: UUID
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { updateColors() } }
    }

    private let highlight = NSView()
    private let swatch = NSView()
    private let label: NSTextField
    private let keycap = NSTextField(labelWithString: "⌘O")
    private let isPrimary: Bool

    override var isFlipped: Bool { true }

    init(option: LittleMoveMenuController.Option, isPrimary: Bool) {
        id = option.id
        self.isPrimary = isPrimary
        label = NSTextField(labelWithString: option.name)
        super.init(frame: .zero)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.cornerCurve = .continuous
        addSubview(highlight)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 7
        swatch.layer?.backgroundColor = option.color.cgColor
        addSubview(swatch)
        label.font = .systemFont(ofSize: M.openInFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        keycap.font = .systemFont(ofSize: 12, weight: .semibold)
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 4
        keycap.isHidden = !isPrimary
        addSubview(keycap)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(option.name)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        highlight.frame = bounds.insetBy(dx: 6, dy: 4)
        swatch.frame = CGRect(x: 16, y: (h - 14) / 2, width: 14, height: 14)
        let keycapWidth = ceil(keycap.attributedStringValue.size().width) + 8
        keycap.frame = CGRect(x: bounds.width - 16 - keycapWidth, y: (h - M.keycapHeight) / 2, width: keycapWidth, height: M.keycapHeight)
        let labelHeight: CGFloat = 17
        let trailing = isPrimary ? keycap.frame.minX - 8 : bounds.width - 16
        label.frame = CGRect(x: swatch.frame.maxX + 10, y: (h - labelHeight) / 2, width: max(0, trailing - swatch.frame.maxX - 10), height: labelHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        highlight.layer?.backgroundColor = isHighlighted ? ink.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        label.textColor = ink
        keycap.textColor = ink.withAlphaComponent(0.8)
        keycap.layer?.backgroundColor = ink.withAlphaComponent(0.1).cgColor
        setAccessibilitySelected(isHighlighted)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private final class MoveMenuListView: NSView {
    override var isFlipped: Bool { true }
}
