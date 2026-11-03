import AppKit
import KiteCore
import ScreenCaptureKit

/// `ui capture`: a window's pixels exactly as they reach the screen (blur, vibrancy, Metal and
/// web content included), even when the window is covered or Kite is in the background. Colours come back in
/// sRGB, so hex values compare across captures and apps.
///
/// ScreenCaptureKit needs Screen Recording permission. Without it, the window server still gives Kite its own
/// window's pixels (an app may always capture its own windows); failing that, the views are drawn into a bitmap,
/// which misses blur, Metal and web content. The output names the path that ran.
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
        let viewNote = "This is a view render: no blur, vibrancy, Metal or web content."
        let composedNote = "Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); "
            + "the theme, the views and the pages are as on screen." + materialNote(window)
        switch source {
        case .screen:
            return (try await screenCapture(window), "ScreenCaptureKit", [])
        case .windowServer:
            guard let image = windowServerCapture(window) else {
                throw AutomationError(.failed, "The window server didn't give window \(window.windowNumber)'s pixels.")
            }
            return (image, "the window server", [])
        case .inProcess:
            if let image = await composedRender(window) { return (image, "an in-process render", [composedNote]) }
            guard let image = viewRender(window) else { throw AutomationError(.failed, "Couldn't draw the window's views.") }
            return (image, "a view render", [viewNote])
        case .auto:
            var notes: [String] = []
            // Only with Screen Recording already granted: asking would put a system prompt on the screen.
            if CGPreflightScreenCaptureAccess() {
                do { return (try await screenCapture(window), "ScreenCaptureKit", []) } catch {
                    notes.append("ScreenCaptureKit failed (\(error.localizedDescription)).")
                }
            }
            if let image = windowServerCapture(window) { return (image, "the window server", notes) }
            if let image = await composedRender(window) { return (image, "an in-process render", notes + [composedNote]) }
            guard let image = viewRender(window) else { throw AutomationError(.failed, "No capture path worked.") }
            return (image, "a view render", notes + [viewNote])
        }
    }

    /// Kite's own window from the window server, composited as on screen. An app may capture its own windows without
    /// Screen Recording permission. `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK but still in
    /// CoreGraphics, so it's looked up at run time.
    private static func windowServerCapture(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3  // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 3)  // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        guard let image = create(.null, includingWindow, CGWindowID(window.windowNumber), options)?.takeRetainedValue(),
              image.width > 1, image.height > 1 else { return nil }
        // In sRGB, as ScreenCaptureKit's captures are.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
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

    /// A browser window drawn in Kite, back to front: the material (its unblurred fallback), the Metal theme rendered
    /// again off screen, the views with those two hidden, then each visible page from Chromium's own frame, clipped
    /// to its card's rounded corners. Nil for windows that aren't browser windows.
    private static func composedRender(_ window: NSWindow) async -> CGImage? {
        guard let controller = window.windowController as? BrowserWindowController,
              let root = window.contentView?.superview ?? window.contentView else { return nil }
        let (material, theme, pages) = controller.inProcessCaptureParts
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The window's rounded corners stay clear, as in the window server's image of it.
        if let mask = windowCornerMask(width: width, height: height, scale: scale) {
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

        draw(material)
        if let image = theme.snapshot() { context.draw(image, in: place(theme.convert(theme.bounds, to: root))) }
        // The views over them, without them (a Metal layer draws nothing here, and the material would cover the theme).
        let wasHidden = (material.isHidden, theme.isHidden)
        material.isHidden = true
        theme.isHidden = true
        draw(root)
        material.isHidden = wasHidden.0
        theme.isHidden = wasHidden.1

        for page in pages where page.view.window === window && !page.view.isHiddenOrHasHiddenAncestor {
            let data: Data? = await withCheckedContinuation { done in
                page.captureImage(area: page.view.bounds) { done.resume(returning: $0) }
            }
            guard let data, let image = NSBitmapImageRep(data: data)?.cgImage else { continue }
            let frame = page.view.convert(page.view.bounds, to: root)
            context.saveGState()
            // The card's rounded corners: the nearest ancestor that clips with a corner radius.
            var clip: NSView? = page.view
            while let view = clip, !(view.layer?.masksToBounds == true && (view.layer?.cornerRadius ?? 0) > 0) { clip = view.superview }
            if let clip, let layer = clip.layer {
                let path = CGPath(roundedRect: place(clip.convert(clip.bounds, to: root)), cornerWidth: layer.cornerRadius,
                                  cornerHeight: layer.cornerRadius, transform: nil)
                context.addPath(path)
                context.clip()
            }
            context.draw(image, in: place(frame))
            context.restoreGState()
        }
        return context.makeImage()
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
    static let windowCornerRadius: CGFloat = 10

    /// White inside the window's continuous rounded rect, black outside, at `width`×`height` pixels.
    private static func windowCornerMask(width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let shape = CALayer()
        shape.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        shape.backgroundColor = CGColor(gray: 1, alpha: 1)
        shape.cornerRadius = windowCornerRadius * scale
        shape.cornerCurve = .continuous
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
