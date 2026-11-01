import Foundation

/// Arc's Profiles: each one is its own Chromium profile folder (cookies, logins, history,
/// extensions, favourites), and every space uses one of them. Arc names the folders the way
/// Chromium does ("Default", "Profile 1", "Profile 2"…) and a space points at its profile by
/// that folder name (StorableSidebar.json: `space.profile` is `{"default": true}` or
/// `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}`). Kite keeps the same shape.
public struct Profile: Identifiable, Hashable, Codable, Sendable {
    /// The folder the default profile lives in. It always exists and can't be deleted or renamed.
    public static let defaultDirectory = "Default"
    /// Arc's name for the default profile in its lists.
    public static let defaultName = "Default"

    /// The Chromium profile folder's name, Arc's `directoryBasename`. Never changes.
    public var directory: String
    public var name: String
    /// Names the profile's website data store on WebKit, which keys stores by UUID.
    public var dataStoreID: UUID

    public var id: String { directory }
    public var isDefault: Bool { directory == Self.defaultDirectory }

    public init(directory: String, name: String, dataStoreID: UUID = UUID()) {
        self.directory = directory
        self.name = name
        self.dataStoreID = dataStoreID
    }

    public static let `default` = Profile(
        directory: defaultDirectory,
        name: defaultName,
        dataStoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    )
}

/// Why a profile name can't be used, with Arc's messages.
public enum ProfileNameError: Error, Equatable, Sendable {
    case invalid
    case duplicate

    public var message: String {
        switch self {
        case .invalid: "Invalid Profile name."
        case .duplicate: "A Profile with that name already exists."
        }
    }
}

extension BrowserState {
    /// The default profile, then the ones made since, in the order they were made.
    public var allProfiles: [Profile] { [.default] + profiles }

    public func profile(_ directory: String?) -> Profile {
        profiles.first { $0.directory == directory } ?? .default
    }

    /// The folder of the profile space `index` uses; a profile that has gone counts as the default.
    public func profileDirectory(ofSpace index: Int) -> String {
        profile(spaces[index].profile).directory
    }

    /// The profile the window's current space uses: its favourites are the ones shown.
    public var selectedProfileDirectory: String { profileDirectory(ofSpace: selectedSpaceIndex) }

    /// The profile a tab's page belongs to: its space's, or for a favourite, the current space's.
    public func profileDirectory(ofTab id: UUID) -> String {
        if let s = spaces.firstIndex(where: { $0.allTabs.contains { $0.id == id } }) {
            return profileDirectory(ofSpace: s)
        }
        if let (directory, _) = favoritesByProfile.first(where: { $0.value.contains { $0.id == id } }) {
            return directory
        }
        return selectedProfileDirectory
    }

    /// Spaces using `directory`, in sidebar order.
    public func spaces(usingProfile directory: String) -> [Space] {
        spaces.indices.filter { profileDirectory(ofSpace: $0) == directory }.map { spaces[$0] }
    }

    /// Checks a name for a new or renamed profile; `except` is the profile being renamed.
    public func validateProfileName(_ name: String, except directory: String? = nil) -> ProfileNameError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(where: \.isNewline) { return .invalid }
        let taken = allProfiles.contains {
            $0.directory != directory && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        return taken ? .duplicate : nil
    }

    /// Makes a profile in the next free "Profile N" folder, as Chromium's profile manager names
    /// them, and moves `spaceIDs` into it.
    public mutating func createProfile(named name: String, spaces spaceIDs: [UUID] = []) throws -> Profile {
        if let error = validateProfileName(name) { throw error }
        let used = Set(allProfiles.map(\.directory) + retiredProfileDirectories)
        let n = (1...).first { !used.contains("Profile \($0)") }!
        let profile = Profile(directory: "Profile \(n)", name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        profiles.append(profile)
        for id in spaceIDs { setProfile(profile.directory, forSpace: id) }
        return profile
    }

    public mutating func renameProfile(_ directory: String, to name: String) throws {
        guard let i = profiles.firstIndex(where: { $0.directory == directory }) else { return }
        if let error = validateProfileName(name, except: directory) { throw error }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Arc: "Only Profiles not assigned to any Spaces can be deleted." and "The Default Profile
    /// cannot be deleted."
    public func canDeleteProfile(_ directory: String) -> Bool {
        directory != Profile.defaultDirectory
            && profiles.contains { $0.directory == directory }
            && spaces(usingProfile: directory).isEmpty
    }

    /// Forgets the profile and its favourites. The shell deletes the folder; its name isn't
    /// reused until then, so a new profile never opens the old one's data.
    @discardableResult
    public mutating func deleteProfile(_ directory: String) -> Bool {
        guard canDeleteProfile(directory) else { return false }
        profiles.removeAll { $0.directory == directory }
        favoritesByProfile[directory] = nil
        retiredProfileDirectories.append(directory)
        return true
    }

    /// The shell has deleted these folders, so their names are free again.
    public mutating func forgetRetiredProfiles(_ directories: Set<String>) {
        retiredProfileDirectories.removeAll { directories.contains($0) }
    }

    /// Moves a space into another profile (nil or "Default" for the default one). Its tabs keep
    /// their URLs and reload in the new profile.
    public mutating func setProfile(_ directory: String?, forSpace id: UUID) {
        guard let s = spaceIndex(id) else { return }
        let directory = directory.flatMap { d in profiles.contains { $0.directory == d } ? d : nil }
        spaces[s].profile = directory
    }
}
