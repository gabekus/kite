import AppKit
import KiteCore
import ScreenCaptureKit

/// `ui capture`: a window's pixels exactly as they reach the screen (blur, vibrancy, Metal and
/// web content included), even when the window is covered or Kite is in the background. Colours come back in
/// sRGB, so hex values compare across captures and apps.
///
/// ScreenCaptureKit needs Screen Recording permission (on macOS 15 so does the window server's image of Kite's own
/// window). Without it, Kite draws the window itself: the views, the Metal theme and the pages from Chromium, with
/// blurred materials unblurred. The output names the path that ran.
@MainActor
enum UICapture {
    /// Full-window images sent to Claude are scaled to this width at most; crops and saved files stay full size.
    static let maxImageWidth = 1280

    static func run(window: NSWindow, region: UIRect?, format: ImageFormat, pixels: [UIPoint], image wantsImage: Bool,
                    save: String?, source: CaptureSource = .auto) async throws -> ToolOutput {
        let (captured, path, notes) = try await capture(window, source: source)
        let scale = Double(captured.width) / Double(window.frame.width)
        var lines = ["Window \(window.windowNumber) captured at \(UIReport.number(scale))× "
            + "(\(captured.width)×\(captured.height) px), sRGB, by \(path)."]
        lines += notes
        if !window.occlusionState.contains(.visible) && !UIDiagnostics.enabledByEnvironment {
            lines.append("The window is covered, so Chromium may have stopped painting the page: a blank card here isn't Kite's "
                + "drawing. Read web content with the page screenshot tool. (KITE_DIAGNOSTICS=1 test builds keep pages painting.)")
        }

        if !pixels.isEmpty {
            let bitmap = NSBitmapImageRep(cgImage: captured)
            lines.append("Pixels (point → sRGB, pixel at the point's top-left):")
            for point in pixels {
                let x = Int((point.x * scale).rounded(.down)), y = Int((point.y * scale).rounded(.down))
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    lines.append("  (\(UIReport.number(point.x)), \(UIReport.number(point.y))): outside the window")
                    continue
                }
                lines.append("  (\(UIReport.number(point.x)), \(UIReport.number(point.y))): \(UIFormat.hex(color.cgColor) ?? "?")")
            }
        }

