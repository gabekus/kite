import AppKit
import KiteCore
import SwiftUI

/// Arc's site permission prompt (its `PermissionRequests` module; docs/arc-visual-spec.md, "Site
/// permission prompt"): the permission's icon, "Allow <site> to access your camera?" with the site
/// set apart, "Not Now" and "Allow", and "Click the lock 🔒 to change this any time". Fonts, sizes
/// and the card's width weren't read from Arc's binary; they're Kite's.
struct PermissionPromptView: View {
    let site: String
    let permissions: [SitePermission]
    let answer: (Bool) -> Void

    enum Metrics {
        static let width: CGFloat = 300
        static let iconSize: CGFloat = 28
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: PermissionPrompt.symbol(for: permissions))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                    .background(Circle().fill(Color.accentColor))
                    .accessibilityHidden(true)
                title
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(PermissionPrompt.denyTitle) { answer(false) }
                Button(PermissionPrompt.allowTitle) { answer(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            (Text(PermissionPrompt.footerBeforeLock) + Text(Image(systemName: PermissionPrompt.footerSymbol))
                + Text(PermissionPrompt.footerAfterLock))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: Metrics.width, alignment: .leading)
    }

    private var title: Text {
        let parts = PermissionPrompt.title(site: site, permissions: permissions)
        let before = String(parts.text[..<parts.siteRange.lowerBound])
        let after = String(parts.text[parts.siteRange.upperBound...])
        return Text(before) + Text(site).fontWeight(.semibold) + Text(after)
    }
}

/// The card Arc puts its prompt in (from Little Arc's code, the one placement read from the binary):
/// corner radius 12, content inset 4, a black shadow at 0.2 with radius 5. It pops in from its
/// leading edge: scale 0.8 → 1 about its left middle and opacity 0 → 1, 0.1 s ease in-out.
@MainActor
final class PermissionPromptCard: NSView {
    static let cornerRadius: CGFloat = 12
    static let inset: CGFloat = 4
    /// From the page's top-leading corner (Arc: a constant plus 8 on each axis; the constant wasn't read).
    static let margin: CGFloat = 8
    static let appearDuration: CFTimeInterval = 0.1

    let requestID: Int
    private let effect = NSVisualEffectView()
    private let host: NSHostingView<PermissionPromptView>

    init(request: PermissionRequest, answer: @escaping (Bool) -> Void) {
        requestID = request.id
        host = NSHostingView(rootView: PermissionPromptView(
            site: PermissionPrompt.siteName(for: request.origin), permissions: request.permissions, answer: answer
        ))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 5
        layer?.shadowOffset = .zero
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        addSubview(effect)
        effect.addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Permission Prompt")
        let size = host.fittingSize
        setFrameSize(NSSize(width: size.width + 2 * Self.inset, height: size.height + 2 * Self.inset))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        host.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    /// Puts the card at the top-leading corner of `area` (in `container`'s coordinates).
    func place(in area: NSRect, of container: NSView) {
        let y = container.isFlipped ? area.minY + Self.margin : area.maxY - Self.margin - frame.height
        setFrameOrigin(NSPoint(x: area.minX + Self.margin, y: y))
        autoresizingMask = container.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
    }

    func animateIn() {
        guard let layer else { return }
        let middle = bounds.height / 2
        var from = CGAffineTransform(translationX: 0, y: middle).scaledBy(x: 0.8, y: 0.8)
        from = from.translatedBy(x: 0, y: -middle)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(from))
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for animation in [scale, fade] {
            animation.duration = Self.appearDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: animation.keyPath)
        }
    }
}
