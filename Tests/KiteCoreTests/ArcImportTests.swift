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
            node(104, kind: ["splitView": ["layoutOrientation": "horizontal", "itemWidthFactors": [id(106), 0.6]]], children: [106, 107]),
            tab(106, parent: 104),
            tab(107, parent: 104),
            node(11, kind: ["itemContainer": ["containerType": ["spaceItems": ["_0": id(1)]]]], children: [110, 112, 111]),
            tab(110, parent: 11),
            node(112, kind: ["splitView": ["layoutOrientation": "vertical"]], children: [113, 114, 115]),
            tab(113, parent: 112),
            tab(114, parent: 112),
            tab(115, parent: 112),
            node(111, kind: ["easel": [:]], children: []),
            node(30, kind: ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]], children: [300]),
            tab(300, parent: 30),
            node(31, kind: ["itemContainer": ["containerType": ["topApps": ["_0": ["custom": [:]]]]]], children: [310, 311]),
            tab(310, parent: 31),
            // Arc keeps one grid per profile, so the same site can be in two of them.
            ["id": id(311), "childrenIds": [], "data": ["tab": ["savedURL": "https://site300.example/", "savedTitle": "Site 300"]]],
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
        #expect(personal.tabs.map { $0.url?.host() } == ["site110.example", "site113.example", "site114.example", "site115.example"])
        #expect(personal.selectedTabID == personal.tabs.first?.id)

        // Renamed tab, nested folder, and a split view's tabs side by side.
        guard personal.pinnedItems.count == 4,
              case .tab(let renamed) = personal.pinnedItems[0],
              case .folder(let folder) = personal.pinnedItems[1],
              case .tab(let left) = personal.pinnedItems[2],
              case .tab(let right) = personal.pinnedItems[3]
        else {
            Issue.record("unexpected pinned items: \(personal.pinnedItems)")
            return
        }
        #expect(result.profiles == ["Default", "Profile 3"])
        #expect(result.favoritesByProfile["Default"]?.map(\.title) == ["Site 300"])
        #expect(result.favoritesByProfile["Profile 3"]?.map(\.title) == ["Site 310", "Site 300"])
        #expect(result.favorites.map(\.title) == ["Site 300", "Site 310", "Site 300"])
        #expect(personal.profile == nil)
        #expect(result.spaces[1].profile == "Profile 3")
        #expect(renamed.customTitle == "Renamed")
        #expect(renamed.displayTitle == "Renamed")
        #expect(folder.name == "Folder")
        #expect(folder.items.tabs.map(\.title) == ["Site 102", "Site 105"])
        guard case .folder(let nested) = folder.items[1] else {
            Issue.record("nested folder lost")
            return
        }
        #expect(nested.name == "Nested")
        #expect([left.title, right.title] == ["Site 106", "Site 107"])

        // Splits: the pinned one keeps Arc's widths, the unpinned one its orientation.
        #expect(personal.splits.count == 2)
        let pinnedSplit = personal.splits[0]
        #expect(pinnedSplit.id == UUID(uuidString: Self.id(104)))
        #expect(pinnedSplit.tabIDs == [left.id, right.id])
        #expect(pinnedSplit.orientation == .horizontal)
        #expect(zip(pinnedSplit.normalizedFactors, [0.6, 0.4]).allSatisfy { abs($0 - $1) < 0.0001 })
        let unpinnedSplit = personal.splits[1]
        #expect(unpinnedSplit.tabIDs == Array(personal.tabs[1...3].map(\.id)))
        #expect(unpinnedSplit.orientation == .vertical)
        #expect(unpinnedSplit.normalizedFactors.count == 3)
        // The splits survive Kite's own clean-up.
        var state = BrowserState.makeDefault(seedURL: nil)
        state.merge(imported: result.spaces)
        state.normalizeSplits()
        #expect(state.spaces.first { $0.id == personal.id }?.splits.count == 2)

        let work = result.spaces[1]
        #expect(work.pinnedItems.isEmpty)
        #expect(work.theme.colors == [ThemeColor(r: 1, g: 0.5, b: 0), ThemeColor(r: 0, g: 0.25, b: 1)])
        #expect(abs(work.theme.grain - 0.2) < 0.001)
        #expect(abs(work.theme.tint - Theme.defaultTint * 0.8) < 0.001)

        // Imported tabs count as fresh so auto-archive doesn't sweep them.
        #expect((result.spaces.flatMap(\.allTabs) + result.favorites).allSatisfy { $0.lastActiveAt == now })
        #expect(result.tabCount == 13)
        #expect(result.folderCount == 2)
        #expect(result.splitCount == 2)
        #expect(result.notes.contains { $0.contains("1 split view is stacked") })
        #expect(result.notes.contains { $0.contains("easel") })
    }

    @Test func fillsInMissingSplitWidths() {
        #expect(ArcImportTests.factors([0.6, nil]) == [0.6, 0.4])
        #expect(ArcImportTests.factors([0.5, nil, nil]) == [0.5, 0.25, 0.25])
        #expect(ArcImportTests.factors([0.3, 0.7]) == [0.3, 0.7])
        #expect(ArcImportTests.factors([nil, nil]) == nil)
        #expect(ArcImportTests.factors([1.2, nil]) == nil)
    }

    private static func factors(_ known: [Double?]) -> [Double]? {
        ArcImport.splitWidthFactors(known).map { $0.map { ($0 * 1000).rounded() / 1000 } }
    }

    @Test func idsAreUniqueAcrossTheImport() throws {
        let result = try ArcImport.parse(Self.fixture)
        let ids = (result.spaces.flatMap(\.allTabs) + result.favorites).map(\.id) + result.spaces.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func reimportReplacesSameSpaces() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let first = try ArcImport.parse(Self.fixture)
        let merged = state.mergeArc(first.spaces, favoritesByProfile: first.favoritesByProfile)
        #expect((merged.added, merged.updated) == (2, 0))
        let second = try ArcImport.parse(Self.fixture)
        let again = state.mergeArc(second.spaces, favoritesByProfile: second.favoritesByProfile)
        #expect((again.added, again.updated) == (0, 2))
        #expect(again.newProfiles.isEmpty)
        #expect(state.spaces.count == 4)
        #expect(state.profiles.count == 1)
        #expect(state.favorites.count == 1)
        #expect(state.selectedSpace.name == "Personal")
    }

    @Test func eachArcProfileBecomesAKiteProfile() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let result = try ArcImport.parse(Self.fixture)
        let merged = state.mergeArc(result.spaces, favoritesByProfile: result.favoritesByProfile,
                                    profileNames: ["Default": "Personal", "Profile 3": "Work stuff"])
        #expect(state.profiles.map(\.name) == ["Work stuff"])
        let work = try #require(state.profiles.first)
        #expect(merged.newProfiles == [work.directory])
        #expect(merged.profiles == ["Default": "Default", "Profile 3": work.directory])
        #expect(state.spaces.first { $0.id == result.spaces[0].id }?.profile == nil)
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == work.directory)
        // Each grid goes to its own profile; a site in both stays in both.
        #expect(state.favoritesByProfile["Default"]?.map(\.title) == ["Site 300"])
        #expect(state.favoritesByProfile[work.directory]?.map(\.title) == ["Site 310", "Site 300"])

        // Renamed in Kite: importing again keeps the space's profile instead of making another.
        try state.renameProfile(work.directory, to: "Job")
        let again = state.mergeArc(try ArcImport.parse(Self.fixture).spaces,
                                   profileNames: ["Profile 3": "Work stuff"])
        #expect(again.newProfiles.isEmpty)
        #expect(state.profiles.map(\.name) == ["Job"])
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == work.directory)
    }

    @Test func arcProfilesMatchKiteProfilesByName() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let existing = try state.createProfile(named: "work STUFF")
        let result = try ArcImport.parse(Self.fixture)
        let merged = state.mergeArc(result.spaces, profileNames: ["Profile 3": "Work stuff"])
        #expect(merged.newProfiles.isEmpty)
        #expect(state.profiles.map(\.directory) == [existing.directory])
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == existing.directory)
    }

    @Test func unnamedOrUnusedArcProfiles() throws {
        let result = try ArcImport.parse(Self.fixture)
        // No name from Arc's Local State: the profile is named after its folder.
        var state = BrowserState.makeDefault(seedURL: nil)
        state.mergeArc(result.spaces, profileNames: ["Profile 3": "  "])
        #expect(state.profiles.map(\.name) == ["Profile 3"])

        // A profile only a left-out space used isn't made, and its favorites stay behind.
        var personalOnly = BrowserState.makeDefault(seedURL: nil)
        let merged = personalOnly.mergeArc([result.spaces[0]], favoritesByProfile: result.favoritesByProfile,
                                           profileNames: ["Profile 3": "Work stuff"])
        #expect(personalOnly.profiles.isEmpty)
        #expect(merged.profiles == ["Default": "Default"])
        #expect(personalOnly.favoritesByProfile.keys.sorted() == ["Default"])
    }

    @Test func defaultFavoritesComeEvenWithNoDefaultSpace() throws {
        let result = try ArcImport.parse(Self.fixture)
        var state = BrowserState.makeDefault(seedURL: nil)
        let merged = state.mergeArc([result.spaces[1]], favoritesByProfile: result.favoritesByProfile)
        #expect(merged.profiles["Default"] == "Default")
        #expect(state.favoritesByProfile["Default"]?.map(\.title) == ["Site 300"])
        #expect(result.favorites(in: ["Profile 3"]).map(\.title) == ["Site 310", "Site 300", "Site 300"])
    }

    @Test func reimportLeavesSpacesWhereTheUserPutThem() throws {
        let result = try ArcImport.parse(Self.fixture)
        let names = ["Profile 3": "Work"]
        var state = BrowserState.makeDefault(seedURL: nil)
        state.mergeArc(result.spaces, favoritesByProfile: result.favoritesByProfile, profileNames: names)
        let work = try #require(state.profiles.first)
        let other = try state.createProfile(named: "Other")
        state.setProfile(other.directory, forSpace: result.spaces[1].id)
        state.setProfile(other.directory, forSpace: result.spaces[0].id)

        let again = state.mergeArc(result.spaces, favoritesByProfile: result.favoritesByProfile, profileNames: names)
        // The spaces stay put; Work's favorites and history still go to Work.
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == other.directory)
        #expect(state.spaces.first { $0.id == result.spaces[0].id }?.profile == other.directory)
        #expect(again.profiles["Profile 3"] == work.directory)
        #expect(state.favoritesByProfile[other.directory] == nil)

        // Work emptied and renamed: Arc's profile still goes there, not to a new "Work".
        state.spaces.removeAll { $0.id == result.spaces[1].id }
        try state.renameProfile(work.directory, to: "Job")
        let third = state.mergeArc(result.spaces, profileNames: names)
        #expect(third.newProfiles.isEmpty)
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == work.directory)
    }

    @Test func spacesFromAnImportBeforeProfilesMoveToTheirProfile() throws {
        let result = try ArcImport.parse(Self.fixture)
        var state = BrowserState.makeDefault(seedURL: nil)
        // As the import did before it knew profiles: everything in Default.
        state.merge(imported: result.spaces.map { var space = $0; space.profile = nil; return space })
        let merged = state.mergeArc(result.spaces, profileNames: ["Profile 3": "Work"])
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == merged.profiles["Profile 3"])
        #expect(merged.newProfiles.count == 1)
    }

    @Test func sameNamedArcProfilesStayApart() throws {
        var spaces = try ArcImport.parse(Self.fixture).spaces
        var third = spaces[1]
        third.id = UUID()
        third.profile = "Profile 4"
        spaces.append(third)
        var state = BrowserState.makeDefault(seedURL: nil)
        let merged = state.mergeArc(spaces, profileNames: ["Profile 3": "Work", "Profile 4": "work"])
        #expect(state.profiles.map(\.name) == ["Work", "work (Arc)"])
        #expect(merged.profiles["Profile 3"] != merged.profiles["Profile 4"])
    }

    @Test func aDeletedProfilesFolderIsntReusedForArc() throws {
        let result = try ArcImport.parse(Self.fixture)
        var state = BrowserState.makeDefault(seedURL: nil)
        state.mergeArc(result.spaces, profileNames: ["Profile 3": "Work"])
        let work = state.profiles[0].directory
        state.spaces.removeAll { $0.id == result.spaces[1].id }
        let deleted = state.deleteProfile(work)
        #expect(deleted)
        state.forgetRetiredProfiles([work])
        let shopping = try state.createProfile(named: "Shopping")
        #expect(shopping.directory == work)

        let again = state.mergeArc(result.spaces, profileNames: ["Profile 3": "Work"])
        #expect(again.newProfiles.count == 1)
        #expect(again.profiles["Profile 3"] != shopping.directory)
        #expect(state.spaces.first { $0.id == result.spaces[1].id }?.profile == again.profiles["Profile 3"])
    }

    @Test func arcProfileMapSurvivesARelaunch() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        state.mergeArc(try ArcImport.parse(Self.fixture).spaces, profileNames: ["Profile 3": "Work"])
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.arcProfileMap == ["Profile 3": state.profiles[0].dataStoreID])
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

    @Test func picksTheSidebarFileThenItsNewestBackup() {
        let names = ["StorableArchive.json", "StorableSidebar.2024-11-21-17-40-41-080.json", "StorableSidebar.json",
                     "StorableSidebar.2026-11-01-21-05-17-932.json", "StorableSidebarX.txt"]
        #expect(ArcImport.sidebarCandidates(in: names) == [
            "StorableSidebar.json", "StorableSidebar.2026-11-01-21-05-17-932.json", "StorableSidebar.2024-11-21-17-40-41-080.json",
        ])
        // Tried even when the folder couldn't be listed.
        #expect(ArcImport.sidebarCandidates(in: []) == ["StorableSidebar.json"])
    }

    @Test func aBackupOnlyWhenTheCurrentSidebarCantBeRead() {
        #expect(ArcImport.triesBackup(after: ArcImport.Failure.notJSON))
        #expect(ArcImport.triesBackup(after: ArcImport.Failure.notArcSidebar))
        #expect(ArcImport.triesBackup(after: CocoaError(.fileReadNoPermission)))
        // No spaces is what Arc has now; an older backup isn't used instead.
        #expect(!ArcImport.triesBackup(after: ArcImport.Failure.noSpaces))
    }

    @Test func readsABackupsDate() throws {
        let date = try #require(ArcImport.backupDate("StorableSidebar.2026-11-01-21-05-17-932.json"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 11, 1, 21, 5])
        #expect(ArcImport.backupDate("StorableSidebar.json") == nil)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ArcImport.Failure.notArcSidebar) { try ArcImport.parse(Data("{}".utf8)) }
        // Cut short, as a file read while it's written would be.
        #expect(throws: ArcImport.Failure.notJSON) { try ArcImport.parse(Self.fixture.prefix(200)) }
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
