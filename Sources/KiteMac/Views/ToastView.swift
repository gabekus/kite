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
        static let padding: CGFloat = 13
        static let buttonSize: CGFloat = 31
        static let topColor = NSColor(srgbRed: 0x55 / 255, green: 0x67 / 255, blue: 0x92 / 255, alpha: 1)
        static let bottomColor = NSColor(srgbRed: 0x49 / 255, green: 0x58 / 255, blue: 0x7D / 255, alpha: 1)
        static let buttonColor = NSColor(srgbRed: 0x74 / 255, green: 0x80 / 255, blue: 0x9C / 255, alpha: 1)
        static let duration: Duration = .seconds(4.6)
    }

    private let gradient = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")
    private let shareButton = NSButton()
    private var labelTrailing: NSLayoutConstraint!
    private var shareURL: URL?
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

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white

        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareButton.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        shareButton.contentTintColor = .white
        shareButton.isBordered = false
        shareButton.wantsLayer = true
        shareButton.layer?.backgroundColor = Metrics.buttonColor.cgColor
        shareButton.layer?.cornerRadius = 6
        shareButton.layer?.cornerCurve = .continuous
        shareButton.target = self
        shareButton.action = #selector(share)

        for view in [label, shareButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        labelTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            shareButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            shareButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),
            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Metrics.height - Metrics.buttonSize) / 2),
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
        return hit === shareButton ? hit : nil
    }

    /// Shows `message`; with `shareURL`, Arc's share button sits on the right.
    func show(_ message: String, shareURL: URL? = nil, for duration: Duration = Metrics.duration) {
        label.stringValue = message
        self.shareURL = shareURL
        shareButton.isHidden = shareURL == nil
        labelTrailing.constant = shareURL == nil ? -Metrics.padding : -(Metrics.padding + Metrics.buttonSize + (Metrics.height - Metrics.buttonSize) / 2)
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

    @objc private func share() {
        guard let shareURL else { return }
        NSSharingServicePicker(items: [shareURL]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }
}
