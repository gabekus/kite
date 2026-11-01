import AppKit

/// A short confirmation ("Copied Current URL") at the content card's top-right
/// corner, matching Arc 1.169: a navy pill with an optional share button.
/// One per window; showing a new message replaces the current one and restarts the timer.
@MainActor
final class ToastView: NSView {
    /// Measured from Arc in points.
    enum Metrics {
        static let height: CGFloat = 46
        static let cornerRadius: CGFloat = 8
        /// Gap to the content card's top and trailing edges.
        static let top: CGFloat = 9
        static let trailing: CGFloat = 8
        // The label's text sits ~1pt inside its frame on each side, so these
        // land the text at 12.5 from the leading edge and 14 before the button.
        static let leading: CGFloat = 11.5
        static let trailingPadding: CGFloat = 13
        static let buttonSize = NSSize(width: 31, height: 27)
        static let buttonTrailing: CGFloat = 11.5
        static let textToButton: CGFloat = 8
        // Tuned so a screen capture of Kite reads like one of Arc (#556692 → #465376,
        // button ~#7D88A4): display-profile captures read lighter once converted to sRGB.
        static let topColor = NSColor(srgbRed: 0x40 / 255, green: 0x52 / 255, blue: 0x83 / 255, alpha: 1)
        static let bottomColor = NSColor(srgbRed: 0x30 / 255, green: 0x3C / 255, blue: 0x5F / 255, alpha: 1)
        static let buttonColor = NSColor(srgbRed: 0x68 / 255, green: 0x75 / 255, blue: 0x96 / 255, alpha: 1)
        static let duration: Duration = .seconds(4.6)
    }

    private let gradient = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")
    /// The button's rounded square; a plain view so the button's intrinsic height can't stretch it.
    private let shareBackground = NSView()
    private let shareButton = NSButton()
    private var labelTrailing: NSLayoutConstraint!
    private var shareURL: URL?
    /// A text button in the share button's place ("Save" on Capture Full Page's toast).
    private let actionBackground = NSView()
    private let actionButton = NSButton()
    private var action: (() -> Void)?
    /// With an undo handler the share button is Arc's Undo accessory ("Download renamed!").
    private var undo: (() -> Void)?
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        gradient.colors = [Metrics.topColor.cgColor, Metrics.bottomColor.cgColor]
        // Top to bottom; the layer's y axis points up.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.cornerRadius = Metrics.cornerRadius
        gradient.cornerCurve = .continuous
        layer?.addSublayer(gradient)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        self.shadow = shadow
        alphaValue = 0
        isHidden = true

        label.font = .systemFont(ofSize: 13.5, weight: .semibold)
        label.textColor = .white

        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareButton.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        shareButton.contentTintColor = .white
        shareButton.isBordered = false
        shareButton.target = self
        shareButton.action = #selector(share)
        shareBackground.wantsLayer = true
        shareBackground.layer?.backgroundColor = Metrics.buttonColor.cgColor
        shareBackground.layer?.cornerRadius = 6
        shareBackground.layer?.cornerCurve = .continuous
        shareBackground.layer?.masksToBounds = true
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareBackground.addSubview(shareButton)

        actionButton.isBordered = false
        actionButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        actionButton.contentTintColor = .white
        actionButton.target = self
        actionButton.action = #selector(runAction)
        actionBackground.wantsLayer = true
        actionBackground.layer?.backgroundColor = Metrics.buttonColor.cgColor
        actionBackground.layer?.cornerRadius = 6
        actionBackground.layer?.cornerCurve = .continuous
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionBackground.addSubview(actionButton)
        actionBackground.isHidden = true

        for view in [label, shareBackground, actionBackground] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        labelTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.trailingPadding)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.leading),
            shareBackground.widthAnchor.constraint(equalToConstant: Metrics.buttonSize.width),
            shareBackground.heightAnchor.constraint(equalToConstant: Metrics.buttonSize.height),
            shareBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.buttonTrailing),
            shareButton.centerXAnchor.constraint(equalTo: shareBackground.centerXAnchor),
            shareButton.centerYAnchor.constraint(equalTo: shareBackground.centerYAnchor),
            shareButton.widthAnchor.constraint(equalTo: shareBackground.widthAnchor),
            shareButton.heightAnchor.constraint(equalTo: shareBackground.heightAnchor),
            actionBackground.heightAnchor.constraint(equalToConstant: Metrics.buttonSize.height),
            actionBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.buttonTrailing),
            actionButton.leadingAnchor.constraint(equalTo: actionBackground.leadingAnchor, constant: 9),
            actionButton.trailingAnchor.constraint(equalTo: actionBackground.trailingAnchor, constant: -9),
            actionButton.centerYAnchor.constraint(equalTo: actionBackground.centerYAnchor),
            labelTrailing,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    // Only the share button takes clicks; the rest goes to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === shareButton || hit === actionButton ? hit : nil
    }

    /// Shows `message`; with `shareURL`, Arc's share button sits on the right, with `undo` the same
    /// button is Arc's Undo accessory (arrow.uturn.backward), or with `action` a text button
    /// (title, handler) does.
    func show(_ message: String, shareURL: URL? = nil, undo: (() -> Void)? = nil,
              action: (title: String, run: () -> Void)? = nil, for duration: Duration = Metrics.duration) {
        label.stringValue = message
        self.shareURL = action == nil && undo == nil ? shareURL : nil
        self.undo = action == nil ? undo : nil
        self.action = action?.run
        shareButton.image = self.undo != nil
            ? NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
            : NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareBackground.isHidden = self.shareURL == nil && self.undo == nil
        actionBackground.isHidden = action == nil
        actionButton.title = action?.title ?? ""
        let buttonWidth = action == nil ? Metrics.buttonSize.width : actionButton.intrinsicContentSize.width + 18
        labelTrailing.constant = shareBackground.isHidden && actionBackground.isHidden
            ? -Metrics.trailingPadding
            : -(Metrics.textToButton + buttonWidth + Metrics.buttonTrailing)
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    if self.alphaValue == 0 { self.isHidden = true }
                }
            }
        }
    }

    @objc private func runAction() {
        action?()
    }

    @objc private func share() {
        if let undo {
            self.undo = nil
            return undo()
        }
        guard let shareURL else { return }
        NSSharingServicePicker(items: [shareURL]).show(relativeTo: shareBackground.bounds, of: shareBackground, preferredEdge: .minY)
    }
}
