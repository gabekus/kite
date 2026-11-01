import AppKit
import KiteCore

/// Arc's File › Capture in Portrait Mode (docs/arc-visual-spec.md, "Capture in Portrait Mode"):
/// the visible page on a backdrop (a colour from the slider, the website's colour or the desktop
/// wallpaper) with a watermark, chosen in a popover with a live preview, then copied with a
/// "Screenshot Copied to Clipboard" toast that offers Save, like Capture Full Page.
extension BrowserWindowController {
    @objc func capturePortraitMode(_ sender: Any?) {
        guard let page = shownPage, page.view.window != nil else { return NSSound.beep() }
        cancelCapture()
        capturePopover?.close()
        let bounds = page.view.bounds
        let title = store.state.selectedTab?.title ?? ""
        let sourceURL = store.state.selectedTab?.url
        page.captureImage(area: CGRect(origin: .zero, size: bounds.size)) { [weak self, weak page] data in
            guard let self, let page, let data, let snapshot = NSImage(data: data),
                  let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSSound.beep() }
            let wallpaper = Self.desktopWallpaper(for: self.window?.screen)
            let source = PortraitSource(image: cgImage, pointSize: bounds.size,
                                        websiteColor: PortraitRenderer.websiteColor(of: cgImage), wallpaper: wallpaper)
            self.showPortraitPopover(source: source, title: title, sourceURL: sourceURL, over: page.view)
        }
    }

    private func showPortraitPopover(source: PortraitSource, title: String, sourceURL: URL?, over view: NSView) {
        guard view.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PortraitCaptureController(source: source, settings: .load()) { [weak self, weak popover] settings in
            popover?.close()
            self?.takePortrait(source: source, settings: settings, title: title, sourceURL: sourceURL)
        }
        capturePopover = popover
        // From the top of the page, where Arc's content toolbar keeps its capture button.
        let anchor = view.isFlipped
            ? NSRect(x: view.bounds.midX - 1, y: 0, width: 2, height: 1)
            : NSRect(x: view.bounds.midX - 1, y: view.bounds.height - 1, width: 2, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    private func takePortrait(source: PortraitSource, settings: PortraitSettings, title: String, sourceURL: URL?) {
        guard let image = PortraitRenderer.render(source, settings: settings, scale: source.pixelScale),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return showToast("Failed to Save")
        }
        let name = PortraitCapture.filename(date: Date())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try png.write(to: file, options: .atomic) } catch { return showToast("Failed to Save") }
        let pasteboard = Self.capturePasteboard
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(file.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
        SoundEffectPlayer.shared.play(.capture)
        MediaLibraryModel.shared.storeCapture(png: png, sourceURL: sourceURL, title: title)
        showToast("Screenshot Copied to Clipboard", action: ("Save", { [weak self] in
            guard let self, let window = self.window else { return }
            let panel = NSSavePanel()
            panel.title = "Save Capture Image"
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: file, to: url)
                } catch {
                    self?.showToast("Failed to Save")
                }
            }
        }))
    }

    /// The window's screen's desktop picture, when macOS gives one Kite can read (a dynamic
    /// wallpaper's first frame; nil for a folder or a colour).
    private static func desktopWallpaper(for screen: NSScreen?) -> NSImage? {
        guard let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              !url.hasDirectoryPath else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// The page snapshot Portrait Mode works from.
struct PortraitSource {
    let image: CGImage
    /// The page's size in points; the image is at device resolution.
    let pointSize: CGSize
    let websiteColor: NSColor?
    let wallpaper: NSImage?

    var pixelScale: CGFloat { pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 2 }
}

/// Arc's three settings, kept under Arc's user-default names.
struct PortraitSettings: Equatable {
    var background: PortraitCapture.Background
    var colorPercentage: Double
    var showsWatermark: Bool

    static func load(_ defaults: UserDefaults = .standard) -> PortraitSettings {
        let stored = defaults.object(forKey: PortraitCapture.backgroundKey) as? Bool
        return PortraitSettings(
            background: PortraitCapture.background(stored: stored),
            colorPercentage: defaults.double(forKey: PortraitCapture.colorPercentageKey),
            showsWatermark: !defaults.bool(forKey: PortraitCapture.hidesWatermarkKey))
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let stored = PortraitCapture.stored(background) {
            defaults.set(stored, forKey: PortraitCapture.backgroundKey)
        } else {
            defaults.removeObject(forKey: PortraitCapture.backgroundKey)
        }
        defaults.set(colorPercentage, forKey: PortraitCapture.colorPercentageKey)
        defaults.set(!showsWatermark, forKey: PortraitCapture.hidesWatermarkKey)
    }
}

/// Draws the finished picture: backdrop, page with rounded corners, shadow and a light edge,
/// and the watermark in the bottom margin.
enum PortraitRenderer {
    static func paletteColor(_ rgb: PortraitCapture.RGB) -> NSColor {
        let r = CGFloat(rgb.red), g = CGFloat(rgb.green), b = CGFloat(rgb.blue)
        switch rgb.space {
        case .sRGB: return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case .displayP3: return NSColor(displayP3Red: r, green: g, blue: b, alpha: 1)
        case .extendedLinearSRGB:
            let space = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!
            return NSColor(colorSpace: space, components: [r, g, b, 1], count: 4)
        }
    }

    /// The slider's colour at `percentage`: the two palette stops it falls between, blended.
    static func sliderColor(at percentage: Double) -> NSColor {
        let stop = PortraitCapture.paletteStop(at: percentage)
        let from = paletteColor(PortraitCapture.palette[stop.from])
        let to = paletteColor(PortraitCapture.palette[stop.to])
        return from.blended(withFraction: CGFloat(stop.fraction), of: to) ?? from
    }

    static func color(for settings: PortraitSettings, website: NSColor?) -> NSColor {
        switch settings.background {
        case .color: sliderColor(at: settings.colorPercentage)
        case .website: website ?? sliderColor(at: PortraitCapture.websiteFallbackPercentage)
        case .wallpaper: .black
        }
    }

    /// Arc turns the colour's hue by ±30° for the backdrop's two gradients.
    static func hueShifted(_ color: NSColor, degrees: Double) -> NSColor {
        guard let rgb = color.usingColorSpace(.extendedSRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var hue = (h + CGFloat(degrees / 360)).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return NSColor(colorSpace: .extendedSRGB, hue: hue, saturation: s, brightness: b, alpha: a)
    }

    /// The page's own colour: the average of its top rows (where a site's header and theme
    /// colour sit). Arc reads a tint the web content reports; Kite measures the snapshot.
    static func websiteColor(of image: CGImage) -> NSColor? {
        let rows = max(1, min(image.height, image.height / 40))
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = data.assumingMemoryBound(to: UInt8.self)
        guard pixel[3] > 0 else { return nil }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    static func render(_ source: PortraitSource, settings: PortraitSettings, scale: CGFloat) -> CGImage? {
        let layout = PortraitCapture.layout(pageWidth: Double(source.pointSize.width), pageHeight: Double(source.pointSize.height))
        let width = Int((CGFloat(layout.width) * scale).rounded()), height = Int((CGFloat(layout.height) * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Points from the top-left corner, as the layout is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let canvas = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawBackdrop(in: canvas, settings: settings, source: source)

        let page = CGRect(x: layout.page.x, y: layout.page.y, width: layout.page.width, height: layout.page.height)
        let radius = CGFloat(layout.cornerRadius)
        let path = CGPath(roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Shadow: Arc's preview uses black at 15%.
        context.saveGState()
        context.setShadow(offset: .zero, blur: CGFloat(layout.shadowRadius) * scale,
                          color: NSColor.black.withAlphaComponent(0.15).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        // The page, its corners rounded. CG draws images bottom-up, so flip around the page.
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.translateBy(x: 0, y: page.maxY + page.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(source.image, in: page)
        context.restoreGState()
        // A light edge: Arc strokes its preview in white at 40%.
        context.saveGState()
        context.addPath(CGPath(roundedRect: page.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5,
                               transform: nil))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        if settings.showsWatermark {
            drawWatermark(height: CGFloat(layout.watermarkHeight), in: canvas, below: page)
        }
        return context.makeImage()
    }

    private static func drawBackdrop(in canvas: CGRect, settings: PortraitSettings, source: PortraitSource) {
        if settings.background == .wallpaper, let wallpaper = source.wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
            // Aspect fill, centred.
            let fill = max(canvas.width / wallpaper.size.width, canvas.height / wallpaper.size.height)
            let size = CGSize(width: wallpaper.size.width * fill, height: wallpaper.size.height * fill)
            let rect = CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2, width: size.width, height: size.height)
            wallpaper.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let base = color(for: settings, website: source.websiteColor)
        base.setFill()
        canvas.fill()
        guard settings.background != .wallpaper else { return }
        // The colour turned +30° from the top-left corner and −30° from the bottom-right, each
        // fading out (Arc's backdrop: the colour with two hue-shifted gradients).
        let warm = hueShifted(base, degrees: PortraitCapture.hueShiftDegrees)
        let cool = hueShifted(base, degrees: -PortraitCapture.hueShiftDegrees)
        NSGradient(colors: [warm, warm.withAlphaComponent(0)])?.draw(in: canvas, angle: 45)
        NSGradient(colors: [cool.withAlphaComponent(0), cool])?.draw(in: canvas, angle: 45)
    }

    /// Kite's own mark (Arc draws its "ArcCaptureWatermark" image here).
    private static func drawWatermark(height: CGFloat, in canvas: CGRect, below page: CGRect) {
        guard height > 0 else { return }
        let font = NSFont.systemFont(ofSize: height, weight: .bold).rounded
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = height * 0.2
        let text = NSAttributedString(string: "Kite", attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.9), .shadow: shadow,
        ])
        let size = text.size()
        let margin = canvas.maxY - page.maxY
        text.draw(at: CGPoint(x: canvas.midX - size.width / 2, y: page.maxY + (margin - size.height) / 2))
    }
}

private extension NSFont {
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
