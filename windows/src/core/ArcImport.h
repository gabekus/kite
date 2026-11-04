#pragma once
// Import from Arc: spaces, pinned tabs, folders, split views, favorites, themes and profiles
// from Arc's StorableSidebar.json, into the session. Ports KiteCore's ArcImport.swift (and
// BrowserImport.merge(imported:), which it uses), case for case.
//
// Arc shuts down on 2026-12-22. Delete this with the other ArcImport* files some time after.
//
// The format is undocumented, so parsing is deliberately loose, as the Mac's: unknown item
// kinds are skipped and reported rather than failing the whole import. Arc for Windows writes
// the Mac's shape with two differences, both read here: a space's container ids may come as
// `newContainerIDs` (`[{"pinned": {}}, id, {"unpinned": {...}}, id]`) next to or instead of
// `containerIDs`, and its icon may be `customInfo.iconType.icon`, a name from Arc's icon set,
// rather than an emoji.

#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "core/Models.h"

namespace kite::arc_import {

struct Result {
    // Each space's extra "profile" is still Arc's profile folder ("Profile 1"; absent for Arc's
    // Default): MergeArc maps it to a Kite profile.
    std::vector<Space> spaces;
    // Arc's favorites grid for Default and each profile the spaces use, by Arc profile folder.
    std::map<std::string, std::vector<Tab>> favoritesByProfile;
    // Arc profile folders, in the order the spaces use them.
    std::vector<std::string> profiles;
    int tabCount = 0;  // every tab read, favorites included
    int folderCount = 0;
    int splitCount = 0;
    // Spaces Arc had no name for (shown as "Arc Space"): often leftovers the user never set up.
    std::set<std::string> untitledSpaceIDs;
    // Sidebar item kinds Kite skipped ("easel"), with how many of each.
    std::map<std::string, int> skippedKinds;
    // Spaces whose Arc icon Kite has no match for (an Arc for Windows icon name), given a stand-in.
    int iconsReplaced = 0;
    // Things that didn't carry over exactly, in plain words for the user.
    std::vector<std::string> notes;

    // Every profile's favorites, in profile order.
    std::vector<Tab> Favorites() const { return FavoritesIn(profiles); }
    // The favorites of `profiles` and Default, the ones an import of those profiles' spaces brings.
    std::vector<Tab> FavoritesIn(const std::vector<std::string>& profiles) const;
    // The profiles of the spaces that import unless the user includes the unnamed ones.
    std::vector<std::string> NamedSpaceProfiles() const;
};

// Default, which Kite always has, then `profiles`, without repeats.
std::vector<std::string> WithDefault(std::vector<std::string> profiles);

enum class Failure {
    NotJSON,        // not JSON at all, or cut short
    NotArcSidebar,  // JSON, but not a sidebar
    NoSpaces,
};
const char* Name(Failure failure);

std::variant<Result, Failure> Parse(std::string_view text, Timestamp now = Now());

// The sidebar files to try from a listing of Arc's folder: StorableSidebar.json (even when the
// folder couldn't be listed), then Arc's dated backups of it, newest first.
std::vector<std::string> SidebarCandidates(const std::vector<std::string>& fileNames);
// Whether a backup should be tried after the current file failed: it couldn't be read, or
// wasn't a whole sidebar. A sidebar with no spaces is what Arc has now, so no backup then.
// `failure` none: the file couldn't be read at all.
bool TriesBackup(std::optional<Failure> failure);
// When Arc made a dated backup, from its name (yyyy-MM-dd-HH-mm-ss-SSS, local time).
std::optional<Timestamp> BackupDate(std::string_view fileName);
// Fills in panes without a stored width; none (equal widths) if the stored ones don't add up.
std::optional<std::vector<double>> SplitWidthFactors(const std::vector<std::optional<double>>& known);

// Foundation's URL(string:) accepting the text, as far as the session needs it: a URL the
// Mac's decoder would refuse must never reach session.json.
bool IsURL(std::string_view text);

}  // namespace kite::arc_import

namespace kite {

// What an Arc import did. `profiles` maps each Arc profile folder it brought (Default and those
// the imported spaces use) to the Kite profile folder that holds it now.
struct ArcMerge {
    int added = 0;
    int updated = 0;
    std::map<std::string, std::string> profiles;
    std::vector<std::string> newProfiles;  // Kite profiles the import made, in order
    // Arc profiles put in Kite's Default only because no Kite profile could be made for them.
    std::set<std::string> fellBack;
    // Favorites the import added to the grids.
    int favoritesAdded = 0;
    bool operator==(const ArcMerge&) const = default;
};

// An Arc profile's name from Arc's `Local State`, or its folder's when it has none.
std::string ArcProfileName(const std::string& directory, const std::map<std::string, std::string>& names);
// The Kite profile each Arc profile folder goes to, for those that already have one: Arc's
// Default is Kite's; then the profile an earlier import put it in, while it exists; then one
// with the same name. The rest get a new profile.
std::map<std::string, std::string> ExistingProfilesForArc(const BrowserState& state, const std::vector<std::string>& directories,
                                                            const std::map<std::string, std::string>& names);
// Adds spaces and favorites from Arc, making a Kite profile for each Arc profile that has none
// yet (BrowserState.mergeArc). A space imported before (same id) is replaced, but stays in the
// profile it's in now once an import has placed its Arc profile.
ArcMerge MergeArc(BrowserState& state, const std::vector<Space>& imported,
                  const std::map<std::string, std::vector<Tab>>& favoritesByProfile = {},
                  const std::map<std::string, std::string>& profileNames = {});
// BrowserImport.merge(imported:): replaces spaces with the same id, appends the rest, selects
// the first, then gives pinned tabs and favorites their pinned URL. Returns added and updated.
std::pair<int, int> MergeImported(BrowserState& state, const std::vector<Space>& imported);
// PinnedURL.swift's syncPinnedURLs: a pinned tab or favorite without a pinned URL takes the
// page it's on (not about:blank or one of Kite's own pages).
void SyncPinnedURLs(BrowserState& state);

}  // namespace kite
