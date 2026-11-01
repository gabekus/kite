import Foundation

/// "Import from Another Browser…" (Arc's Arc menu): bookmarks and history from Safari, Firefox
/// and the Chromium browsers Arc's import lists (Chrome, Brave, Edge, Vivaldi, Opera, Opera GX).
///
/// Bookmarks become pinned tabs in a space named after the browser, keeping their folders.
/// Importing again replaces that space. History goes into Kite's history (`History.merge`).
/// Chrome, Brave, Edge, Vivaldi and Firefox can have several profiles; the dialog asks which
/// one to import from. The shell reads the files (KiteMac/BrowserImportController.swift);
/// this is the pure part.
public enum ImportBrowser: String, CaseIterable, Sendable {
    case safari, chrome, brave, edge, vivaldi, opera, operaGX, firefox

    public var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .operaGX: "Opera GX"
        case .firefox: "Firefox"
        }
    }

    public var isChromium: Bool { self != .safari && self != .firefox }

    /// The browser's data folder: under ~/Library/Application Support, or ~/Library for Safari.
    /// Chromium browsers keep their profiles (Default, Profile 1, …) and `Local State` in it,
    /// Firefox its profiles and `profiles.ini`. Opera keeps its one profile at the top level.
    public var dataFolder: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google/Chrome"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .operaGX: "com.operasoftware.OperaGX"
        case .firefox: "Firefox"
        }
    }

    /// Whether the browser can have several profiles that the dialog lets you choose from.
    public var hasProfiles: Bool {
        switch self {
        case .chrome, .brave, .edge, .vivaldi, .firefox: true
        case .safari, .opera, .operaGX: false
        }
    }

    /// The profile read when there's no list of profiles: Chromium's `Default`, or the data
    /// folder itself (Safari, Opera). Firefox has no fixed one; its list is `profiles.ini`.
    public var defaultProfile: ImportProfile? {
        switch self {
        case .chrome, .brave, .edge, .vivaldi: ImportProfile(directory: "Default", name: "Default")
        case .safari, .opera, .operaGX: ImportProfile(directory: "", name: title)
        case .firefox: nil
        }
    }

    /// Where the default profile is, relative to Application Support (Library for Safari).
    public var profilePath: String {
        guard let directory = defaultProfile?.directory, !directory.isEmpty else { return dataFolder }
        return dataFolder + "/" + directory
    }

    /// Bookmark files, in the order they're read. Chrome keeps the bookmarks of a signed-in
    /// account in AccountBookmarks and the rest in Bookmarks. Firefox keeps bookmarks and
    /// history in the same database.
    public var bookmarkFiles: [String] {
        switch self {
        case .safari: ["Bookmarks.plist"]
        case .firefox: ["places.sqlite"]
        default: ["Bookmarks", "AccountBookmarks"]
        }
    }

    public var historyFile: String {
        switch self {
        case .safari: "History.db"
        case .firefox: "places.sqlite"
        default: "History"
        }
    }

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
        case .firefox: 8
        }
        return UUID(uuidString: String(format: "4B495445-494D-5054-8000-%012d", n))!
    }

    /// The space for one of the browser's profiles. The default profile (or the only one) keeps
    /// the browser's own space, so it's the same one an import before profiles made; each other
    /// profile has its own, so importing a second profile doesn't replace the first.
    public func spaceID(for profile: ImportProfile) -> UUID {
        if profile.directory == defaultProfile?.directory { return spaceID }
        // FNV-1a over the browser and the profile's folder: stable across launches.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (rawValue + "/" + profile.directory).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return UUID(uuidString: String(format: "4B495445-494D-5054-%04X-%012llX", UInt32(0x8000 | (hash >> 52)), hash & 0xFFFF_FFFF_FFFF))!
    }
}

/// One profile of the browser being imported from: its folder (relative to the browser's data
/// folder, or absolute for a Firefox profile kept elsewhere) and the name the browser shows.
public struct ImportProfile: Sendable, Equatable, Hashable {
    public var directory: String
    public var name: String

    public init(directory: String, name: String) {
        self.directory = directory
        self.name = name
    }

    public var isAbsolute: Bool { directory.hasPrefix("/") }
}

public enum ImportProfiles {
    /// A Chromium `Local State` file's profiles (`profile.info_cache`: folder → `name`), in the
    /// order of `profile.profiles_order` when it's there, then Default, then by folder.
    public static func chromium(localState data: Data) -> [ImportProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? []
        func rank(_ directory: String) -> (Int, Int, String) {
            if let i = order.firstIndex(of: directory) { return (0, i, "") }
            return (1, directory == "Default" ? 0 : 1, directory)
        }
        return cache.keys
            .sorted { rank($0) < rank($1) }
            .map { directory in
                let info = cache[directory] as? [String: Any]
                let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
                return ImportProfile(directory: directory, name: name)
            }
    }

