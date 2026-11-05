// Port of KiteCore Profiles.swift; see Profiles.h.

#include "core/Profiles.h"

#include <algorithm>
#include <set>

#include "core/Unicode.h"
#include "core/Uuid.h"

namespace kite {

namespace {

std::optional<Profile> DecodeProfile(const json::Value& v) {
    const json::Value* directory = v.Find("directory");
    const json::Value* name = v.Find("name");
    const json::Value* store = v.Find("dataStoreID");
    if (!directory || !directory->AsString() || !name || !name->AsString() || !store || !store->AsString()) return std::nullopt;
    auto id = NormalizeUuid(*store->AsString());
    if (!id) return std::nullopt;
    return Profile{*directory->AsString(), *name->AsString(), *id};
}

json::Value Encode(const Profile& p) {
    return json::Object{{"dataStoreID", p.dataStoreID}, {"directory", p.directory}, {"name", p.name}};
}

void SetProfiles(BrowserState& state, const std::vector<Profile>& profiles) {
    if (profiles.empty()) {
        state.extra.erase("profiles");
        return;
    }
    json::Array array;
    for (const Profile& p : profiles) array.push_back(Encode(p));
    state.extra.insert_or_assign("profiles", json::Value(std::move(array)));
}

void SetRetired(BrowserState& state, const std::vector<std::string>& directories) {
    if (directories.empty()) {
        state.extra.erase("retiredProfileDirectories");
        return;
    }
    json::Array array(directories.begin(), directories.end());
    state.extra.insert_or_assign("retiredProfileDirectories", json::Value(std::move(array)));
}

// Swift's Character.isNewline.
bool IsNewline(char32_t c) { return (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029; }

}  // namespace

const char* Message(ProfileNameError error) {
    return error == ProfileNameError::Invalid ? "Invalid Profile name." : "A Profile with that name already exists.";
}

std::vector<Profile> Profiles(const BrowserState& state) {
    std::vector<Profile> out;
    auto it = state.extra.find("profiles");
    if (it == state.extra.end() || !it->second.AsArray()) return out;
    for (const auto& value : *it->second.AsArray()) {
        if (auto profile = DecodeProfile(value)) out.push_back(std::move(*profile));
    }
    return out;
}

std::vector<Profile> AllProfiles(const BrowserState& state) {
    std::vector<Profile> out{Profile::Default()};
    for (Profile& p : Profiles(state)) out.push_back(std::move(p));
    return out;
}

Profile ProfileFor(const BrowserState& state, const std::string& directory) {
    for (Profile& p : Profiles(state)) {
        if (p.directory == directory) return p;
    }
    return Profile::Default();
}

bool SameNameIgnoringCase(const std::string& a, const std::string& b) { return unicode::Folded(a) == unicode::Folded(b); }

std::optional<ProfileNameError> ValidateProfileName(const BrowserState& state, const std::string& name,
                                                    const std::optional<std::string>& except) {
    const std::string trimmed(unicode::Trim(name));
    const std::vector<char32_t> points = unicode::Decode(trimmed);
    if (trimmed.empty() || std::any_of(points.begin(), points.end(), IsNewline)) return ProfileNameError::Invalid;
    for (const Profile& p : AllProfiles(state)) {
        if ((!except || p.directory != *except) && SameNameIgnoringCase(p.name, trimmed)) return ProfileNameError::Duplicate;
    }
    return std::nullopt;
}

std::variant<Profile, ProfileNameError> CreateProfile(BrowserState& state, const std::string& name,
                                                      const std::vector<std::string>& spaceIDs) {
    if (auto error = ValidateProfileName(state, name)) return *error;
    std::set<std::string> used;
    for (const Profile& p : AllProfiles(state)) used.insert(p.directory);
    for (const std::string& d : RetiredProfileDirectories(state)) used.insert(d);
    int n = 1;
    while (used.contains("Profile " + std::to_string(n))) ++n;
    Profile profile{"Profile " + std::to_string(n), std::string(unicode::Trim(name)), NewUuid()};
    std::vector<Profile> profiles = Profiles(state);
    profiles.push_back(profile);
    SetProfiles(state, profiles);
    for (const std::string& id : spaceIDs) SetProfile(state, profile.directory, id);
    return profile;
}

std::optional<ProfileNameError> RenameProfile(BrowserState& state, const std::string& directory, const std::string& name) {
    std::vector<Profile> profiles = Profiles(state);
    auto it = std::find_if(profiles.begin(), profiles.end(), [&](const Profile& p) { return p.directory == directory; });
    if (it == profiles.end()) return std::nullopt;
    if (auto error = ValidateProfileName(state, name, directory)) return error;
    it->name = std::string(unicode::Trim(name));
    SetProfiles(state, profiles);
    return std::nullopt;
}

bool CanDeleteProfile(const BrowserState& state, const std::string& directory) {
    if (directory == Profile::kDefaultDirectory) return false;
    const std::vector<Profile> profiles = Profiles(state);
    if (std::none_of(profiles.begin(), profiles.end(), [&](const Profile& p) { return p.directory == directory; })) return false;
    for (size_t s = 0; s < state.spaces.size(); ++s) {
        if (state.ProfileDirectory(s) == directory) return false;
    }
    return true;
}

bool DeleteProfile(BrowserState& state, const std::string& directory) {
    if (!CanDeleteProfile(state, directory)) return false;
    std::vector<Profile> profiles = Profiles(state);
    std::erase_if(profiles, [&](const Profile& p) { return p.directory == directory; });
    SetProfiles(state, profiles);
    state.favoritesByProfile.erase(directory);
    std::vector<std::string> retired = RetiredProfileDirectories(state);
    retired.push_back(directory);
    SetRetired(state, retired);
    return true;
}

void ForgetRetiredProfiles(BrowserState& state, const std::vector<std::string>& directories) {
    std::vector<std::string> retired = RetiredProfileDirectories(state);
    std::erase_if(retired, [&](const std::string& d) { return std::find(directories.begin(), directories.end(), d) != directories.end(); });
    SetRetired(state, retired);
}

std::vector<std::string> RetiredProfileDirectories(const BrowserState& state) {
    std::vector<std::string> out;
    auto it = state.extra.find("retiredProfileDirectories");
    if (it == state.extra.end() || !it->second.AsArray()) return out;
    for (const auto& value : *it->second.AsArray()) {
        if (auto* text = value.AsString()) out.push_back(*text);
    }
    return out;
}

void SetProfile(BrowserState& state, const std::optional<std::string>& directory, const std::string& spaceID) {
    auto index = state.SpaceIndex(spaceID);
    if (!index) return;
    std::optional<std::string> known;
    if (directory) {
        for (const Profile& p : Profiles(state)) {
            if (p.directory == *directory) known = *directory;
        }
    }
    SetSpaceProfile(state.spaces[*index], known);
}

std::optional<std::string> SpaceProfile(const Space& space) {
    auto it = space.extra.find("profile");
    if (it == space.extra.end() || !it->second.AsString()) return std::nullopt;
    return *it->second.AsString();
}

void SetSpaceProfile(Space& space, const std::optional<std::string>& directory) {
    if (directory) space.extra.insert_or_assign("profile", *directory);
    else space.extra.erase("profile");
}

std::map<std::string, std::string> ArcProfileMap(const BrowserState& state) {
    std::map<std::string, std::string> out;
    auto it = state.extra.find("arcProfiles");
    if (it == state.extra.end() || !it->second.AsObject()) return out;
    for (const auto& [arc, value] : *it->second.AsObject()) {
        auto* text = value.AsString();
        auto id = text ? NormalizeUuid(*text) : std::nullopt;
        // [String: UUID] decoded with try?: one bad entry and the whole map reads as empty.
        if (!id) return {};
        out[arc] = *id;
    }
    return out;
}

void SetArcProfileMap(BrowserState& state, const std::map<std::string, std::string>& map) {
    if (map.empty()) {
        state.extra.erase("arcProfiles");
        return;
    }
    json::Object object;
    for (const auto& [arc, id] : map) object.emplace(arc, id);
    state.extra.insert_or_assign("arcProfiles", json::Value(std::move(object)));
}

}  // namespace kite
