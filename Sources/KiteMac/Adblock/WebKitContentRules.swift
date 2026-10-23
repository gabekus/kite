import CryptoKit
import Foundation
import WebKit

/// Ad blocking for the WebKit engine: adblock-rust converts the filter lists to
/// WebKit content-blocker rules, compiled once per list update into Kite's own
/// WKContentRuleListStore. Each page has its own content controller, so the
/// shield can turn the rules off for one site without touching other tabs.
@MainActor
final class WebKitContentRules {
    /// WebKit rejects a rule list with more than 150,000 rules.
    private nonisolated static let maxRulesPerList = 150_000

    private let store: WKContentRuleListStore?
    private unowned let adblocker: Adblocker
    private var lists: [WKContentRuleList] = []
    private var compiledKey: String?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var pageURLs: [ObjectIdentifier: URL] = [:]

    init(adblocker: Adblocker) {
        self.adblocker = adblocker
        let directory = adblocker.directory.appendingPathComponent("WebKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
        adblocker.onEngineChange.append { [weak self] in self?.compile() }
        adblocker.onPolicyChange.append { [weak self] in self?.applyToAll() }
    }

    /// A fresh controller for a new page, with the rules applied as of now.
    func makeController() -> WKUserContentController {
        let controller = WKUserContentController()
        controllers.add(controller)
        return controller
    }

    /// Call before each main-frame navigation; rule changes apply to the next load.
    func apply(to controller: WKUserContentController, url: URL?) {
        pageURLs[ObjectIdentifier(controller)] = url
        controller.removeAllContentRuleLists()
        guard adblocker.blocks(url) else { return }
        lists.forEach(controller.add)
    }

    private func applyToAll() {
        for controller in controllers.allObjects {
            apply(to: controller, url: pageURLs[ObjectIdentifier(controller)])
        }
    }

    private func compile() {
        #if canImport(KiteAdblock)
        guard let store else { return }
        let adblocker = adblocker
        Task {
            let (texts, key) = await Task.detached(priority: .utility) {
                let texts = adblocker.readLists()
                var hash = SHA256()
                texts.forEach { hash.update(data: $0.text) }
                return (texts, "kite-adblock-" + hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined())
            }.value
            guard key != compiledKey else { return }
            compiledKey = key

            let identifiers = await store.availableIdentifiers() ?? []
            var compiled: [WKContentRuleList] = []
            if let cached = try? await lookUp(identifiers.filter { $0.hasPrefix(key + "-") }.sorted(), in: store), !cached.isEmpty {
                compiled = cached
            } else {
                // Converting and compiling ~140k rules takes seconds; keep it off the main thread.
                let chunks: [String] = await Task.detached(priority: .utility) {
                    guard let rules = AdblockEngine.contentBlockingRules(lists: texts),
                          let array = try? JSONSerialization.jsonObject(with: Data(rules.json.utf8)) as? [Any] else { return [] }
                    return stride(from: 0, to: array.count, by: Self.maxRulesPerList).compactMap { start in
                        let slice = Array(array[start..<min(start + Self.maxRulesPerList, array.count)])
                        return (try? JSONSerialization.data(withJSONObject: slice)).map { String(decoding: $0, as: UTF8.self) }
                    }
                }.value
                for (i, chunk) in chunks.enumerated() {
                    do {
                        if let list = try await store.compileContentRuleList(forIdentifier: "\(key)-\(i)", encodedContentRuleList: chunk) {
                            compiled.append(list)
                        }
                    } catch {
                        NSLog("Kite: WebKit rejected ad-block rules: \(error)")
                    }
                }
            }
            guard compiledKey == key else { return }
            lists = compiled
            applyToAll()
            for identifier in identifiers where !identifier.hasPrefix(key + "-") {
                try? await store.removeContentRuleList(forIdentifier: identifier)
            }
        }
        #endif
    }

    private func lookUp(_ identifiers: [String], in store: WKContentRuleListStore) async throws -> [WKContentRuleList] {
        var found: [WKContentRuleList] = []
        for identifier in identifiers {
            if let list = try await store.contentRuleList(forIdentifier: identifier) { found.append(list) }
        }
        return found
    }
}
