import Foundation

/// "Import from Another Browser…" (Arc's Arc menu): bookmarks and history from Safari and the
/// Chromium browsers Arc's import lists (Chrome, Brave, Edge, Vivaldi, Opera, Opera GX).
///
/// Bookmarks become pinned tabs in a space named after the browser, keeping their folders.
/// Importing again replaces that space. History goes into Kite's history (`History.merge`).
/// The shell reads the files (KiteMac/BrowserImportController.swift); this is the pure part.
public enum ImportBrowser: String, CaseIterable, Sendable {
    case safari, chrome, brave, edge, vivaldi, opera, operaGX

    public var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .operaGX: "Opera GX"
        }
    }

    public var isChromium: Bool { self != .safari }

    /// Where the browser keeps its default profile: under ~/Library/Application Support for
    /// the Chromium browsers, ~/Library for Safari. Opera keeps its profile at the top level.
    public var profilePath: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google/Chrome/Default"
        case .brave: "BraveSoftware/Brave-Browser/Default"
        case .edge: "Microsoft Edge/Default"
        case .vivaldi: "Vivaldi/Default"
        case .opera: "com.operasoftware.Opera"
        case .operaGX: "com.operasoftware.OperaGX"
        }
    }

    /// Bookmark files, in the order they're read. Chrome keeps the bookmarks of a signed-in
    /// account in AccountBookmarks and the rest in Bookmarks.
    public var bookmarkFiles: [String] {
        isChromium ? ["Bookmarks", "AccountBookmarks"] : ["Bookmarks.plist"]
    }

    public var historyFile: String { isChromium ? "History" : "History.db" }

    /// Arc's line for each browser names everything Arc takes from it; Kite's names only
    /// what Kite imports so far.
    public var importsDescription: String {
        "Kite can import your history and bookmarks from \(title)."
    }

    /// The space the bookmarks go into keeps the same ID, so importing again replaces it.
    public var spaceID: UUID {
        let n: Int = switch self {
        case .safari: 1
        case .chrome: 2
        case .brave: 3
        case .edge: 4
        case .vivaldi: 5
        case .opera: 6
        case .operaGX: 7
        }
        return UUID(uuidString: String(format: "4B495445-494D-5054-8000-%012d", n))!
    }
}

public enum BookmarkImport {
    public struct Result: Sendable, Equatable {
        public var items: [PinnedItem]
        public var bookmarkCount: Int
        public var folderCount: Int
        /// Bookmarks Kite can't open as a pinned tab (bookmarklets, browser-internal pages).
        public var skipped: Int

        public init(items: [PinnedItem] = [], bookmarkCount: Int = 0, folderCount: Int = 0, skipped: Int = 0) {
            self.items = items
            self.bookmarkCount = bookmarkCount
            self.folderCount = folderCount
            self.skipped = skipped
        }

        public var isEmpty: Bool { items.isEmpty }
    }

    public enum Failure: Error, Equatable {
        case unreadable
    }

    /// A Chromium `Bookmarks` file. The bookmarks bar's contents go at the top level; the other
    /// roots ("Other bookmarks", "Mobile bookmarks") become folders when they have anything in them.
    /// Several files (Bookmarks and AccountBookmarks) add up; a bookmark in both is kept once.
    public static func chromium(_ files: [Data], now: Date = Date()) throws -> Result {
        var builder = Builder(now: now)
        var parsedAny = false
        var top: [PinnedItem] = []
        var rest: [String: [PinnedItem]] = [:]
        var restOrder: [String] = []
        for data in files {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = root["roots"] as? [String: Any]
            else { continue }
            parsedAny = true
            if let bar = roots["bookmark_bar"] as? [String: Any] {
                top += builder.chromiumChildren(bar)
            }
            for key in ["other", "synced"] {
                guard let node = roots[key] as? [String: Any] else { continue }
                let children = builder.chromiumChildren(node)
                guard !children.isEmpty else { continue }
                let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (key == "other" ? "Other bookmarks" : "Mobile bookmarks")
                if rest[name] == nil { restOrder.append(name) }
                rest[name, default: []] += children
            }
        }
        guard parsedAny else { throw Failure.unreadable }
        var items = top
        for name in restOrder { items.append(builder.folder(name, rest[name]!)) }
        return builder.result(items)
    }

