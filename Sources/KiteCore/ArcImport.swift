import Foundation

/// Imports spaces, pinned tabs, folders, split views, favorites and themes from
/// Arc's `StorableSidebar.json`.
///
/// Arc shuts down on 2026-12-22. This file is self-contained so it can be
/// deleted, along with its menu item, some time after that.
///
/// The format is undocumented, so parsing is deliberately loose: unknown item
/// kinds are skipped and reported rather than failing the whole import.
public enum ArcImport {
    public struct Result: Sendable {
        /// Each space's `profile` is still Arc's profile folder ("Profile 1"; nil for Arc's
        /// Default): `BrowserState.mergeArc` maps it to a Kite profile.
        public var spaces: [Space]
        /// Arc's favorites grid for Default and each profile the spaces use, by Arc profile folder.
        public var favoritesByProfile: [String: [BrowserTab]]
        /// Arc profile folders, in the order the spaces use them.
        public var profiles: [String]
        /// Every tab read, favorites included.
        public var tabCount: Int
        public var folderCount: Int
        public var splitCount: Int
        /// Spaces Arc had no name for (shown as "Arc Space"). Often leftovers
        /// the user never set up, so the shell may offer to skip them.
        public var untitledSpaceIDs: Set<UUID>
        /// Things that didn't carry over exactly, in plain words for the user.
        public var notes: [String]

        /// Every profile's favorites, in profile order.
        public var favorites: [BrowserTab] { favorites(in: profiles) }

        /// Default, which Kite always has, then `profiles`, without repeats.
        public static func withDefault(_ profiles: [String]) -> [String] {
            profiles.contains(Profile.defaultDirectory) ? profiles : profiles + [Profile.defaultDirectory]
        }

        /// The favorites of `profiles` and Default, the ones an import of those profiles' spaces brings.
        public func favorites(in profiles: [String]) -> [BrowserTab] {
            Self.withDefault(profiles).flatMap { favoritesByProfile[$0] ?? [] }
        }

        /// The profiles of the spaces that import unless the user includes the unnamed ones.
        public var namedSpaceProfiles: [String] {
            var result: [String] = []
            for space in spaces where !untitledSpaceIDs.contains(space.id) {
                let profile = space.profile ?? Profile.defaultDirectory
                if !result.contains(profile) { result.append(profile) }
            }
            return result
        }
    }

    public enum Failure: Error, Equatable {
        case notArcSidebar
        case noSpaces
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any]
        else { throw Failure.notArcSidebar }

