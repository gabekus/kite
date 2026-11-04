import Foundation

/// windows.json: the browser windows beyond the main one, reopened at launch (BrowserWindows).
/// Read window by window, so one that doesn't decode (a blank window whose state is damaged) is
/// dropped alone instead of taking every other window with it.
public struct SavedWindows: Codable, Sendable {
    public struct Window: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case normal, blank }
        public var kind: Kind
        /// x, y, width, height in screen points.
        public var frame: [Double]
        /// A normal window's selection in the shared sidebar.
        public var selection: WindowSelection?
        /// A blank window's own tabs.
        public var state: BrowserState?

        public init(kind: Kind, frame: [Double], selection: WindowSelection? = nil, state: BrowserState? = nil) {
            self.kind = kind
            self.frame = frame
            self.selection = selection
            self.state = state
        }
    }

    public var version = 1
    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    /// How many windows were left out because they didn't decode.
    public private(set) var dropped = 0

    private enum CodingKeys: String, CodingKey { case version, windows }

    private struct Lenient: Decodable {
        let window: Window?
        init(from decoder: Decoder) throws { window = try? Window(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let all = try c.decode([Lenient].self, forKey: .windows)
        windows = all.compactMap(\.window)
        dropped = all.count - windows.count
    }

    /// The saved windows, or none when there's no file. A file that can't be read or decoded at
    /// all is moved aside (`windows.corrupt-….json`), and one with windows dropped is copied
    /// aside, both before the next save replaces it.
    public static func load(from url: URL) -> SavedWindows? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(SavedWindows.self, from: data) else {
            try? SessionStore.moveAside(url)
            return nil
        }
        if file.dropped > 0 {
            let copy = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            if !FileManager.default.fileExists(atPath: copy.path) { try? data.write(to: copy, options: .atomic) }
        }
        return file
    }
}
