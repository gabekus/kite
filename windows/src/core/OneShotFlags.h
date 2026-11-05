#pragma once
// Kite's one-shot flags (KiteCore's OneShotFlags.swift): things it asks or shows once, such as the
// favorites tray's empty state. The Mac keeps them in UserDefaults on a real profile and in
// "One-Shot Flags.plist" in a test profile's folder (a binary property list of names to booleans,
// as PropertyListEncoder writes it). Windows has no UserDefaults, so every profile keeps them in
// that file, in the Mac's format: a test profile reads the same file on both.

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
    // Sets a flag and writes the file (atomically: a temporary file moved over it). An error
    // string when it couldn't be written; the flag holds for this run either way.
    std::string Set(const std::string& key, bool value);

    // A binary property list (bplist00) whose top object is a dictionary of strings to booleans;
    // none for anything else (other value types are skipped, as [String: Bool] won't decode them
    // on the Mac either: there the whole read fails, here the rest are kept).
    static std::optional<std::map<std::string, bool>> Parse(std::string_view bytes);
    static std::string Write(const std::map<std::string, bool>& flags);

private:
    std::filesystem::path file_;
    std::map<std::string, bool> flags_;
};

}  // namespace kite
