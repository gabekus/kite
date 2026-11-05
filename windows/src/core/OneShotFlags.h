#pragma once
// Kite's one-shot flags (KiteCore's OneShotFlags.swift): things it asks or shows once, such as the
// favorites tray's empty state. The Mac keeps them in UserDefaults on a real profile and in
// "One-Shot Flags.plist" in a test profile's folder (a binary property list of names to booleans,
// as PropertyListEncoder writes it). Windows has no UserDefaults, so every profile keeps them in
// that file, in the Mac's format: a test profile reads the same file on both, and
// Tests/Fixtures/one-shot-flags.plist is one both test suites read.

#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace kite {

class OneShotFlags {
public:
    static constexpr const char* kFileName = "One-Shot Flags.plist";
    // The favorites tray's empty state was dismissed (FavoritesTrayView.emptyStateDismissedKey).
    static constexpr const char* kFavoritesEmptyStateDismissed = "favoritesEmptyStateDismissed";

    // The flags in `folder` (a profile's): none set when the file is missing or unreadable, as the
    // Mac's read gives [:].
    static OneShotFlags Load(const std::filesystem::path& folder);
    bool Get(const std::string& key) const;
    // Sets a flag and writes the file (atomically: a temporary file moved over it), as
    // SessionStore::Save writes. An error string naming the file when it couldn't be written; the
    // flag holds for this run either way.
    std::string Set(const std::string& key, bool value);

    // A binary property list (bplist00) whose top object is a dictionary of strings to booleans.
    // None for anything else, and none when any value isn't a boolean: the Mac's PropertyListDecoder
    // fails to decode [String: Bool] then, and its read gives no flags at all.
    static std::optional<std::map<std::string, bool>> Parse(std::string_view bytes);
    // None when a key isn't valid UTF-8 (a property list's strings are Unicode).
    static std::optional<std::string> Write(const std::map<std::string, bool>& flags);

private:
    std::filesystem::path file_;
    std::map<std::string, bool> flags_;
};

}  // namespace kite
