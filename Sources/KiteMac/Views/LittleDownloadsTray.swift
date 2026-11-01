import AppKit
import KiteCore

/// Little Kite's downloads tray: Arc's `LittleBrowserDownloadsTrayViewController` (Arc 1.171
/// decomp; geometry in `LittleKite.DownloadsTray`). A 96pt strip along the bottom of the window,
/// over the page, with a card per download this window started. Clicks on the empty parts of the
/// strip go through to the page, as Arc's `PassthroughView` lets them.
@MainActor
final class LittleDownloadsTrayView: NSView {
    typealias Tray = LittleKite.DownloadsTray

    /// The card's ×.
    var onDismiss: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = TrayDocumentView()
    private var cards: [UUID: LittleDownloadCard] = [:]
    private var order: [UUID] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downloads")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `tray`'s cards with the list's current state of each.
    func show(_ tray: Tray, items: [UUID: DownloadItem]) {
        let ids = tray.ids.filter { items[$0] != nil }
        let added = ids.last.map { !order.contains($0) } ?? false
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for id in ids {
            guard let item = items[id] else { continue }
            let card = cards[id] ?? {
                let card = LittleDownloadCard()
                card.onDismiss = { [weak self] in self?.onDismiss?(id) }
                documentView.addSubview(card)
                cards[id] = card
                return card
            }()
            card.item = item
        }
        order = ids
        isHidden = ids.isEmpty
        layoutCards()
        // A new download scrolls into view, at the end of the row.
        if added, let last = ids.last, let card = cards[last] { documentView.scrollToVisible(card.frame) }
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    private func layoutCards() {
        let height = bounds.height
        documentView.frame = CGRect(x: 0, y: 0, width: max(Tray.contentWidth(count: order.count), scrollView.contentSize.width),
                                    height: height)
        for (index, id) in order.enumerated() {
            cards[id]?.frame = CGRect(x: Tray.itemX(at: index), y: Tray.inset, width: Tray.itemWidth, height: Tray.itemHeight)
        }
    }

    /// Only the cards take clicks; the rest of the strip belongs to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === scrollView || hit === scrollView.contentView || hit === documentView { return nil }
        return hit
    }

    /// For `ui` and tests: the cards' file names, in order.
    var cardTitles: [String] { order.compactMap { cards[$0]?.item?.fileName } }
}

private final class TrayDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One download: Arc's `LittleBrowserDownloadsTrayItemView`. A 250×56 card, corner 8, with a
/// soft shadow (black at 0.25, radius 3, 1pt down), `DownloadItemBackground` (hovered:
/// `DownloadItemBackgroundHovered`); a horizontal stack with 10pt insets and spacing: the file's
/// 32pt icon, the name (14pt, truncated in the middle) over a status line 5pt below, and a ×
/// that shows on hover. Clicking the card opens the file.
private final class LittleDownloadCard: NSView {
    var item: DownloadItem? {
        didSet { update(from: oldValue) }
    }
    var onDismiss: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = CardLabel(labelWithString: "")
    private let subtitleLabel = CardLabel(labelWithString: "")
    private let closeButton = NSButton()
    private var hovered = false {
        didSet {
            closeButton.isHidden = !hovered
            needsDisplay = true
            needsLayout = true
        }
    }

    private enum Metrics {
        static let inset: CGFloat = 10
        static let spacing: CGFloat = 10
        static let iconSize: CGFloat = 32
        static let cornerRadius: CGFloat = 8
        static let titleSize: CGFloat = 14
        /// The status line's size isn't in the decomp (a named text style); Kite's.
        static let subtitleSize: CGFloat = 12
        static let lineSpacing: CGFloat = 5
        static let closeSize: CGFloat = 16
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        // Arc's card turns masksToBounds off so its shadow shows.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: Metrics.titleSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: Metrics.subtitleSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from Tray")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.contentTintColor = .labelColor
        closeButton.toolTip = "Remove from Tray"
        closeButton.setAccessibilityLabel("Remove from Tray")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update(from old: DownloadItem?) {
        guard let item else { return }
        if old?.path != item.path || old?.fileName != item.fileName || old?.state != item.state { iconView.image = item.icon }
        titleLabel.stringValue = item.fileName
        subtitleLabel.stringValue = item.state == .complete && !DownloadsModel.shared.fileExists(item)
            ? "File deleted or moved" : DownloadText.subtitle(item)
        setAccessibilityLabel(item.fileName)
        setAccessibilityValue(subtitleLabel.stringValue)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = CGRect(x: Metrics.inset, y: (h - Metrics.iconSize) / 2, width: Metrics.iconSize, height: Metrics.iconSize)
        closeButton.frame = CGRect(x: bounds.width - Metrics.inset - Metrics.closeSize, y: (h - Metrics.closeSize) / 2,
                                   width: Metrics.closeSize, height: Metrics.closeSize)
        let textX = iconView.frame.maxX + Metrics.spacing
        // Arc's stack drops the hidden × and gives its room to the text.
        let textEnd = (closeButton.isHidden ? bounds.width - Metrics.inset : closeButton.frame.minX) - Metrics.spacing
        let textWidth = max(0, textEnd - textX)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitleLabel.intrinsicContentSize.height)
        let top = (h - titleHeight - Metrics.lineSpacing - subtitleHeight) / 2
        titleLabel.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
        subtitleLabel.frame = CGRect(x: textX, y: top + titleHeight + Metrics.lineSpacing, width: textWidth, height: subtitleHeight)
    }

    override func updateLayer() {
        let color = hovered ? DownloadColors.itemBackgroundHovered : DownloadColors.itemBackground
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
        layer?.masksToBounds = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // Kept here, so a click on the card doesn't drag the window (it moves by its background).
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let item, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        DownloadsModel.shared.open(item)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item else { return false }
        DownloadsModel.shared.open(item)
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeClicked() { onDismiss?() }
}

/// The card's text: clicks go to the card.
private final class CardLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
