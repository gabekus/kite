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
        case .siteSettings: symbol = "gearshape"
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