    /// Firefox's `profiles.ini`: a `[ProfileN]` section per profile with `Name`, `Path` and
    /// `IsRelative`, in file order. The default is the one an `[Install…]` section names, else
    /// the profile marked `Default=1`.
    public static func firefox(ini text: String) -> (profiles: [ImportProfile], defaultDirectory: String?) {
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        var profiles: [ImportProfile] = []
        var marked: String?
        for section in sections where section.name.hasPrefix("Profile") {
            guard let path = section.values["Path"], !path.isEmpty else { continue }
            let relative = section.values["IsRelative"] != "0"
            let directory = relative ? path : (path.hasPrefix("/") ? path : "/" + path)
            let name = section.values["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? path
            profiles.append(ImportProfile(directory: directory, name: name))
            if section.values["Default"] == "1", marked == nil { marked = directory }
        }
        let install = sections.first { $0.name.hasPrefix("Install") }?.values["Default"]
        let defaultDirectory = [install, marked].compactMap { $0 }.first { d in profiles.contains { $0.directory == d } }
        return (profiles, defaultDirectory)
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

    /// The space for one profile's bookmarks: named after the browser, with the profile's name
    /// when the browser has more than one ("Chrome (Work)").
    public static func space(for browser: ImportBrowser, profile: ImportProfile, namedAfterProfile: Bool,
                             _ result: Result, theme: Theme, icon: String) -> Space {
        Space(id: browser.spaceID(for: profile), name: spaceName(browser, profile: profile, namedAfterProfile: namedAfterProfile),
              icon: icon, theme: theme, pinnedItems: result.items)
    }

    public static func spaceName(_ browser: ImportBrowser, profile: ImportProfile, namedAfterProfile: Bool) -> String {
        namedAfterProfile ? "\(browser.title) (\(profile.name))" : browser.title
    }

    /// One row of Firefox's `moz_bookmarks`, with its page's URL from `moz_places`.
    public struct FirefoxRow: Sendable, Equatable {
        public var id: Int64
        public var parent: Int64
        /// 1 bookmark, 2 folder, 3 separator.
        public var type: Int
        public var position: Int
        public var title: String?
        public var guid: String
        public var url: String?

        public init(id: Int64, parent: Int64, type: Int, position: Int, title: String?, guid: String, url: String?) {
            self.id = id
            self.parent = parent
            self.type = type
            self.position = position
            self.title = title
            self.guid = guid
            self.url = url
        }
    }

    /// Firefox's bookmarks (`places.sqlite`). Like Chromium's, the toolbar's contents go at the
    /// top level; the Bookmarks Menu, Other Bookmarks and Mobile Bookmarks roots become folders
    /// when they have anything in them. Tags and separators aren't bookmarks and are left out.
    public static func firefox(_ rows: [FirefoxRow], now: Date = Date()) -> Result {
        var children: [Int64: [FirefoxRow]] = [:]
        for row in rows { children[row.parent, default: []].append(row) }
        for key in children.keys { children[key]!.sort { $0.position < $1.position } }
        var builder = Builder(now: now)
        func root(_ guid: String) -> FirefoxRow? { rows.first { $0.guid == guid } }
        func contents(_ folder: FirefoxRow) -> [PinnedItem] {
            (children[folder.id] ?? []).flatMap { row -> [PinnedItem] in
                switch row.type {
                case 1:
                    return builder.tab(row.url, title: row.title).map { [$0] } ?? []
                case 2:
                    let name = row.title ?? ""
                    builder.path.append(name)
                    let inner = contents(row)
                    builder.path.removeLast()
                    return inner.isEmpty ? [] : [builder.folder(name.isEmpty ? "Untitled" : name, inner)]
                default:
                    return []
                }
            }
        }
        var items: [PinnedItem] = []
        if let toolbar = root("toolbar_____") { items += contents(toolbar) }
        for (guid, fallback) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            guard let node = root(guid) else { continue }
            builder.path.append(fallback)
            let inner = contents(node)
            builder.path.removeLast()
            if !inner.isEmpty { items.append(builder.folder(fallback, inner)) }
        }
        return builder.result(items)
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
    /// Firefox's history timestamps (`moz_historyvisits.visit_date`): microseconds since 1970.
    public static func firefoxDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    /// Safari's history timestamps: seconds since 2001-01-01 UTC.
    public static func safariDate(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
