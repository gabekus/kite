#pragma once
// Profiles: each one is its own Chromium profile folder, and every space uses one of them.
// Ports KiteCore's Profiles.swift (Profile, ProfileNameError and BrowserState's profile
// functions) as far as Import from Arc needs them: listing, making, renaming and deleting
// profiles and moving a space into one. Windows has no Profiles UI yet.
//
// They live in session.json as the Mac keeps them, in BrowserState::extra: "profiles"
// ([{"dataStoreID", "directory", "name"}], left out when empty), "retiredProfileDirectories"
// and, for Import from Arc, "arcProfiles" ({Arc folder: dataStoreID}). A space's profile is its
// extra "profile" (absent for the default one).

#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "core/Models.h"

namespace kite {

struct Profile {
    static constexpr const char* kDefaultDirectory = "Default";
    static constexpr const char* kDefaultName = "Default";
    static constexpr const char* kDefaultDataStoreID = "00000000-0000-0000-0000-000000000000";

    std::string directory;  // the Chromium profile folder's name; never changes
    std::string name;
    std::string dataStoreID;  // a UUID, never reused (a deleted profile's folder name is)

    bool IsDefault() const { return directory == kDefaultDirectory; }
    static Profile Default() { return {kDefaultDirectory, kDefaultName, kDefaultDataStoreID}; }
    bool operator==(const Profile&) const = default;
};

// Why a profile name can't be used, with Arc's messages (ProfileNameError.message).
enum class ProfileNameError { Invalid, Duplicate };
const char* Message(ProfileNameError error);

// The profiles made since the default one, in the order they were made. Entries that don't
// read as a Profile are left out (the Mac would refuse the whole session).
std::vector<Profile> Profiles(const BrowserState& state);
// The default profile, then the others.
std::vector<Profile> AllProfiles(const BrowserState& state);
// The profile with that folder, or the default one.
Profile ProfileFor(const BrowserState& state, const std::string& directory);

// Checks a name for a new or renamed profile; `except` is the profile being renamed.
std::optional<ProfileNameError> ValidateProfileName(const BrowserState& state, const std::string& name,
                                                    const std::optional<std::string>& except = std::nullopt);
// Makes a profile in the next free "Profile N" folder, as Chromium names them, and moves
// `spaceIDs` into it.
std::variant<Profile, ProfileNameError> CreateProfile(BrowserState& state, const std::string& name,
                                                      const std::vector<std::string>& spaceIDs = {});
std::optional<ProfileNameError> RenameProfile(BrowserState& state, const std::string& directory, const std::string& name);
// Only a profile no space uses, and never the default one.
bool CanDeleteProfile(const BrowserState& state, const std::string& directory);
// Forgets the profile and its favourites; its folder name isn't reused until the shell has
// deleted the folder (ForgetRetiredProfiles).
bool DeleteProfile(BrowserState& state, const std::string& directory);
void ForgetRetiredProfiles(BrowserState& state, const std::vector<std::string>& directories);
std::vector<std::string> RetiredProfileDirectories(const BrowserState& state);
// Moves a space into a profile (none or an unknown one: the default).
void SetProfile(BrowserState& state, const std::optional<std::string>& directory, const std::string& spaceID);
// A space's profile as stored: none for the default one.
std::optional<std::string> SpaceProfile(const Space& space);
void SetSpaceProfile(Space& space, const std::optional<std::string>& directory);

// Import from Arc: each Arc profile folder's Kite profile, by dataStoreID (BrowserState.arcProfileMap).
// An unreadable value reads as empty, as the Mac's `try?`.
std::map<std::string, std::string> ArcProfileMap(const BrowserState& state);
void SetArcProfileMap(BrowserState& state, const std::map<std::string, std::string>& map);

// Whether two names are the same ignoring case, as Foundation's caseInsensitive compare.
bool SameNameIgnoringCase(const std::string& a, const std::string& b);

}  // namespace kite
