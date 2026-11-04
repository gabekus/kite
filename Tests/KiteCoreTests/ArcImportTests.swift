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

    /// Spaces whose pinned section is item n·10 and unpinned section item n·10 + 1, in Arc
    /// profile folder `profiles[n]` (Default if none); `items` are the rest.
    private static func sidebar(_ items: [[String: Any]], spaces: [Int] = [1], profiles: [Int: String] = [:],
                                favorites: [Any] = []) throws -> ArcImport.Result {
        var spaceList: [Any] = []
        for n in spaces {
            var profile: [String: Any] = ["default": true]
            if let folder = profiles[n] { profile = ["custom": ["_0": ["directoryBasename": folder, "machineID": "m"]]] }
            let space: [String: Any] = [
                "id": id(n), "title": "Space \(n)", "profile": profile,
                "containerIDs": ["pinned", id(n * 10), "unpinned", id(n * 10 + 1)],
            ]
            spaceList += [id(n), space]
        }
        let root: [String: Any] = ["sidebar": ["containers": [[
            "spaces": spaceList,
            "items": items.flatMap { [$0["id"]!, $0] },
            "topAppsContainerIDs": favorites,
        ]]]]
        return try ArcImport.parse(JSONSerialization.data(withJSONObject: root))
    }

    private static func folder(_ n: Int, parent: Int? = nil, children: [Int]) -> [String: Any] {
        var folder = node(n, kind: ["list": [:]], title: "Folder \(n)", children: children)
        if let parent { folder["parentID"] = id(parent) }
        return folder
    }

    private static func split(_ n: Int, children: [Int]) -> [String: Any] {
        node(n, kind: ["splitView": ["layoutOrientation": "horizontal"]], children: children)
    }

    private static func container(_ n: Int, children: [Int]) -> [String: Any] {
        node(n, kind: ["itemContainer": [:]], children: children)
    }

    @Test func aSelfParentingFolderImportsOnce() throws {
        let result = try Self.sidebar([
            Self.container(10, children: [100, 101]),
            Self.tab(100, parent: 10),
            Self.folder(101, parent: 101, children: [101, 102]),
            Self.tab(102, parent: 101),
            Self.container(11, children: []),
        ])
        let pinned = result.spaces[0].pinnedItems
        guard pinned.count == 2, case .folder(let folder) = pinned[1] else {
            Issue.record("unexpected pinned items: \(pinned)")
            return
        }
        #expect(pinned.tabs.map(\.title) == ["Site 100", "Site 102"])
        #expect(folder.items.count == 1)
        #expect(result.folderCount == 1)
        #expect(result.tabCount == 2)
        #expect(result.notes == ["Skipped 1 repeated or circular sidebar entry."])
    }

    @Test func aTwoCycleImportsEachFolderOnce() throws {
        let result = try Self.sidebar([
            // Each folder's parentID names the other, so neither may claim the other first.
            Self.container(10, children: [101]),
            Self.folder(101, parent: 102, children: [102, 103]),
            Self.folder(102, parent: 101, children: [101, 104]),
            Self.tab(103, parent: 101),
            Self.tab(104, parent: 102),
            // The same cycle outside the pinned section, where folders flatten.
            Self.container(11, children: [111]),
            Self.folder(111, children: [112, 113]),
            Self.folder(112, children: [111, 114]),
            Self.tab(113, parent: 111),
            Self.tab(114, parent: 112),
        ])
        let space = result.spaces[0]
        guard space.pinnedItems.count == 1, case .folder(let outer) = space.pinnedItems[0],
              outer.items.count == 2, case .folder(let inner) = outer.items[0]
        else {
            Issue.record("unexpected pinned items: \(space.pinnedItems)")
            return
        }
        #expect(outer.name == "Folder 101")
        #expect(inner.name == "Folder 102")
        #expect(inner.items.tabs.map(\.title) == ["Site 104"])
        #expect(outer.items.tabs.map(\.title) == ["Site 104", "Site 103"])
        #expect(space.tabs.map(\.title) == ["Site 114", "Site 113"])
        #expect(result.folderCount == 2)
        #expect(result.tabCount == 4)
        #expect(result.notes == ["Skipped 2 repeated or circular sidebar entries."])
    }

    @Test func aCycleThroughASplitImportsEachTabOnce() throws {
        // Split 400 holds tab 401 and folder 402, which lists the split again.
        let result = try Self.sidebar([
            Self.container(10, children: [400]),
            Self.split(400, children: [401, 402]),
            Self.tab(401, parent: 400),
            Self.folder(402, children: [400, 403]),
            Self.tab(403, parent: 402),
            Self.container(11, children: []),
        ])
        let space = result.spaces[0]
        #expect(space.pinnedItems.tabs.map(\.title) == ["Site 401", "Site 403"])
        #expect(space.splits.map(\.tabIDs) == [space.pinnedItems.tabs.map(\.id)])
        #expect(result.tabCount == 2)
        #expect(result.notes == ["Skipped 1 repeated or circular sidebar entry."])
    }

    @Test func aChildListedTwiceImportsOnce() throws {
        // Forty folders that each list the next one twice: 2^40 copies of the last tab if
        // repeats were followed.
        let chain = (0..<40).map { Self.folder(200 + $0, children: [201 + $0, 201 + $0]) }
        let result = try Self.sidebar([
            Self.container(10, children: [100, 100, 101]),
            Self.tab(100, parent: 10),
            Self.folder(101, children: [102, 102, 100]),
            Self.tab(102, parent: 101),
            Self.container(11, children: [110, 110, 200]),
            Self.tab(110, parent: 11),
            Self.tab(240, parent: 239),
        ] + chain)
        let space = result.spaces[0]
        #expect(space.pinnedItems.count == 2)
        #expect(space.pinnedItems.tabs.map(\.title) == ["Site 100", "Site 102"])
        #expect(space.tabs.map(\.title) == ["Site 110", "Site 240"])
        #expect(Set(space.allTabs.map(\.id)).count == space.allTabs.count)
        #expect(result.tabCount == 4)
        #expect(result.notes == ["Skipped 44 repeated or circular sidebar entries."])
    }

    @Test func aChildListedUnderTwoParentsGoesToItsParentID() throws {
        // Tab 100 was moved from space 1's folder to space 2's, and the old listing stayed.
        let result = try Self.sidebar([
            Self.container(10, children: [101]),
            Self.folder(101, children: [100]),
            Self.container(11, children: []),
            Self.container(20, children: [201]),
            Self.folder(201, children: [100]),
            Self.tab(100, parent: 201),
            Self.container(21, children: []),
        ], spaces: [1, 2])
        guard result.spaces.count == 2,
              case .folder(let old)? = result.spaces[0].pinnedItems.first,
              case .folder(let current)? = result.spaces[1].pinnedItems.first
        else {
            Issue.record("unexpected spaces: \(result.spaces)")
            return
        }
        #expect(old.items.isEmpty)
        #expect(current.items.tabs.map(\.title) == ["Site 100"])
        #expect(result.tabCount == 1)
        #expect(result.notes == ["Skipped 1 repeated or circular sidebar entry."])
    }

    @Test func profilesSharingAFavoritesGridBothGetIt() throws {
        let favorites: [Any] = [
            ["default": true], Self.id(30),
            ["custom": ["_0": ["directoryBasename": "Profile 3"]]], Self.id(30),
        ]
        let result = try Self.sidebar([
            Self.container(10, children: []),
            Self.container(11, children: []),
            Self.container(20, children: []),
            Self.container(21, children: []),
            Self.container(30, children: [300]),
            Self.tab(300, parent: 30),
        ], spaces: [1, 2], profiles: [2: "Profile 3"], favorites: favorites)
        #expect(result.profiles == ["Default", "Profile 3"])
        #expect(result.favoritesByProfile["Default"]?.map(\.title) == ["Site 300"])
        #expect(result.favoritesByProfile["Profile 3"]?.map(\.title) == ["Site 300"])
        #expect(result.notes.isEmpty)
    }

    @Test func aVeryDeepChainStopsAtTheCap() throws {
        // Ten thousand folders, each inside the last, with a tab at the bottom.
        let depth = 10_000
        let chain = (0..<depth).map { Self.folder(1000 + $0, children: [1001 + $0]) }
        let result = try Self.sidebar([
            Self.container(10, children: [1000]),
            Self.tab(1000 + depth, parent: 999 + depth),
            Self.container(11, children: [1000 + depth + 1]),
            Self.tab(1000 + depth + 1, parent: 11),
        ] + chain)
        var levels = 0
        var level = result.spaces[0].pinnedItems
        while case .folder(let folder)? = level.first {
            levels += 1
            level = folder.items
        }
        #expect(levels == ArcImport.maxDepth)
        #expect(level.isEmpty)
        #expect(result.folderCount == ArcImport.maxDepth)
        #expect(result.spaces[0].tabs.map(\.title) == ["Site \(1000 + depth + 1)"])
        // Every folder below the cap, and the tab at the bottom.
        let cut = depth - ArcImport.maxDepth + 1
        #expect(result.notes == ["\(cut) items nested more than \(ArcImport.maxDepth) levels deep were left out."])
    }

    @Test func aSplitInAFolderAtTheCap() throws {
        // Folders down to level 61. The last holds split 2000 (level 62, its tabs at 63: kept)
        // and folder 1062 (level 62), whose split 3000 puts its tabs at 64, past the cap.
        #expect(ArcImport.maxDepth == 64)
        let chain = (0..<61).map { Self.folder(1000 + $0, children: [1001 + $0]) }
        let result = try Self.sidebar([
            Self.container(10, children: [1000]),
            Self.folder(1061, children: [2000, 1062]),
            Self.split(2000, children: [2001, 2002]),
            Self.tab(2001, parent: 2000),
            Self.tab(2002, parent: 2000),
            Self.folder(1062, children: [3000]),
            Self.split(3000, children: [3001, 3002]),
            Self.tab(3001, parent: 3000),
            Self.tab(3002, parent: 3000),
            Self.container(11, children: []),
        ] + chain)
        let space = result.spaces[0]
        #expect(space.pinnedItems.tabs.map(\.title) == ["Site 2001", "Site 2002"])
        #expect(space.splits.map(\.tabIDs) == [space.pinnedItems.tabs.map(\.id)])
        #expect(result.splitCount == 1)
        #expect(result.folderCount == 63)
        #expect(result.notes == ["2 items nested more than 64 levels deep were left out."])
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