        var parser = Parser(now: now)
        parser.collect(containers)
        let result = parser.buildSpaces()
        guard !result.spaces.isEmpty else { throw Failure.noSpaces }
        return result
    }

    /// Fills in panes without a stored width; nil (equal widths) if the stored ones don't add up.
    static func splitWidthFactors(_ known: [Double?]) -> [Double]? {
        let stored = known.compactMap { $0 }
        guard !stored.isEmpty, stored.allSatisfy({ $0 > 0 }) else { return nil }
        let missing = known.count - stored.count
        let rest = 1 - stored.reduce(0, +)
        if missing == 0 { return stored }
        guard rest > 0 else { return nil }
        return known.map { $0 ?? rest / Double(missing) }
    }

    private struct Parser {
        let now: Date
        var spaceObjects: [[String: Any]] = []
        var items: [String: [String: Any]] = [:]
        /// Arc profile folder ("Default", "Profile 1"…) → favorites container item ID.
        var favoritesContainers: [String: String] = [:]

        var usedIDs: Set<UUID> = []
        var tabCount = 0
        var folderCount = 0
        var splitCount = 0
        var verticalSplits = 0
        /// Splits found while building the current space.
        var spaceSplits: [SplitView] = []
        var untitled: Set<UUID> = []
        var skippedKinds: Set<String> = []
        /// Profiles in the order spaces use them.
        var profiles: [String] = []

        init(now: Date) {
            self.now = now
        }

        // Arc stores most collections as flat [id, object, id, object, ...] arrays.
        mutating func collect(_ containers: [Any]) {
            var seenSpaces: Set<String> = []
            for case let container as [String: Any] in containers {
                for case let space as [String: Any] in container["spaces"] as? [Any] ?? [] {
                    guard let id = space["id"] as? String, seenSpaces.insert(id).inserted else { continue }
                    spaceObjects.append(space)
                }
                for case let item as [String: Any] in container["items"] as? [Any] ?? [] {
                    if let id = item["id"] as? String { items[id] = item }
                }
                let favorites = container["topAppsContainerIDs"] as? [Any] ?? []
                for i in stride(from: 0, to: favorites.count - 1, by: 2) {
                    if let key = profileKey(favorites[i]), let id = favorites[i + 1] as? String {
                        favoritesContainers[key] = id
                    }
                }
            }
        }

        mutating func buildSpaces() -> Result {
            var spaces: [Space] = []
            for object in spaceObjects {
                if let space = buildSpace(object, index: spaces.count) { spaces.append(space) }
            }

            // Favorites: a grid per profile, in Arc and in Kite.
            var favorites: [String: [BrowserTab]] = [:]
            // Default's too: Kite always has that profile, even with no space in it.
            for profile in Result.withDefault(profiles) {
                guard let containerID = favoritesContainers[profile] else { continue }
                // A split in the favorites grid can't stay one: favorites belong to no space.
                spaceSplits = []
                let tabs = children(of: containerID).flatMap { flatTabs($0) }
                spaceSplits = []
                var grid: [BrowserTab] = []
                for tab in tabs where !grid.contains(where: { $0.url == tab.url }) {
                    grid.append(tab)
                }
                if !grid.isEmpty { favorites[profile] = grid }
            }

            var notes: [String] = []
            if verticalSplits > 0 {
                notes.append("\(verticalSplits) split view\(verticalSplits == 1 ? " is" : "s are") stacked top to bottom in Arc. Kite shows \(verticalSplits == 1 ? "it" : "them") side by side until it has that layout.")
            }
            if !skippedKinds.isEmpty {
                notes.append("Skipped unsupported sidebar items: \(skippedKinds.sorted().joined(separator: ", ")).")
            }
            return Result(
                spaces: spaces,
                favoritesByProfile: favorites,
                profiles: profiles,
                tabCount: tabCount,
                folderCount: folderCount,
                splitCount: splitCount,
                untitledSpaceIDs: untitled,
                notes: notes
            )
        }

        private mutating func buildSpace(_ object: [String: Any], index: Int) -> Space? {
            let containers = pairs(object["containerIDs"])
            spaceSplits = []
            let pinned = containers["pinned"].map { children(of: $0).flatMap { pinnedItems($0) } } ?? []
            let unpinned = containers["unpinned"].map { children(of: $0).flatMap { flatTabs($0) } } ?? []

            let profile = profileKey(object["profile"]) ?? Profile.defaultDirectory

            let name = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if name == nil && pinned.isEmpty && unpinned.isEmpty { return nil }
            if !profiles.contains(profile) { profiles.append(profile) }

            splitCount += spaceSplits.count
            verticalSplits += spaceSplits.filter { $0.orientation == .vertical }.count

            let customInfo = object["customInfo"] as? [String: Any]
            let id = uniqueID(object["id"])
            if name == nil { untitled.insert(id) }
            var space = Space(
                id: id,
                name: name ?? "Arc Space",
                icon: icon(customInfo?["iconType"]) ?? Self.fallbackIcons[index % Self.fallbackIcons.count],
                theme: theme(customInfo?["windowTheme"]) ?? Theme.presets[index % Theme.presets.count],
                pinnedItems: pinned,
                tabs: unpinned,
                selectedTabID: unpinned.first?.id,
                splits: spaceSplits
            )
            space.profile = profile == Profile.defaultDirectory ? nil : profile
            return space
        }

        private static let fallbackIcons = ["🌀", "🌿", "🎨", "📚", "🎧", "🧪"]

        // MARK: Items

        private func children(of id: String) -> [[String: Any]] {
            let ids = items[id]?["childrenIds"] as? [String] ?? []
            return ids.compactMap { items[$0] }
        }

        /// A pinned tab, a folder, or a split view's tabs side by side (the split itself
        /// is recorded in `spaceSplits`).
        private mutating func pinnedItems(_ item: [String: Any]) -> [PinnedItem] {
            let data = item["data"] as? [String: Any] ?? [:]
            if data["list"] != nil {
                folderCount += 1
                let id = item["id"] as? String ?? ""
                let contents = children(of: id).flatMap { pinnedItems($0) }
                let name = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
                return [.folder(TabFolder(id: uniqueID(id), name: name, items: contents))]
            }
            return flatTabs(item).map(PinnedItem.tab)
        }

        /// Tabs in an item, flattening split views and (outside the pinned section) folders.
        private mutating func flatTabs(_ item: [String: Any]) -> [BrowserTab] {
            let data = item["data"] as? [String: Any] ?? [:]
            if let tab = data["tab"] as? [String: Any] {
                tabCount += 1
                // An item title is the user's rename; it stays when the page's title changes.
                let customTitle = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var imported = BrowserTab(
                    id: uniqueID(item["id"]),
                    url: (tab["savedURL"] as? String).flatMap(URL.init(string:)),
                    title: tab["savedTitle"] as? String ?? "",
                    // Arc's timestamps would trip Kite's 12-hour auto-archive right away.
                    lastActiveAt: now
                )
                imported.customTitle = customTitle
                return [imported]
            }
            let id = item["id"] as? String ?? ""
            if let split = data["splitView"] as? [String: Any] {
                return splitTabs(id: id, split)
            }
            if data["list"] != nil {
                return children(of: id).flatMap { flatTabs($0) }
            }
            if let kind = data.keys.first { skippedKinds.insert(kind) }
            return []
        }

        /// A split view's tabs, in pane order, recording the split for the space.
        /// Arc's `itemWidthFactors` is a flat [itemID, factor, ...] list and may leave
        /// panes out; those share what's left.
        private mutating func splitTabs(id: String, _ split: [String: Any]) -> [BrowserTab] {
            let widths = doublePairs(split["itemWidthFactors"])
            var tabs: [BrowserTab] = []
            var factors: [Double?] = []
            for child in children(of: id) {
                let childTabs = flatTabs(child)
                tabs += childTabs
                let factor = (child["id"] as? String).flatMap { widths[$0] }
                factors += childTabs.indices.map { $0 == 0 ? factor : nil }
            }
            let panes = Array(tabs.prefix(SplitView.maxPanes))
            guard panes.count >= 2 else { return tabs }
            let orientation = SplitOrientation(rawValue: split["layoutOrientation"] as? String ?? "") ?? .horizontal
            spaceSplits.append(SplitView(
                id: uniqueID(id),
                tabIDs: panes.map(\.id),
                widthFactors: ArcImport.splitWidthFactors(Array(factors.prefix(panes.count))),
                orientation: orientation
            ))
            return tabs
        }


        /// Reuses Arc's UUIDs where possible (so re-importing updates the same spaces)
        /// but never hands out the same ID twice.
        private mutating func uniqueID(_ raw: Any?) -> UUID {
            if let string = raw as? String, let id = UUID(uuidString: string), usedIDs.insert(id).inserted {
                return id
            }
            var id = UUID()
            while !usedIDs.insert(id).inserted { id = UUID() }
            return id
        }

        // MARK: Fields

        private func pairs(_ raw: Any?) -> [String: String] {
            let list = raw as? [Any] ?? []
            var result: [String: String] = [:]
            for i in stride(from: 0, to: list.count - 1, by: 2) {
                if let key = list[i] as? String, let value = list[i + 1] as? String { result[key] = value }
            }
            return result
        }

        private func doublePairs(_ raw: Any?) -> [String: Double] {
            let list = raw as? [Any] ?? []
            var result: [String: Double] = [:]
            for i in stride(from: 0, to: list.count - 1, by: 2) {
                if let key = list[i] as? String, let value = list[i + 1] as? Double { result[key] = value }
            }
            return result
        }

        private func profileKey(_ raw: Any?) -> String? {
            guard let profile = raw as? [String: Any] else { return nil }
            // Arc's Default profile lives in User Data/Default, as Kite's does.
            if profile["default"] != nil { return Profile.defaultDirectory }
            let custom = (profile["custom"] as? [String: Any])?["_0"] as? [String: Any]
            return custom?["directoryBasename"] as? String
        }

        private func icon(_ raw: Any?) -> String? {
            guard let iconType = raw as? [String: Any] else { return nil }
            if let emoji = iconType["emoji_v2"] as? String, !emoji.isEmpty { return emoji }
            if let code = iconType["emoji"] as? Int, let scalar = Unicode.Scalar(UInt32(code)) {
                return String(Character(scalar))
            }
            return nil
        }

        /// Pulls every color out of the theme's background, whatever the variant
        /// (single color, gradient, ...), in a stable order.
        private func theme(_ raw: Any?) -> Theme? {
            guard let background = (raw as? [String: Any])?["background"] else { return nil }
            var colors: [ThemeColor] = []
            var noise: Double?
            func walk(_ value: Any) {
                if let dict = value as? [String: Any] {
                    if let r = dict["red"] as? Double, let g = dict["green"] as? Double, let b = dict["blue"] as? Double {
                        let color = ThemeColor(r: clamp(r), g: clamp(g), b: clamp(b))
                        if !colors.contains(color) { colors.append(color) }
                        return
                    }
                    if let n = dict["noiseFactor"] as? Double { noise = n }
                    for key in dict.keys.sorted() { walk(dict[key]!) }
                } else if let list = value as? [Any] {
                    list.forEach(walk)
                }
            }
            walk(background)
            guard !colors.isEmpty else { return nil }
            var intensity: Double?
            var translucency: String?
            func settings(_ value: Any) {
                if let dict = value as? [String: Any] {
                    if let i = dict["intensityFactor"] as? Double { intensity = i }
                    if let t = dict["translucencyStyle"] {
                        // Either a bare case name or Swift's enum encoding, {"opaque": {}}.
                        translucency = (t as? String) ?? (t as? [String: Any])?.keys.first
                    }
                    for key in dict.keys.sorted() { settings(dict[key]!) }
                } else if let list = value as? [Any] {
                    list.forEach(settings)
                }
            }
            settings(raw!)
            // Arc draws the theme at its intensity over the window's material; "opaque" hides the material.
            let tint = translucency == "opaque" ? 1 : Theme.defaultTint * Float(intensity ?? 1)
            return Theme(colors: colors, grain: Float(noise ?? 0.35), tint: tint)
        }

        private func clamp(_ x: Double) -> Float {
            Float(min(max(x, 0), 1))
        }
    }
}

