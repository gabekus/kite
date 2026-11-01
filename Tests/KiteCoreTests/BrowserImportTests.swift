import Foundation
import Testing
@testable import KiteCore

/// Hand-made fixtures shaped like Chromium's Bookmarks JSON and Safari's Bookmarks.plist.
@Suite struct BrowserImportTests {
    private static func url(_ name: String, _ url: String) -> [String: Any] {
        ["type": "url", "name": name, "url": url, "date_added": "13300000000000000", "guid": UUID().uuidString, "id": "1"]
    }

    private static func folder(_ name: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "name": name, "children": children, "date_added": "13300000000000000", "id": "2"]
    }

    private static func chromiumFile(bar: [[String: Any]], other: [[String: Any]] = [], synced: [[String: Any]] = []) -> Data {
        let root: [String: Any] = [
            "checksum": "x", "version": 1,
            "roots": [
                "bookmark_bar": folder("Bookmarks bar", bar),
                "other": folder("Other bookmarks", other),
                "synced": folder("Mobile bookmarks", synced),
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private static func names(_ items: [PinnedItem]) -> [String] {
        items.map {
            switch $0 {
            case .tab(let tab): tab.title
            case .folder(let folder): "[\(folder.name)]"
            }
        }
    }

    @Test func chromiumBarAtTopLevelOtherRootsAsFolders() throws {
        let data = Self.chromiumFile(
            bar: [Self.url("One", "https://one.example/"), Self.folder("Work", [Self.url("Two", "https://two.example/")])],
            other: [Self.url("Three", "https://three.example/")]
        )
        let result = try BookmarkImport.chromium([data])
        #expect(Self.names(result.items) == ["One", "[Work]", "[Other bookmarks]"])
        #expect(result.bookmarkCount == 3)
        #expect(result.folderCount == 2)
        guard case .tab(let one) = result.items[0] else { Issue.record("not a tab"); return }
        #expect(one.url == URL(string: "https://one.example/"))
        #expect(one.pinnedURL == one.url)
    }

    @Test func chromiumSkipsBookmarkletsAndEmptyFolders() throws {
        let data = Self.chromiumFile(bar: [
            Self.url("Bookmarklet", "javascript:alert(1)"),
            Self.url("Settings", "chrome://settings"),
            Self.folder("Empty", []),
            Self.folder("Only bookmarklets", [Self.url("B", "javascript:void(0)")]),
            Self.url("Page", "https://page.example/"),
        ])
        let result = try BookmarkImport.chromium([data])
        #expect(Self.names(result.items) == ["Page"])
        #expect(result.skipped == 3)
        #expect(result.folderCount == 0)
    }

    @Test func chromiumAccountAndLocalFilesAddUpWithoutDuplicates() throws {
        let local = Self.chromiumFile(bar: [Self.url("Shared", "https://shared.example/"), Self.url("Local", "https://local.example/")])
        let account = Self.chromiumFile(bar: [Self.url("Shared", "https://shared.example/"), Self.url("Account", "https://account.example/")])
        let result = try BookmarkImport.chromium([local, account])
        #expect(Self.names(result.items) == ["Shared", "Local", "Account"])
        #expect(result.bookmarkCount == 3)
    }

    @Test func chromiumRejectsOtherFiles() {
        #expect(throws: BookmarkImport.Failure.unreadable) { try BookmarkImport.chromium([Data("nope".utf8)]) }
    }

    private static func leaf(_ title: String, _ url: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title], "WebBookmarkUUID": UUID().uuidString]
    }

    private static func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children, "WebBookmarkUUID": UUID().uuidString]
    }

    @Test func safariFavoritesAtTopLevelReadingListLeftOut() throws {
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "", "WebBookmarkFileVersion": 1,
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                Self.list("BookmarksBar", [Self.leaf("Fav", "https://fav.example/"), Self.list("Recipes", [Self.leaf("Soup", "https://soup.example/")])]),
                Self.list("BookmarksMenu", [Self.leaf("Menu", "https://menu.example/")]),
                Self.list("com.apple.ReadingList", [Self.leaf("Later", "https://later.example/")]),
                Self.list("Travel", [Self.leaf("Map", "https://map.example/")]),
                Self.list("Hidden", [Self.leaf("H", "https://h.example/")]).merging(["ShouldOmitFromUI": true]) { $1 },
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let result = try BookmarkImport.safari(data)
        #expect(Self.names(result.items) == ["Fav", "[Recipes]", "[Bookmarks Menu]", "[Travel]"])
        #expect(result.bookmarkCount == 4)
        #expect(result.folderCount == 3)
    }

    @Test func safariRejectsOtherFiles() {
        #expect(throws: BookmarkImport.Failure.unreadable) { try BookmarkImport.safari(Data("nope".utf8)) }
    }

    @Test func reimportReplacesTheBrowsersSpace() throws {
        var state = BrowserState.makeDefault()
        let first = try BookmarkImport.chromium([Self.chromiumFile(bar: [Self.url("Old", "https://old.example/")])])
        state.merge(imported: [BookmarkImport.space(for: .chrome, first, theme: .arcDefault, icon: "🌿")])
        let second = try BookmarkImport.chromium([Self.chromiumFile(bar: [Self.url("New", "https://new.example/")])])
        state.merge(imported: [BookmarkImport.space(for: .chrome, second, theme: .arcDefault, icon: "🌿")])
        let spaces = state.spaces.filter { $0.id == ImportBrowser.chrome.spaceID }
        #expect(spaces.count == 1)
        #expect(spaces[0].name == "Chrome")
        #expect(spaces[0].pinned.map(\.title) == ["New"])
        #expect(state.selectedSpaceID == ImportBrowser.chrome.spaceID)
    }

    @Test func eachBrowserHasItsOwnSpace() {
        #expect(Set(ImportBrowser.allCases.map(\.spaceID)).count == ImportBrowser.allCases.count)
    }

    @Test func safariDates() {
        #expect(History.safariDate(0) == Date(timeIntervalSince1970: 978_307_200))
    }
}
