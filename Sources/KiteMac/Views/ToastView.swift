import AppKit

/// A short confirmation pill ("Copied URL") at the bottom of the window, like Arc's.
/// One per window; showing a new message replaces the current one and restarts the timer.
@MainActor
final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        alphaValue = 0
        isHidden = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Purely informational; clicks go to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String, for duration: Duration = .seconds(1.6)) {
        label.stringValue = message
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
}