extension BrowserState {
    /// What an Arc import did. `profiles` maps each Arc profile folder it brought (Default and
    /// those the imported spaces use) to the Kite profile folder that holds it now, so the shell
    /// can bring each one's history.
    public struct ArcMerge: Equatable, Sendable {
        public var added: Int
        public var updated: Int
        public var profiles: [String: String]
        /// Kite profiles the import made, in order.
        public var newProfiles: [String]
    }

    /// An Arc profile's name from Arc's `Local State`, or its folder's when it has none.
    public static func arcProfileName(_ directory: String, names: [String: String]) -> String {
        let name = names[directory]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? directory : name
    }

    /// The Kite profile each Arc profile folder in `directories` goes to, for those that
    /// already have one: Arc's Default is Kite's; then the profile an earlier import put it in
    /// (so a rename in Kite sticks), while it exists; then one with the same name. The rest get
    /// a new profile. `names` is Arc's folder → profile name, from Arc's `Local State`.
    public func existingProfiles(forArc directories: [String], names: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for arc in directories {
            if arc == Profile.defaultDirectory {
                result[arc] = Profile.defaultDirectory
            } else if let earlier = arcProfileMap[arc], let profile = profiles.first(where: { $0.dataStoreID == earlier }) {
                // By data store, which is never reused: a deleted profile's folder name is.
                result[arc] = profile.directory
            } else {
                let name = Self.arcProfileName(arc, names: names)
                if let match = allProfiles.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                    result[arc] = match.directory
                }
            }
        }
        return result
    }

    /// Adds spaces and favorites from Arc, making a Kite profile for each Arc profile that has
    /// none yet (see `existingProfiles`). `imported` spaces carry Arc's profile folder, as
    /// `ArcImport.parse` leaves them. A space imported before (same ID) is replaced, so
    /// importing again before Arc shuts down picks up changes, but it stays in the profile it's
    /// in now once an import has placed its Arc profile, wherever the user moved it since. A space
    /// moved to another profile in Arc after it was imported stays where it is in Kite too.
    @discardableResult
    public mutating func mergeArc(
        _ imported: [Space],
        favoritesByProfile newFavorites: [String: [BrowserTab]] = [:],
        profileNames names: [String: String] = [:]
    ) -> ArcMerge {
        var arcProfiles: [String] = []
        for space in imported {
            let arc = space.profile ?? Profile.defaultDirectory
            if !arcProfiles.contains(arc) { arcProfiles.append(arc) }
        }
        arcProfiles = ArcImport.Result.withDefault(arcProfiles)
        let placedBefore = Set(arcProfileMap.keys).union([Profile.defaultDirectory])
        var map = existingProfiles(forArc: arcProfiles, names: names)
        var made: [String] = []
        for arc in arcProfiles where map[arc] == nil {
            // Taken by a Kite profile that isn't this one, or by another Arc profile of the same name.
            let name = Self.arcProfileName(arc, names: names)
            let profile = [name, "\(name) (Arc)", arc, "\(arc) (Arc)"].lazy.compactMap { [self] candidate -> String? in
                validateProfileName(candidate) == nil ? candidate : nil
            }.first.flatMap { try? createProfile(named: $0) }
            // Only a Kite profile named for each candidate stops this; the spaces stay in Default.
            map[arc] = profile?.directory ?? Profile.defaultDirectory
            if let profile { made.append(profile.directory) }
        }
        for (arc, directory) in map where arc != Profile.defaultDirectory && directory != Profile.defaultDirectory {
            arcProfileMap[arc] = profile(directory).dataStoreID
        }

        for arc in arcProfiles {
            guard let tabs = newFavorites[arc], let directory = map[arc] else { continue }
            var grid = favoritesByProfile[directory] ?? []
            let existing = Set(grid.compactMap(\.url))
            grid += tabs.filter { $0.url.map { !existing.contains($0) } ?? false }
            favoritesByProfile[directory] = grid.isEmpty ? nil : grid
        }

        let spaces = imported.map { space in
            var space = space
            let arc = space.profile ?? Profile.defaultDirectory
            if let index = spaceIndex(space.id), placedBefore.contains(arc) {
                space.profile = self.spaces[index].profile
            } else {
                let directory = map[arc] ?? Profile.defaultDirectory
                space.profile = directory == Profile.defaultDirectory ? nil : directory
            }
            return space
        }
        let (added, updated) = merge(imported: spaces)
        return ArcMerge(added: added, updated: updated, profiles: map, newProfiles: made)
    }
}
