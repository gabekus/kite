#if canImport(KiteAdblock)
import Foundation
import KiteAdblock
import KiteCore

/// Brave's adblock-rust engine (Sources/KiteAdblock). Immutable once built, so it
/// can be read from any thread: Chromium checks requests on its network thread
/// while the main thread asks for a page's cosmetic filters.
final class AdblockEngine: NSObject, @unchecked Sendable {
    let pointer: OpaquePointer

    private init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ka_engine_free(pointer)
    }

    /// Takes about 50 ms for the default lists; call it off the main thread.
    static func build(lists: [(text: Data, trusted: Bool)]) -> AdblockEngine? {
        withLists(lists) { ka_engine_new($0, $1) }.map(AdblockEngine.init)
    }

    /// Nil when the cache came from another adblock-rust version or is damaged.
    static func deserialize(_ data: Data) -> AdblockEngine? {
        data.withUnsafeBytes { ka_engine_deserialize($0.baseAddress, $0.count) }.map(AdblockEngine.init)
    }

    func serialize() -> Data? {
        var length = 0
        guard let bytes = ka_engine_serialize(pointer, &length) else { return nil }
        defer { ka_bytes_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    /// Scriptlets and redirect bodies; set once, before the engine is shared.
    func useResources(_ json: Data) -> Bool {
        json.withUnsafeBytes { ka_engine_use_resources(pointer, $0.baseAddress, $0.count) }
    }

    func cosmeticResources(for url: URL) -> CosmeticResources? {
        guard let json = Self.take(ka_engine_url_cosmetic_resources(pointer, url.absoluteString)) else { return nil }
        return try? JSONDecoder().decode(CosmeticResources.self, from: Data(json.utf8))
    }

    func hiddenSelectors(classes: [String], ids: [String], exceptions: [String]) -> [String] {
        func encode(_ strings: [String]) -> String {
            String(decoding: (try? JSONEncoder().encode(strings)) ?? Data("[]".utf8), as: UTF8.self)
        }
        let json = Self.take(ka_engine_hidden_class_id_selectors(pointer, encode(classes), encode(ids), encode(exceptions)))
        return json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    /// WebKit content-blocker rules for the lists, and how many there are.
    static func contentBlockingRules(lists: [(text: Data, trusted: Bool)]) -> (json: String, count: Int)? {
        var count = 0
        let json = withLists(lists) { take(ka_content_blocking_json($0, $1, &count)) } ?? nil
        return json.map { ($0, count) }
    }

    /// uBlock Origin's redirect resources (`$redirect=noopjs` and the like) as adblock-rust JSON.
    static func redirectResources(directory: URL, index: URL) -> Data? {
        take(ka_assemble_redirect_resources(directory.path, index.path)).map { Data($0.utf8) }
    }

    private static func withLists<T>(_ lists: [(text: Data, trusted: Bool)], _ body: (UnsafePointer<KAList>, Int) -> T?) -> T? {
        // Data's bytes are only valid inside withUnsafeBytes, so nest one call per list.
        func nest(_ index: Int, _ built: [KAList]) -> T? {
            guard index < lists.count else { return built.withUnsafeBufferPointer { body($0.baseAddress!, $0.count) } }
            return lists[index].text.withUnsafeBytes { bytes in
                let list = KAList(text: bytes.bindMemory(to: UInt8.self).baseAddress, len: bytes.count, trusted: lists[index].trusted)
                return nest(index + 1, built + [list])
            }
        }
        return nest(0, [])
    }

    private static func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
        guard let string else { return nil }
        defer { ka_string_free(string) }
        return String(cString: string)
    }
}
#endif
