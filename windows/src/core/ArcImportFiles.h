#pragma once
// Import from Arc's other files, next to the sidebar. Ports KiteCore's ArcArchiveImport.swift
// (StorableArchiveItems.json), ArcSettingsImport.swift (Arc's settings), ArcKeyBindingsImport.swift
// (StorableKeyBindings.json), ArcLinkRoutingImport.swift (StorableLinkRouting.json), and the
// readers in KiteMac's ArcSiteSearchImport.swift (Site Search, in the profile's "Web Data") and
// ArcImportController.readProfileNames (Arc's profile names, in "Local State").
//
// Delete with ArcImport.h once Arc has shut down.

#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "core/AirTrafficControl.h"
#include "core/Json.h"
#include "core/KeyBindings.h"
#include "core/Models.h"
#include "core/SiteSearch.h"

namespace kite::arc_import {

// MARK: Archive (ArcArchiveImport.swift)

// Archived tabs from Little Arc, or with no space, have no space to go back to.
inline constexpr const char* kNoSpace = "00000000-0000-0000-0000-000000000000";
// Oldest archived first, like Kite's own archive. Entries Kite can't read are skipped.
std::vector<ClosedTab> ParseArchive(std::string_view text);
// BrowserState.mergeArchive(imported:): Arc's archived tabs go before Kite's own (they're older),
// skipping ones imported before; past the archive's limit the oldest go. Returns how many of
// them are in the archive now.
int MergeArchive(BrowserState& state, const std::vector<ClosedTab>& imported);

// MARK: Settings (ArcSettingsImport.swift)

struct Settings {
    std::optional<bool> warnsBeforeQuitting;             // shouldWarnBeforeQuitting
    std::optional<bool> opensExternalLinksInLittleKite;  // openExternalLinksInLittleBrowserEnabled
    std::optional<std::string> archiveAfter;             // the default profile's auto-archive threshold

    bool IsEmpty() const { return !warnsBeforeQuitting && !opensExternalLinksInLittleKite && !archiveAfter; }
    // The settings' names in Arc's words, for the summary.
    std::vector<std::string> Names() const;
    // `defaults` is Arc's defaults as an object (its plist).
    static Settings FromDefaults(const json::Value& defaults);
    bool operator==(const Settings&) const = default;
};
// Arc's autoArchiveTimeThresholdsPerProfile: a JSON string, {"thresholds": [profile, threshold,
// ...]}. The default profile's threshold, else the first there is; none for Arc's default
// (an empty list) or anything unreadable.
std::optional<std::string> ArchiveInterval(const json::Value& raw);
// "1 hour", as ArchiveInterval.title.
std::string ArchiveIntervalTitle(std::string_view raw);
// BrowserState.apply(_ settings:): the ones the session keeps (Little Kite's is the app's).
void Apply(BrowserState& state, const Settings& settings);

// MARK: Key bindings (ArcKeyBindingsImport.swift)

// One override per changed action. Arc's `unset` state means the user removed the shortcut;
// `valid` holds the new one. nullopt when the file doesn't decode as Arc's (JSONDecoder's
// strictness: one malformed override and none import).
std::optional<std::vector<KeyBindingOverride>> ParseKeyBindings(std::string_view text);
// Arc's stored shortcut as Kite's, or none for one Kite can't use.
std::optional<KeyShortcut> ArcShortcut(const std::string& keyEquivalent, int64_t flags);

// MARK: Air Traffic Control (ArcLinkRoutingImport.swift)

struct LinkRouting {
    std::vector<air_traffic::Rule> rules;
    // Arc's default when it's a space. A Little Arc or most-recent default is the Little Kite
    // setting instead (defaultOpensInLittleKite).
    std::optional<std::string> defaultSpace;
    std::optional<bool> defaultOpensInLittleKite;
    int profileRoutes = 0;  // routes to an Arc profile, which Kite's can't open in
    int unreadable = 0;     // routes Kite couldn't read

    bool IsEmpty() const { return rules.empty() && !defaultSpace && !defaultOpensInLittleKite; }
    // Leaves out routes to spaces Kite doesn't have.
    LinkRouting Keeping(const std::set<std::string>& spaceIDs) const;
    bool operator==(const LinkRouting&) const = default;
};
std::optional<LinkRouting> ParseLinkRouting(std::string_view text);
// Little Arc opens in Little Kite; a space keeps Arc's id, which imported spaces keep too.
std::optional<air_traffic::Destination> ArcDestination(const json::Value* raw);
// Adds Arc's routes after Kite's own, replacing one imported before (same id), and takes Arc's
// default when it's a space. Returns how many routes were new.
int Merge(air_traffic::State& state, const LinkRouting& imported);

// MARK: Site Search (KiteMac's ArcSiteSearchImport.swift)

// The shortcuts the user added or turned on in a Chromium "Web Data" database, oldest first.
// Chromium's built-in engines are left out. nullopt when it isn't a database with keywords.
std::optional<std::vector<SiteSearch>> ParseSiteSearches(std::string_view webData);

// MARK: Profile names (ImportProfiles.chromium(localState:))

// Arc's profile names by folder, from Chromium's Local State (profile.info_cache); a profile
// with no name has its folder's.
std::map<std::string, std::string> ParseProfileNames(std::string_view localState);

}  // namespace kite::arc_import
