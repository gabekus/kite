import AppKit
import KiteCore
import SwiftUI

/// In-memory favicon cache that merges duplicate requests for the same icon.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private let images = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    /// Icons that failed this run, so rows scrolling back into view don't refetch them.
    private var missing: Set<URL> = []

    private init() {
        images.countLimit = 500
    }

    func cached(_ url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if missing.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            images.setObject(image, forKey: url as NSURL)
        } else {
            missing.insert(url)
        }
        return image
    }
}

struct FaviconView: View {
    let url: URL?
    var size: CGFloat = 16
    @State private var image: NSImage?

    /// The page's reported icon, else the site's /favicon.ico, so tabs that
    /// haven't loaded yet (imported, hibernated) still get an icon.
    init(tab: BrowserTab, size: CGFloat = 16) {
        self.init(page: tab.url, icon: tab.faviconURL, size: size)
    }

    init(page: URL?, icon: URL? = nil, size: CGFloat = 16) {
        self.size = size
        switch InternalPage(page) {
        case .history: symbol = "clock.arrow.circlepath"
        case .archive: symbol = "archivebox"
        case .siteSettings, .settings: symbol = "gearshape"
        case .searchEngines: symbol = "magnifyingglass"
        case nil: break
        }
        if let icon {
            url = icon
        } else if let page, let scheme = page.scheme, ["http", "https"].contains(scheme), let host = page.host() {
            url = URL(string: "\(scheme)://\(host)/favicon.ico")
        } else {
            url = nil
        }
    }

    /// Kite's own pages show a symbol: a clock for History, like Chromium's history icon; a box for the Archive.
    private var symbol: String?

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).resizable().scaledToFit().opacity(0.8)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().opacity(0.6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.19, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = FaviconCache.shared.cached(url)
            if image == nil { image = await FaviconCache.shared.image(for: url) }
        }
    }
}

extension NSImage {
    /// The most common saturated hue in the icon, averaged; nil for a grey or empty icon.
    var dominantColor: NSColor? {
        let side = 16
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var bins: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5,
                      pixel.saturationComponent > 0.25, pixel.brightnessComponent > 0.15 else { continue }
                let bin = Int(pixel.hueComponent * 12) % 12
                let sum = bins[bin, default: (0, 0, 0, 0)]
                bins[bin] = (sum.count + 1, sum.r + pixel.redComponent, sum.g + pixel.greenComponent, sum.b + pixel.blueComponent)
            }
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = CGFloat(top.count)
        return NSColor(srgbRed: top.r / n, green: top.g / n, blue: top.b / n, alpha: 1)
    }
}
