import AppKit
import KiteCore
import UniformTypeIdentifiers

/// Pictures chosen as space icons (Kite only: Arc's picker has just Emoji and Icon). Each one is scaled
/// down to a square PNG in the profile's SpaceIcons folder, and the space's icon is `image:` and its name,
/// so state.json stays small and a space never points outside that folder.
@MainActor
enum SpaceIconImages {
    /// Stored at 128 px: the largest place a space icon shows is 28 pt, so this stays sharp on Retina.
    static let pixelSize = 128

    static var directory: URL { AppDelegate.supportDirectory.appendingPathComponent("SpaceIcons", isDirectory: true) }

    private static let cache = NSCache<NSString, NSImage>()

    /// The picture behind an `image:` icon, or nil when the file is missing or the name isn't a bare file name.
    static func image(for icon: String) -> NSImage? {
        guard icon.hasPrefix(Space.imagePrefix) else { return nil }
        let name = String(icon.dropFirst(Space.imagePrefix.count))
        guard Space.isValidIconImageName(name) else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// The file types the picker takes: anything NSImage reads (PNG, JPEG, HEIC, GIF, TIFF, WebP, PDF, SVG…).
    static var readableTypes: [UTType] { NSImage.imageTypes.compactMap { UTType($0) } }

    /// Saves `image` as a new icon and returns the `image:` icon string for it, or nil if it can't be drawn.
    /// The picture is centre-cropped to a square, like an avatar, so it fills the icon's slot.
    static func store(_ image: NSImage) -> String? {
        guard let png = squarePNG(image) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("Kite: couldn't save a space icon: \(error.localizedDescription)")
            return nil
        }
        return Space.imagePrefix + name
    }

    static func store(contentsOf url: URL) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return store(image)
    }

    /// An image on the pasteboard, as a file or as image data (copied from Preview or a web page).
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let image = urls.lazy.compactMap(NSImage.init(contentsOf:)).first {
            return image
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first
    }

    static func squarePNG(_ image: NSImage) -> Data? {
        // Measure in pixels: an NSImage's point size can disagree with its pixel size (72 vs 144 dpi).
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        var source = CGSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
        if source.width <= 0 || source.height <= 0 { source = image.size } // PDF and SVG have no pixels
        guard source.width > 0, source.height > 0 else { return nil }
        let side = min(source.width, source.height)
        // The centred square of the picture, in the image's point space for draw(in:from:).
        let scale = image.size.width / source.width
        let crop = NSRect(x: (source.width - side) / 2 * scale, y: (source.height - side) / 2 * scale,
                          width: side * scale, height: side * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        out.size = NSSize(width: pixelSize, height: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize), from: crop, operation: .copy, fraction: 1)
        context.flushGraphics()
        return out.representation(using: .png, properties: [:])
    }
}
