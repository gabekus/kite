import Foundation
import KiteCore

extension Notification.Name {
    /// The zap library changed; pages refresh their document-start script and live CSS.
    static let kiteZapsChanged = Notification.Name("KiteZapsChanged")
}

/// The profile's zaps (zaps.json): Arc's Zap, kept per site until Boosts hold them.
@MainActor
final class ZapsModel {
    static let shared = ZapsModel()

    private(set) var library: ZapLibrary
    /// The document-start script for the current library.
    private(set) var documentStartScript: String
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? AppDelegate.supportDirectory.appendingPathComponent("zaps.json")
        self.fileURL = fileURL
        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(ZapLibrary.self, from: $0) }
        let library = saved ?? ZapLibrary()
        self.library = library
        documentStartScript = ZapScript.documentStart(library)
    }

    func selectors(for domain: String) -> [String] { library.selectors(for: domain) }

    func add(_ selector: String, for domain: String) {
        guard library.add(selector, for: domain) else { return }
        changed()
    }

    /// Arc's removeZap.
    func remove(_ selector: String, for domain: String) {
        guard library.remove(selector, for: domain) else { return }
        changed()
    }

    private func changed() {
        documentStartScript = ZapScript.documentStart(library)
        save()
        NotificationCenter.default.post(name: .kiteZapsChanged, object: self)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(library) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Brings a live page's zap CSS up to date (all of its site's zaps, minus `except`, which
    /// the picker shows while its cell is hovered).
    func applyLive(to page: WebPage, except: String? = nil) {
        page.evaluateJavaScript(ZapScript.hostScript) { [weak self, weak page] host in
            guard let self, let page, let domain = ZapLibrary.domain(ofHost: host as? String) else { return }
            let css = ZapLibrary.css(self.library.selectors(for: domain).filter { $0 != except })
            page.evaluateJavaScript(ZapScript.apply(css: css)) { _ in }
        }
    }
}