        var cropped = captured
        if let region {
            let rect = CGRect(x: region.x * scale, y: region.y * scale, width: region.width * scale, height: region.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: captured.width, height: captured.height))
            guard !rect.isEmpty, let crop = captured.cropping(to: rect) else {
                throw AutomationError(.invalidArguments, "\"region\" is outside the window.")
            }
            cropped = crop
            lines.append("Region [\(region.description)] is \(crop.width)×\(crop.height) px.")
        }
        if let save {
            let url = URL(fileURLWithPath: (save as NSString).expandingTildeInPath)
            guard let data = encode(cropped, format: .png) else { throw AutomationError(.failed, "Couldn't encode the capture.") }
            try data.write(to: url)
            lines.append("Saved full resolution PNG to \(url.path).")
        }
        var content: [ToolOutput.Content] = [.text(lines.joined(separator: "\n"))]
        if wantsImage {
            var sent = cropped
            if region == nil, cropped.width > maxImageWidth, let smaller = resize(cropped, width: maxImageWidth) {
                sent = smaller
                content[0] = .text(lines.joined(separator: "\n") + "\nImage scaled to \(maxImageWidth) px wide; use region for full-resolution crops.")
            }
            guard let data = encode(sent, format: format) else { throw AutomationError(.failed, "Couldn't encode the capture.") }
            content.append(.image(base64: data.base64EncodedString(), mimeType: format.mimeType))
        }
        return ToolOutput(content: content)
    }

    /// The image, the path that made it, and notes on what that path misses.
    private static func capture(_ window: NSWindow, source: CaptureSource) async throws -> (CGImage, String, [String]) {
        switch source {
        case .screen:
            // Asking would put a system prompt on the screen.
            guard CGPreflightScreenCaptureAccess() else {
                throw AutomationError(.failed, "Screen Recording isn't granted to the app that launched Kite; "
                    + "capture with source in-process (kite ui capture --in-process) instead.")
            }
            return (try await screenCapture(window), "ScreenCaptureKit", [])
        case .inProcess:
            return try await inProcess(window, notes: [])
        case .auto:
            var notes: [String] = []
            // Only with Screen Recording already granted, for the same reason.
            if CGPreflightScreenCaptureAccess() {
                do { return (try await screenCapture(window), "ScreenCaptureKit", []) } catch {
                    notes.append("ScreenCaptureKit failed (\(error.localizedDescription)).")
                }
            }
            return try await inProcess(window, notes: notes)
        }
    }

    /// The composed render for a browser window, else (Little Kite, a web app) a plain view render.
    private static func inProcess(_ window: NSWindow, notes: [String]) async throws -> (CGImage, String, [String]) {
        if let (image, composeNotes) = await composedRender(window) {
            let note = "Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); "
                + "the theme, the views and the pages are as on screen." + materialNote(window)
            return (image, "an in-process render", notes + [note] + composeNotes)
        }
        guard let image = viewRender(window) else { throw AutomationError(.failed, "Couldn't draw the window's views.") }
        return (image, "a view render", notes + ["This is a view render: no blur, vibrancy, Metal or web content."])
    }

    private static func screenCapture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw AutomationError(.notFound, "ScreenCaptureKit doesn't list window \(window.windowNumber) (minimized?).")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// A browser window drawn in Kite, back to front: the backdrop (the material's unblurred fallback, the Metal theme
    /// drawn again off screen), the views over it, then each page from Chromium's own frame in its card, with the views
    /// above that page (overlays in the card, the command bar, the Library) drawn over it again. Nil for windows that
    /// aren't browser windows; its notes say which pages didn't answer.
    private static func composedRender(_ window: NSWindow) async -> (CGImage, [String])? {
        guard let controller = window.windowController as? BrowserWindowController,
              let root = window.contentView?.superview ?? window.contentView else { return nil }
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A titled window's rounded corners stay clear, as in a capture of it; a full-screen window's are square.
        if !window.styleMask.contains(.fullScreen),
           let mask = roundedMask(CGRect(x: 0, y: 0, width: width, height: height), radius: windowCornerRadius * scale,
                                  curve: .continuous, width: width, height: height) {
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
        }
        context.scaleBy(x: scale, y: scale)
        /// `rect` in the root view's coordinates, as a rect in the context (bottom-left origin).
        func place(_ rect: CGRect) -> CGRect {
            root.isFlipped ? CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        func draw(_ view: NSView) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let image = bitmap.cgImage { context.draw(image, in: place(view.convert(view.bounds, to: root))) }
        }

        controller.drawCaptureBackdrop(view: draw) { image, view in context.draw(image, in: place(view.convert(view.bounds, to: root))) }
        controller.withCaptureBackdropHidden { draw(root) }

        var notes: [String] = []
        for page in controller.capturePages {
            let data: Data?
            do {
                data = try await withTimeout(3, "the page's frame") { done in page.captureImage(area: page.view.bounds) { done(.success($0)) } }
            } catch {
                notes.append("A page didn't give its frame within 3 s, so its card is drawn without it.")
                continue
            }
            guard page.view.window === window, let data, let image = NSBitmapImageRep(data: data)?.cgImage else { continue }
            context.saveGState()
            // The card's rounded corners: the nearest ancestor that clips with a corner radius, in its own corner curve.
            var clip: NSView? = page.view
            while let view = clip, !(view.layer?.masksToBounds == true && (view.layer?.cornerRadius ?? 0) > 0) { clip = view.superview }
            if let clip, let layer = clip.layer {
                let rect = place(clip.convert(clip.bounds, to: root))
                let device = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                if let mask = roundedMask(device, radius: layer.cornerRadius * scale, curve: layer.cornerCurve, width: width, height: height) {
                    context.clip(to: CGRect(origin: .zero, size: size), mask: mask)
                }
            }
            context.draw(image, in: place(page.view.convert(page.view.bounds, to: root)))
            context.restoreGState()
            // What's above the page on screen: its later siblings at every level up to the window.
            var child: NSView = page.view
            while let parent = child.superview {
                if let index = parent.subviews.firstIndex(of: child) {
                    for view in parent.subviews[(index + 1)...] where !view.isHidden && view.alphaValue > 0 { draw(view) }
                }
                if parent === root { break }
                child = parent
            }
        }
        return context.makeImage().map { ($0, notes) }
    }

    /// The frames of the materials an in-process render can't blur, so a diff can treat them as material-only.
    private static func materialNote(_ window: NSWindow) -> String {
        guard let root = window.contentView?.superview ?? window.contentView else { return "" }
        var frames: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if view is NSVisualEffectView {
                let r = view.convert(view.bounds, to: root)
                let y = root.isFlipped ? r.minY : root.bounds.height - r.maxY
                frames.append("[\(UIReport.number(r.minX)),\(UIReport.number(y)) \(UIReport.number(r.width))×\(UIReport.number(r.height))]")
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return frames.isEmpty ? "" : "\nMaterial (unblurred) at: " + frames.joined(separator: ", ") + "."
    }

    /// A titled window's corner radius on macOS 15 (measured against ScreenCaptureKit's captures: continuous corners).
    private static let windowCornerRadius: CGFloat = 10

    /// A `width`×`height` pixel mask, white inside `rect` (pixels, bottom-left origin) with rounded corners, black outside.
    private static func roundedMask(_ rect: CGRect, radius: CGFloat, curve: CALayerCornerCurve, width: Int, height: Int) -> CGImage? {
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let shape = CALayer()
        shape.frame = rect
        shape.backgroundColor = CGColor(gray: 1, alpha: 1)
        shape.cornerRadius = radius
        shape.cornerCurve = curve
        context.translateBy(x: rect.minX, y: rect.minY)
        shape.render(in: context)
        return context.makeImage()
    }

    private static func viewRender(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }

    static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return bitmap.representation(using: .png, properties: [:])
        case .jpeg: return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
    }

    private static func resize(_ image: CGImage, width: Int) -> CGImage? {
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
