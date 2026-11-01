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

/// Firefox's places.sqlite rows, Chromium's Local State and Firefox's profiles.ini, hand-made.
@Suite struct BrowserImportProfileTests {
    private static func names(_ items: [PinnedItem]) -> [String] {
        items.map {
            switch $0 {
            case .tab(let tab): tab.title
            case .folder(let folder): "[\(folder.name)]"
            }
        }
    }

    private static func row(_ id: Int64, _ parent: Int64, _ type: Int, _ position: Int, _ title: String?, guid: String = "", url: String? = nil) -> BookmarkImport.FirefoxRow {
        BookmarkImport.FirefoxRow(id: id, parent: parent, type: type, position: position, title: title, guid: guid.isEmpty ? "g\(id)" : guid, url: url)
    }

    @Test func firefoxToolbarAtTopLevelOtherRootsAsFolders() {
        let rows = [
            Self.row(1, 0, 2, 0, "", guid: "root________"),
            Self.row(2, 1, 2, 0, "menu", guid: "menu________"),
            Self.row(3, 1, 2, 1, "toolbar", guid: "toolbar_____"),
            Self.row(4, 1, 2, 2, "tags", guid: "tags________"),
            Self.row(5, 1, 2, 3, "unfiled", guid: "unfiled_____"),
            Self.row(6, 1, 2, 4, "mobile", guid: "mobile______"),
            Self.row(10, 3, 1, 1, "Second", url: "https://two.example/"),
            Self.row(11, 3, 1, 0, "First", url: "https://one.example/"),
            Self.row(12, 3, 3, 2, nil),
            Self.row(13, 3, 2, 3, "Work"),
            Self.row(14, 13, 1, 0, "Inner", url: "https://inner.example/"),
            Self.row(15, 2, 1, 0, "Menu page", url: "https://menu.example/"),
            Self.row(16, 4, 2, 0, "a-tag"),
            Self.row(17, 16, 1, 0, nil, url: "https://tagged.example/"),
            Self.row(18, 5, 1, 0, "Bookmarklet", url: "javascript:void(0)"),
            Self.row(19, 13, 2, 1, "Empty"),
        ]
        let result = BookmarkImport.firefox(rows)
        #expect(Self.names(result.items) == ["First", "Second", "[Work]", "[Bookmarks Menu]"])
        #expect(result.bookmarkCount == 4)
        #expect(result.folderCount == 2)
        #expect(result.skipped == 1)
        guard case .folder(let work) = result.items[2] else { Issue.record("not a folder"); return }
        #expect(Self.names(work.items) == ["Inner"])
    }

    @Test func chromiumLocalStateProfilesInChromesOrder() {
        let state: [String: Any] = ["profile": [
            "info_cache": ["Profile 2": ["name": "Work"], "Default": ["name": "Person 1"], "Profile 1": ["name": ""]],
            "profiles_order": ["Profile 2", "Default"],
        ]]
        let data = try! JSONSerialization.data(withJSONObject: state)
        #expect(ImportProfiles.chromium(localState: data) == [
            ImportProfile(directory: "Profile 2", name: "Work"),
            ImportProfile(directory: "Default", name: "Person 1"),
            ImportProfile(directory: "Profile 1", name: "Profile 1"),
        ])
        #expect(ImportProfiles.chromium(localState: Data("{}".utf8)).isEmpty)
    }

    @Test func firefoxProfilesIni() {
        let ini = """
            [Install4F96D1932A9F858E]
            Default=Profiles/b2c3.default-release
            Locked=1

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/a1b2.default
            Default=1

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/b2c3.default-release

            [Profile2]
            Name=Elsewhere
            IsRelative=0
            Path=/Volumes/Data/ff

            [General]
            StartWithLastProfile=1
            Version=2
            """
        let parsed = ImportProfiles.firefox(ini: ini)
        #expect(parsed.profiles.map(\.name) == ["default", "default-release", "Elsewhere"])
        #expect(parsed.profiles[2].isAbsolute)
        #expect(parsed.defaultDirectory == "Profiles/b2c3.default-release")
        let noInstall = ImportProfiles.firefox(ini: "[Profile0]\nName=only\nIsRelative=1\nPath=Profiles/x\nDefault=1\n")
        #expect(noInstall.defaultDirectory == "Profiles/x")
    }

    @Test func eachProfileHasItsOwnSpaceAndDefaultKeepsTheBrowsers() {
        let main = ImportProfile(directory: "Default", name: "Person 1")
        let work = ImportProfile(directory: "Profile 1", name: "Work")
        #expect(ImportBrowser.chrome.spaceID(for: main) == ImportBrowser.chrome.spaceID)
        #expect(ImportBrowser.chrome.spaceID(for: work) != ImportBrowser.chrome.spaceID)
        #expect(ImportBrowser.chrome.spaceID(for: work) == ImportBrowser.chrome.spaceID(for: work))
        #expect(ImportBrowser.chrome.spaceID(for: work) != ImportBrowser.brave.spaceID(for: work))
        let ff = ImportProfile(directory: "Profiles/a.default", name: "default")
        #expect(ImportBrowser.firefox.spaceID(for: ff) != ImportBrowser.firefox.spaceID)
        #expect(BookmarkImport.spaceName(.chrome, profile: work, namedAfterProfile: true) == "Chrome (Work)")
        #expect(BookmarkImport.spaceName(.chrome, profile: work, namedAfterProfile: false) == "Chrome")
        #expect(ImportBrowser.chrome.profilePath == "Google/Chrome/Default")
        #expect(ImportBrowser.opera.profilePath == "com.operasoftware.Opera")
    }

    @Test func firefoxDates() {
        #expect(History.firefoxDate(1_700_000_000_000_000) == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
