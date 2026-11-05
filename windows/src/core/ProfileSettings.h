#pragma once
// Settings Arc keeps per profile, beside its search engine: a port of KiteCore's
// ProfileSettings.swift (Arc's profile preferences `downloadFilePath`,
// `promptForDownloadFilePath`, `searchSuggestEnabled`; Chromium keeps the same three as
// `download.default_directory`, `download.prompt_for_download` and `search.suggest_enabled`).
//
// session.json keeps them under `profileSettings`, keyed by the profile's dataStoreID (the
// default profile's is the zero UUID), written only for a profile whose settings aren't the
// defaults. BrowserState::Settings and UpdateSettings (Models.h) read and change them, as the
// Mac's BrowserState extension does.

#include <filesystem>
#include <functional>
#include <optional>
#include <string>

#include "core/Json.h"

namespace kite {

struct ProfileSettings {
    // The folder downloads save into; none is the user's Downloads folder.
    std::optional<std::string> downloadDirectory;
    // Arc's "Ask" choice: a save panel for every download, starting in the download folder.
    bool promptsForDownload = false;
    // "Include search engine suggestions" (the command bar asks the engine as you type). On by
    // default, as in Arc.
    bool includesSearchSuggestions = true;
    // Members the Mac may add that Windows doesn't know, written back unchanged.
    json::Object extra;

    // The folder to save into: the chosen one while it still exists (`exists`), else `downloads`.
    std::filesystem::path DownloadFolder(const std::filesystem::path& downloads,
                                         const std::function<bool(const std::string&)>& exists) const;

    // Whether these are Arc's defaults, which session.json doesn't store (members Windows
    // doesn't know don't count, as the Mac compares only its own).
    bool IsDefault() const;
    bool operator==(const ProfileSettings&) const = default;
};

json::Value Encode(const ProfileSettings&);
// Swift's decoder: each member optional, but one of the wrong type fails it (and with it the
// session, as the Mac's BrowserState decoder does).
std::optional<ProfileSettings> DecodeProfileSettings(const json::Value&);

// Profile.default's dataStoreID, which keys the default profile's settings.
inline constexpr const char* kDefaultDataStoreID = "00000000-0000-0000-0000-000000000000";

// Where downloads go when no folder was chosen (DownloadLocation.defaultFolder): a test run's
// own folder (KITE_TEST_DOWNLOADS_PATH, an absolute path, honoured only on a test profile, one
// that isn't %LOCALAPPDATA%\Kite, so a stray variable can't move a real profile's downloads),
// else the user's Downloads. A quiet run (Kite.exe's --smoke-test, --capture, --save-log, which
// need KITE_SUPPORT_PATH) without one saves into its profile's own Downloads folder, never the
// user's: on the Mac a throwaway profile without the variable still saves into ~/Downloads.
// `supportOverridden` is IsTestProfile's answer.
std::filesystem::path DefaultDownloadFolder(const std::optional<std::filesystem::path>& testDownloads, bool supportOverridden,
                                            bool quiet, const std::filesystem::path& support,
                                            const std::filesystem::path& userDownloads);

// Whether `support` is a test profile: anything but the default %LOCALAPPDATA%\Kite (Kite.exe and
// kitecore decide it the same way, from where the profile is).
bool IsTestProfile(const std::filesystem::path& support, const std::optional<std::filesystem::path>& localAppData);

}  // namespace kite
