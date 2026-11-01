import Foundation
import Testing
@testable import KiteCore

@Suite struct ArcImportTests {
    private static func id(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }

    private static func tab(_ n: Int, parent: Int, title: String? = nil) -> [String: Any] {
        [
            "id": id(n), "parentID": id(parent), "title": title as Any, "childrenIds": [],
            "data": ["tab": ["savedURL": "https://site\(n).example/", "savedTitle": "Site \(n)", "timeLastActiveAt": 1.0]],
        ]
    }

    private static func node(_ n: Int, kind: [String: Any], title: String? = nil, children: [Int]) -> [String: Any] {
        ["id": id(n), "title": title as Any, "childrenIds": children.map(id), "data": kind]
    }

    /// Mirrors the shape of a real StorableSidebar.json.
    static let fixture: Data = {
        let personal: [String: Any] = [
            "id": id(1), "title": "Personal",
            "customInfo": ["iconType": ["emoji_v2": "🏃", "emoji": 127939]],
            "profile": ["default": true],
            "containerIDs": ["pinned", id(10), "unpinned", id(11)],
        ]
        let work: [String: Any] = [
            "id": id(2), "title": "Work",
            "customInfo": ["windowTheme": ["background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": [
                "baseColors": [
                    ["red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1, "colorSpace": "extendedSRGB"],
                    ["red": 0.0, "green": 0.25, "blue": 1.2, "alpha": 1, "colorSpace": "extendedSRGB"],
                ],
                "modifiers": ["noiseFactor": 0.2, "overlay": "grain"],
            ]]]]]]]], "intensityFactor": 0.8, "translucencyStyle": ["light": [:]]]],
            "profile": ["custom": ["_0": ["directoryBasename": "Profile 3", "machineID": "m"]]],
            "containerIDs": ["pinned", id(20), "unpinned", id(21)],
        ]
        let items: [[String: Any]] = [
            node(10, kind: ["itemContainer": ["containerType": ["spaceItems": ["_0": id(1)]]]], children: [100, 101, 104]),
            tab(100, parent: 10, title: "Renamed"),
            node(101, kind: ["list": [:]], title: "Folder", children: [102, 103]),
            tab(102, parent: 101),
            node(103, kind: ["list": [:]], title: "Nested", children: [105]),
            tab(105, parent: 103),
            node(104, kind: ["splitView": ["layoutOrientation": "horizontal"]], children: [106, 107]),
            tab(106, parent: 104),
            tab(107, parent: 104),
            node(11, kind: ["itemContainer": ["containerType": ["spaceItems": ["_0": id(1)]]]], children: [110, 111]),
            tab(110, parent: 11),
            node(111, kind: ["easel": [:]], children: []),
            node(30, kind: ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]], children: [300]),
            tab(300, parent: 30),
            node(20, kind: ["itemContainer": ["containerType": ["spaceItems": ["_0": id(2)]]]], children: []),
            node(21, kind: ["itemContainer": ["containerType": ["spaceItems": ["_0": id(2)]]]], children: [210]),
            tab(210, parent: 21),
        ]
        var flatItems: [Any] = []
        for item in items { flatItems += [item["id"]!, item] }
        let root: [String: Any] = [
            "version": 1,
            "sidebar": ["containers": [
                ["global": [:]],
                [
                    "spaces": [id(1), personal, id(2), work],
                    "items": flatItems,
                    "topAppsContainerIDs": [["default": true], id(30), ["custom": ["_0": ["directoryBasename": "Profile 3"]]], id(31)],
                ],
                ["littleBrowser": [:]],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }()

    @Test func importsSpacesFoldersFavoritesAndThemes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try ArcImport.parse(Self.fixture, now: now)
        #expect(result.spaces.map(\.name) == ["Personal", "Work"])

        let personal = result.spaces[0]
        #expect(personal.id == UUID(uuidString: Self.id(1)))
        #expect(personal.icon == "🏃")
        #expect(personal.tabs.map { $0.url?.host() } == ["site110.example"])
        #expect(personal.selectedTabID == personal.tabs.first?.id)

        // Renamed tab, nested folder, split view kept together.
        guard personal.pinnedItems.count == 3,
              case .tab(let renamed) = personal.pinnedItems[0],
              case .folder(let folder) = personal.pinnedItems[1],
              case .folder(let split) = personal.pinnedItems[2]
        else {
            Issue.record("unexpected pinned items: \(personal.pinnedItems)")
            return
        }
        #expect(result.favorites.map(\.title) == ["Site 300"])
        #expect(renamed.customTitle == "Renamed")
        #expect(renamed.displayTitle == "Renamed")
        #expect(folder.name == "Folder")
        #expect(folder.items.tabs.map(\.title) == ["Site 102", "Site 105"])
        guard case .folder(let nested) = folder.items[1] else {
            Issue.record("nested folder lost")
            return
        }
        #expect(nested.name == "Nested")
        #expect(split.items.tabs.map(\.title) == ["Site 106", "Site 107"])

        let work = result.spaces[1]
        #expect(work.pinnedItems.isEmpty)
        #expect(work.theme.colors == [ThemeColor(r: 1, g: 0.5, b: 0), ThemeColor(r: 0, g: 0.25, b: 1)])
        #expect(abs(work.theme.grain - 0.2) < 0.001)
        #expect(abs(work.theme.tint - Theme.defaultTint * 0.8) < 0.001)

        // Imported tabs count as fresh so auto-archive doesn't sweep them.
        #expect((result.spaces.flatMap(\.allTabs) + result.favorites).allSatisfy { $0.lastActiveAt == now })
        #expect(result.tabCount == 8)
        #expect(result.folderCount == 3)
        #expect(result.notes.contains { $0.contains("split view") })
        #expect(result.notes.contains { $0.contains("2 Arc profiles") })
        #expect(result.notes.contains { $0.contains("easel") })
    }

    @Test func idsAreUniqueAcrossTheImport() throws {
        let result = try ArcImport.parse(Self.fixture)
        let ids = (result.spaces.flatMap(\.allTabs) + result.favorites).map(\.id) + result.spaces.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func reimportReplacesSameSpaces() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let first = try ArcImport.parse(Self.fixture)
        #expect(state.merge(imported: first.spaces, favorites: first.favorites) == (added: 2, updated: 0))
        let second = try ArcImport.parse(Self.fixture)
        #expect(state.merge(imported: second.spaces, favorites: second.favorites) == (added: 0, updated: 2))
        #expect(state.spaces.count == 4)
        #expect(state.favorites.count == 1)
        #expect(state.selectedSpace.name == "Personal")
    }

    @Test func flagsUntitledSpaces() throws {
        let untitled: [String: Any] = ["id": Self.id(5), "containerIDs": ["unpinned", Self.id(50)]]
        let items: [[String: Any]] = [
            Self.node(50, kind: ["itemContainer": [:]], children: [500]),
            Self.tab(500, parent: 50),
        ]
        let root: [String: Any] = ["sidebar": ["containers": [[
            "spaces": [Self.id(5), untitled],
            "items": items.flatMap { [$0["id"]!, $0] },
        ]]]]
        let result = try ArcImport.parse(JSONSerialization.data(withJSONObject: root))
        #expect(result.spaces.map(\.name) == ["Arc Space"])
        #expect(result.untitledSpaceIDs == [result.spaces[0].id])
        #expect(try ArcImport.parse(Self.fixture).untitledSpaceIDs.isEmpty)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ArcImport.Failure.notArcSidebar) { try ArcImport.parse(Data("{}".utf8)) }
        let empty = try! JSONSerialization.data(withJSONObject: ["sidebar": ["containers": []]])
        #expect(throws: ArcImport.Failure.noSpaces) { try ArcImport.parse(empty) }
    }

    /// Runs against a real Arc file when KITE_ARC_SIDEBAR points at one. Prints counts only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KITE_ARC_SIDEBAR"] != nil))
    func importsRealArcFile() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KITE_ARC_SIDEBAR"]!)
        let result = try ArcImport.parse(Data(contentsOf: url))
        print("Arc import: \(result.spaces.count) spaces, \(result.favorites.count) favorites, \(result.tabCount) tabs, \(result.folderCount) folders")
        for space in result.spaces {
            print("  \(space.icon) \(space.name): \(space.pinned.count) pinned, \(space.tabs.count) unpinned, \(space.theme.colors.count) theme colors")
        }
        result.notes.forEach { print("  note: \($0)") }
        #expect(!result.spaces.isEmpty)
    }
}
