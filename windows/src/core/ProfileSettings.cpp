// Port of KiteCore's ProfileSettings.swift and DownloadLocation.defaultFolder; see ProfileSettings.h.

#include "core/ProfileSettings.h"

#include "core/Models.h"
#include "core/Uuid.h"

namespace kite {

std::filesystem::path ProfileSettings::DownloadFolder(const std::filesystem::path& downloads,
                                                      const std::function<bool(const std::string&)>& exists) const {
    if (!downloadDirectory || !exists(*downloadDirectory)) return downloads;
    return std::filesystem::path(std::u8string(downloadDirectory->begin(), downloadDirectory->end()));
}

bool ProfileSettings::IsDefault() const {
    return !downloadDirectory && !promptsForDownload && includesSearchSuggestions;
}

json::Value Encode(const ProfileSettings& settings) {
    json::Object o = settings.extra;
    // Swift's synthesized encoder: an optional only when it has a value, the Bools always.
    if (settings.downloadDirectory) o.insert_or_assign("downloadDirectory", *settings.downloadDirectory);
    else o.erase("downloadDirectory");
    o.insert_or_assign("promptsForDownload", settings.promptsForDownload);
    o.insert_or_assign("includesSearchSuggestions", settings.includesSearchSuggestions);
    return json::Value(std::move(o));
}

std::optional<ProfileSettings> DecodeProfileSettings(const json::Value& v) {
    const json::Object* object = v.AsObject();
    if (!object) return std::nullopt;
    ProfileSettings settings;
    for (const auto& [key, value] : *object) {
        if (key == "downloadDirectory") {
            if (value.IsNull()) continue;
            const std::string* text = value.AsString();
            if (!text) return std::nullopt;
            settings.downloadDirectory = *text;
        } else if (key == "promptsForDownload" || key == "includesSearchSuggestions") {
            if (value.IsNull()) continue;  // decodeIfPresent: null is absent
            auto flag = value.AsBool();
            if (!flag) return std::nullopt;
            (key == "promptsForDownload" ? settings.promptsForDownload : settings.includesSearchSuggestions) = *flag;
        } else {
            settings.extra.emplace(key, value);
        }
    }
    return settings;
}

std::filesystem::path DefaultDownloadFolder(const std::optional<std::filesystem::path>& testDownloads, bool supportOverridden,
                                            bool quiet, const std::filesystem::path& support,
                                            const std::filesystem::path& userDownloads) {
    if (supportOverridden && testDownloads && testDownloads->is_absolute()) return *testDownloads;
    if (quiet) return support / "Downloads";
    return userDownloads;
}

bool IsTestProfile(const std::filesystem::path& support, const std::optional<std::filesystem::path>& localAppData) {
    if (!localAppData || localAppData->empty()) return true;
    const std::filesystem::path real = *localAppData / "Kite";
    std::error_code error;
    if (std::filesystem::equivalent(support, real, error) && !error) return false;
    return std::filesystem::absolute(support, error).lexically_normal() != std::filesystem::absolute(real, error).lexically_normal();
}

// MARK: BrowserState (ProfileSettings.swift's extension, Profiles.swift's profile(_:))

std::string BrowserState::DataStoreID(const std::optional<std::string>& directory) const {
    if (!directory) return kDefaultDataStoreID;
    if (auto profiles = extra.find("profiles"); profiles != extra.end() && profiles->second.AsArray()) {
        for (const auto& profile : *profiles->second.AsArray()) {
            const json::Value* folder = profile.Find("directory");
            if (!folder || !folder->AsString() || *folder->AsString() != *directory) continue;
            const json::Value* id = profile.Find("dataStoreID");
            if (auto normalized = id && id->AsString() ? NormalizeUuid(*id->AsString()) : std::nullopt) return *normalized;
            break;
        }
    }
    return kDefaultDataStoreID;
}

ProfileSettings BrowserState::Settings(const std::optional<std::string>& directory) const {
    auto it = profileSettings.find(DataStoreID(directory));
    return it == profileSettings.end() ? ProfileSettings{} : it->second;
}

void BrowserState::UpdateSettings(const std::optional<std::string>& directory, const std::function<void(ProfileSettings&)>& change) {
    const std::string key = DataStoreID(directory);
    ProfileSettings settings = Settings(directory);
    change(settings);
    if (settings.IsDefault()) profileSettings.erase(key);
    else profileSettings[key] = std::move(settings);
}

}  // namespace kite
