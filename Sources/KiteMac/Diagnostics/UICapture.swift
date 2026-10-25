import AppKit
import KiteCore
import ScreenCaptureKit

/// `ui capture`: a window's pixels exactly as they reach the screen (blur, vibrancy, Metal and
/// web content included), via ScreenCaptureKit, even when the window is covered or Kite is in
/// the background. Colours come back in sRGB, so hex values compare across captures and apps.
///
/// Needs Screen Recording permission once. Without it, it falls back to drawing the views
/// into a bitmap, which misses blur and Metal and says so.
@MainActor
enum UICapture {
    /// Full-window images sent to Claude are scaled to this width at most; crops and saved files stay full size.
    static let maxImageWidth = 1280

    static func run(window: NSWindow, region: UIRect?, format: ImageFormat, pixels: [UIPoint], image wantsImage: Bool,
                    save: String?) async throws -> ToolOutput {
        var notes: [String] = []
        let captured: CGImage
        do {
            captured = try await screenCapture(window)
        } catch {
            guard let fallback = viewRender(window) else { throw error }
            captured = fallback
            notes.append("ScreenCaptureKit failed (\(error.localizedDescription)); this is a view render, without blur, "
                + "vibrancy or Metal. Grant Kite Screen Recording permission for exact pixels.")
        }
        let scale = Double(captured.width) / Double(window.frame.width)
        var lines = ["Window \(window.windowNumber) captured at \(UIReport.number(scale))× "
            + "(\(captured.width)×\(captured.height) px), sRGB."]
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
