import AppKit
import CoreImage

/// What a normal window shows in place of a tab whose page another window has taken: a blurred
/// snapshot of the page, stretched to fill the pane.
///
/// Arc: `WindowContentPlaceholderViewController` (with `Snapshot` and `BlurredSnapshotView`) draws
/// `Image(nsImage:).resizable()` (stretch) filling the frame and ignoring the safe area, and fades a new
/// snapshot in with `.easeInOut(0.2)`; `WebContentPlaceholderView` is a plain layer-backed colour
/// behind it. Arc shows no text or button there. The blur radius isn't in what was traced (see
/// docs/arc-visual-spec.md).
final class PagePlaceholderView: NSView {
    /// Unmeasured: Arc's blur radius wasn't recovered.
    static let blurRadius: Double = 20
    static let fadeDuration: Double = 0.2

    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.pageBackdrop.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.opacity = 0
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("PagePlaceholder")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// The page as it was (PNG data from `WebPage.captureImage`); nil leaves the plain background.
    func setSnapshot(_ data: Data?) {
        guard let data, let image = Self.blurred(data) else { return }
        imageLayer.contents = image
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.opacity = 1
        imageLayer.add(fade, forKey: "fade")
        setAccessibilityValue("snapshot")
    }

    private static let context = CIContext()

    private static func blurred(_ data: Data) -> CGImage? {
        guard let input = CIImage(data: data) else { return nil }
        let extent = input.extent
        // Clamp first so the edges blur into the page rather than into transparency.
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }
}