    /// Safari's `Bookmarks.plist`. The Favorites bar's contents go at the top level, the
    /// Bookmarks Menu and other top-level folders become folders. The Reading List and the
    /// History proxy aren't bookmarks and are left out.
    public static func safari(_ data: Data, now: Date = Date()) throws -> Result {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = root["Children"] as? [[String: Any]]
        else { throw Failure.unreadable }
        var builder = Builder(now: now)
        var items: [PinnedItem] = []
        for child in children where child["WebBookmarkType"] as? String == "WebBookmarkTypeList" {
            let title = child["Title"] as? String ?? ""
            switch title {
            case "com.apple.ReadingList":
                continue
            case "BookmarksBar":
                items += builder.safariChildren(child)
            case "BookmarksMenu":
                let contents = builder.safariChildren(child)
                if !contents.isEmpty { items.append(builder.folder("Bookmarks Menu", contents)) }
            default:
                items += builder.safariNode(child)
            }
        }
        // Leaves directly under the root (rare) keep their place.
        for child in children where child["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
            items += builder.safariNode(child)
        }
        return builder.result(items)
    }

    /// Whether a bookmark can become a pinned tab: a web or file page, not a bookmarklet or a
    /// browser's own page (chrome://, edge://).
    public static func importable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// The space the bookmarks go into, named after the browser.
    public static func space(for browser: ImportBrowser, _ result: Result, theme: Theme, icon: String) -> Space {
        Space(id: browser.spaceID, name: browser.title, icon: icon, theme: theme, pinnedItems: result.items)
    }

    private struct Builder {
        let now: Date
        var bookmarkCount = 0
        var folderCount = 0
        var skipped = 0
        /// Folder path + URL, so a bookmark in both Chrome files is kept once.
        var seen: Set<String> = []
        var path: [String] = []

        init(now: Date) {
            self.now = now
        }

        mutating func tab(_ urlString: String?, title: String?) -> PinnedItem? {
            guard let urlString, let url = URL(string: urlString), Self.isUsable(url) else {
                skipped += 1
                return nil
            }
            let key = (path + [url.absoluteString]).joined(separator: "\u{1F}")
            guard seen.insert(key).inserted else { return nil }
            bookmarkCount += 1
            let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .tab(BrowserTab(url: url, title: name, lastActiveAt: now, pinnedURL: url))
        }

        private static func isUsable(_ url: URL) -> Bool { BookmarkImport.importable(url) }

        mutating func folder(_ name: String, _ items: [PinnedItem]) -> PinnedItem {
            folderCount += 1
            return .folder(TabFolder(name: name, isExpanded: false, items: items))
        }

        mutating func chromiumChildren(_ node: [String: Any]) -> [PinnedItem] {
            (node["children"] as? [[String: Any]] ?? []).flatMap { chromiumNode($0) }
        }

        mutating func chromiumNode(_ node: [String: Any]) -> [PinnedItem] {
            switch node["type"] as? String {
            case "url":
                return tab(node["url"] as? String, title: node["name"] as? String).map { [$0] } ?? []
            case "folder":
                let name = node["name"] as? String ?? ""
                path.append(name)
                let contents = chromiumChildren(node)
                path.removeLast()
                return contents.isEmpty ? [] : [folder(name.isEmpty ? "Untitled" : name, contents)]
            default:
                return []
            }
        }

        mutating func safariChildren(_ node: [String: Any]) -> [PinnedItem] {
            (node["Children"] as? [[String: Any]] ?? []).flatMap { safariNode($0) }
        }

        mutating func safariNode(_ node: [String: Any]) -> [PinnedItem] {
            if node["ShouldOmitFromUI"] as? Bool == true { return [] }
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                return tab(node["URLString"] as? String, title: title).map { [$0] } ?? []
            case "WebBookmarkTypeList":
                let name = node["Title"] as? String ?? ""
                path.append(name)
                let contents = safariChildren(node)
                path.removeLast()
                return contents.isEmpty ? [] : [folder(name.isEmpty ? "Untitled" : name, contents)]
            default:
                return []
            }
        }

        func result(_ items: [PinnedItem]) -> Result {
            Result(items: items, bookmarkCount: bookmarkCount, folderCount: folderCount, skipped: skipped)
        }
    }
}

extension History {
    /// Safari's history timestamps: seconds since 2001-01-01 UTC.
    public static func safariDate(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
