import Foundation
import Testing
@testable import KiteCore

@Suite struct ProfilesTests {
    func twoSpaces() -> BrowserState {
        let a = Space(name: "Personal", icon: "🏠", theme: Theme.presets[0])
        let b = Space(name: "Work", icon: "💼", theme: Theme.presets[1])
        return BrowserState(spaces: [a, b])
    }

    @Test func newProfilesTakeChromiumsFolderNames() throws {
        var state = twoSpaces()
        let work = try state.createProfile(named: "Work", spaces: [state.spaces[1].id])
        #expect(work.directory == "Profile 1")
        #expect(state.profileDirectory(ofSpace: 1) == "Profile 1")
        #expect(state.profileDirectory(ofSpace: 0) == Profile.defaultDirectory)
        let school = try state.createProfile(named: "School")
        #expect(school.directory == "Profile 2")
        #expect(state.allProfiles.map(\.name) == ["Default", "Work", "School"])
    }

    @Test func namesAreCheckedLikeArcs() throws {
        var state = twoSpaces()
        _ = try state.createProfile(named: "Work")
        #expect(state.validateProfileName("  ") == .invalid)
        #expect(state.validateProfileName("work") == .duplicate)
        #expect(state.validateProfileName("default") == .duplicate)
        #expect(state.validateProfileName("Work", except: "Profile 1") == nil)
        var copy = state
        #expect(throws: ProfileNameError.duplicate) { try copy.createProfile(named: "Work") }
        #expect(ProfileNameError.duplicate.message == "A Profile with that name already exists.")
    }

    @Test func onlyUnusedProfilesCanBeDeleted() throws {
        var state = twoSpaces()
        let work = try state.createProfile(named: "Work", spaces: [state.spaces[1].id])
        #expect(!state.canDeleteProfile(Profile.defaultDirectory))
        let refused = state.deleteProfile(work.directory)
        #expect(!refused)
        state.setProfile(nil, forSpace: state.spaces[1].id)
        let deleted = state.deleteProfile(work.directory)
        #expect(deleted)
        #expect(state.profiles.isEmpty)
        // The folder isn't reused until the shell has deleted it.
        let again = try state.createProfile(named: "Again")
        #expect(again.directory == "Profile 2")
        state.forgetRetiredProfiles(["Profile 1"])
        let third = try state.createProfile(named: "Third")
        #expect(third.directory == "Profile 1")
    }

    @Test func favoritesBelongToTheCurrentSpacesProfile() throws {
        var state = twoSpaces()
        let personal = state.spaces[0].id, work = state.spaces[1].id
        _ = try state.createProfile(named: "Work", spaces: [work])
        state.selectedSpaceID = personal
        state.favorites = [BrowserTab(url: URL(string: "https://mail.example")!)]
        state.selectedSpaceID = work
        #expect(state.favorites.isEmpty)
        state.favorites = [BrowserTab(url: URL(string: "https://work.example")!)]
        state.selectedSpaceID = personal
        #expect(state.favorites.map(\.url?.host) == ["mail.example"])
        // Every profile's favorites stay live, and know their profile.
        let workFavorite = state.favoritesByProfile["Profile 1"]![0].id
        #expect(state.allTabIDs.contains(workFavorite))
        #expect(state.profileDirectory(ofTab: workFavorite) == "Profile 1")
    }

    @Test func sessionsRoundTripAndOldOnesStillLoad() throws {
        var state = twoSpaces()
        state.favorites = [BrowserTab(url: URL(string: "https://a.example")!)]
        _ = try state.createProfile(named: "Work", spaces: [state.spaces[1].id])
        state.selectedSpaceID = state.spaces[1].id
        state.favorites = [BrowserTab(url: URL(string: "https://b.example")!)]
        state.syncPinnedURLs()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded == state)
        // Before profiles, "favorites" was the only grid; it's the default profile's.
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["favorites"] as? [Any])?.count == 1)
        var old = json
        old["profiles"] = nil
        old["profileFavorites"] = nil
        var spaces = old["spaces"] as! [[String: Any]]
        spaces[1]["profile"] = nil
        old["spaces"] = spaces
        let legacy = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.profiles.isEmpty)
        #expect(legacy.favoritesByProfile[Profile.defaultDirectory]?.count == 1)
    }

    @Test func aSpaceWhoseProfileIsGoneUsesTheDefault() {
        var state = twoSpaces()
        state.spaces[1].profile = "Profile 9"
        #expect(state.profileDirectory(ofSpace: 1) == Profile.defaultDirectory)
    }
}
