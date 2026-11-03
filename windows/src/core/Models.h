#pragma once
// Kite's browser model, the C++ counterpart of KiteCore's Models.swift and BrowserState.swift.
//
// session.json is the contract with the Mac app: every type reads and writes the Mac's
// JSON (Swift Codable) shape, and keeps members it doesn't model yet in `extra`, so a
// session that goes Mac → Windows → Mac loses nothing.
//
// Ported so far: tabs, folders, spaces, themes, favorites per profile, selection,
// opening, selecting, closing, archiving and reopening tabs (TabClosing.cpp), spaces, and
// splits as data (closing keeps them whole). Not yet: making splits, profiles, live folders,
// Tidy Tabs. Those arrive as Helix checkpoints (docs/helix.md).

#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "core/Json.h"

namespace kite {

// Seconds since 2001-01-01 00:00:00 UTC: Foundation's Date encoding (timeIntervalSinceReferenceDate).
using Timestamp = double;
Timestamp Now();
// Unix seconds → Foundation reference-date seconds.
constexpr Timestamp FromUnixTime(double unixSeconds) { return unixSeconds - 978307200.0; }

struct Tab {
    std::string id;
    std::optional<std::string> url;
    std::string title;
    std::optional<std::string> faviconURL;
    Timestamp lastActiveAt = 0;
    std::optional<std::string> pinnedURL;
    std::optional<std::string> customTitle;
    std::optional<bool> splitPane;
    json::Object extra;

    // Rename, then the page's title, then the host, then the URL, then "New Tab".
    std::string DisplayTitle() const;
    // A tab that never had a page (no address, or about:blank, and no pinned one either): a
    // split pane nobody filled. Closing a pinned one removes it (PinnedURL.swift's isBlank).
    bool IsBlank() const;
    bool operator==(const Tab&) const = default;
};

struct PinnedItem;

struct Folder {
    std::string id;
    std::string name;
    bool isExpanded = true;
    std::vector<PinnedItem> items;
    std::optional<json::Value> live;  // LiveFolders.swift, not ported yet
    std::optional<bool> ephemeral;
    json::Object extra;

    bool operator==(const Folder&) const;
};

// The pinned section is a tree of tabs and (nestable) folders.
struct PinnedItem {
    std::variant<Tab, Folder> value;

    const std::string& Id() const;
    bool operator==(const PinnedItem&) const;
};

// Every tab in sidebar order, depth first. The pointers stay valid until the tree changes.
std::vector<const Tab*> TabsIn(const std::vector<PinnedItem>& items);
const Tab* FindTab(const std::vector<PinnedItem>& items, const std::string& id);
Tab* FindTab(std::vector<PinnedItem>& items, const std::string& id);

struct ThemeColor {
    float r = 0, g = 0, b = 0;  // sRGB, 0...1
    bool operator==(const ThemeColor&) const = default;
    static ThemeColor FromHex(uint32_t hex);
};

struct Theme {
    static constexpr size_t kMaxColors = 4;
    static constexpr float kDefaultTint = 0.55f;

    // Never empty (the Mac's Theme.init requires a colour); the first preset's by default.
    std::vector<ThemeColor> colors{{0.1f, 0.1f, 0.1f}};
    float grain = 0.35f;
    float tint = kDefaultTint;

    // Clamps like the Mac's Theme.init: at most four colors, grain and tint in 0...1. Where the
    // Mac traps on no colours, this keeps the default colour.
    static Theme Make(std::vector<ThemeColor> colors, float grain = 0.35f, float tint = kDefaultTint);
    static const std::vector<Theme>& Presets();
    bool operator==(const Theme&) const = default;
};

// Tabs shown side by side in one sidebar row (SplitView.swift). The members stay in their
// space's pinned or unpinned list; the split only groups them. Windows doesn't make or show
// splits yet: it keeps them whole when a member closes (NormalizeSplits).
struct SplitView {
    std::string id;
    std::vector<std::string> tabIDs;     // pane order
    std::vector<double> widthFactors;    // each pane's share, summing to 1
    std::string orientation = "horizontal";
    std::optional<std::string> expandedTabID;
    json::Object extra;

    // `widthFactors` when they fit the panes and are all positive (scaled to sum to 1), else
    // equal shares.
    std::vector<double> NormalizedFactors() const;
    // Drops a pane, giving its share to the others in proportion (SplitView.remove).
    void Remove(const std::string& tabID);
    bool operator==(const SplitView&) const = default;
};

struct Space {
    std::string id;
    std::string name;
    std::string icon;  // emoji, "symbol:NAME", "image:FILE" or empty
    Theme theme;
    std::vector<PinnedItem> pinnedItems;
    std::vector<Tab> tabs;  // unpinned, newest first
    std::optional<std::string> selectedTabID;
    std::vector<SplitView> splits;
    json::Object extra;  // tabGroups, profile, about

    std::vector<const Tab*> Pinned() const { return TabsIn(pinnedItems); }
    // Sidebar order: pinned, then unpinned.
    std::vector<const Tab*> AllTabs() const;
    bool operator==(const Space&) const = default;
};

// Why a tab went into the archive (Archive.swift's ArchiveReason).
enum class ArchiveReason { Manual, Auto };

// A tab that was closed: in Recently Closed (Ctrl+Shift+T) and in the archive (ClosedTab).
struct ClosedTab {
    Tab tab;
    std::string spaceID;
    long long index = 0;  // where it was in its space's unpinned tabs
    std::optional<Timestamp> archivedAt;     // none for entries from before Kite kept it
    std::optional<ArchiveReason> reason;     // likewise
    std::optional<bool> littleKite;          // a Little Kite window's page, not a sidebar tab
    json::Object extra;
    bool operator==(const ClosedTab&) const = default;
};

// What closing a tab did (BrowserState.close's CloseOutcome): an unpinned tab (or a blank or
// split-pane pinned one) is removed and archived; a pinned tab or favorite stays as a row and
// only loses its page.
enum class CloseOutcome { NotFound, Removed, Unloaded };

enum class TabSection { Favorite, Pinned, Unpinned };

struct TabLocation {
    std::optional<size_t> space;  // none for favorites, which belong to no space
    TabSection section;
    size_t index;
};

struct BrowserState {
    std::vector<Space> spaces;  // never empty
    std::string selectedSpaceID;
    static constexpr const char* kDefaultProfile = "Default";  // Profile.defaultDirectory
    // Favorites grids by Chromium profile folder; an empty grid has no entry, as on the Mac.
    std::map<std::string, std::vector<Tab>> favoritesByProfile;
    // Favorite splits by profile folder, like the grids.
    std::map<std::string, std::vector<SplitView>> favoriteSplitsByProfile;
    std::vector<ClosedTab> recentlyClosed;  // oldest first, at most kRecentlyClosedLimit
    std::vector<ClosedTab> archived;        // oldest first, at most kArchiveLimit
    static constexpr size_t kRecentlyClosedLimit = 25;
    static constexpr size_t kArchiveLimit = 500;
    // "Archive tabs after" (ArchiveInterval's raw value): never, oneHour, sixHours,
    // twelveHours (the default, as Arc's), twentyFourHours, sevenDays, thirtyDays.
    std::string archiveAfter = "twelveHours";
    std::string searchEngine = "google";
    json::Object extra;  // everything else the Mac stores

    // Personal (with one tab when seedURL is set) and Work, like BrowserState.makeDefault().
    static BrowserState MakeDefault(std::optional<std::string> seedURL = std::string("https://www.wikipedia.org"));

    // The profile folder a space uses: its `profile` when that profile still exists, else Default.
    std::string ProfileDirectory(size_t space) const;
    std::string SelectedProfileDirectory() const { return ProfileDirectory(SelectedSpaceIndex()); }
    // The favorites grid of the current space's profile, shown above the pinned tabs.
    const std::vector<Tab>& Favorites() const;
    void SetFavorites(std::vector<Tab> tabs);

    size_t SelectedSpaceIndex() const;
    const Space& SelectedSpace() const { return spaces[SelectedSpaceIndex()]; }
    const Tab* SelectedTab() const;
    // Favorites, then the space's pinned and unpinned tabs.
    std::vector<const Tab*> SidebarTabs(size_t space) const;
    std::optional<size_t> SpaceIndex(const std::string& id) const;
    std::optional<TabLocation> Location(const std::string& id) const;
    const Tab* FindTabByID(const std::string& id) const;

    // New tabs go to the top of the unpinned list.
    std::string OpenTab(std::optional<std::string> url, std::optional<std::string> spaceID = std::nullopt,
                        bool select = true, Timestamp now = Now(), std::string id = {});
    // Favorites open in the current space; other tabs switch to their own space.
    void Select(const std::string& tabID, Timestamp now = Now());
    void SelectSpace(const std::string& id);
    void SelectAdjacentSpace(int offset);
    // Opens or closes a pinned folder, at any depth in any space.
    void SetFolderExpanded(const std::string& folderID, bool expanded);
    std::string AddSpace(std::string name, std::string icon, Theme theme);

    // MARK: Closing, archiving and reopening (TabClosing.cpp, BrowserState.swift)

    // Closes a tab: an unpinned one goes to Recently Closed and the archive; a pinned tab or
    // favorite only unloads, unless it closes for good. A selected tab hands the selection to
    // its split neighbour, else to the tab that slides into its place, else the one above.
    CloseOutcome Close(const std::string& tabID);
    // A pinned tab or favorite that closing removes rather than unloads: a split pane, or a
    // tab that never had a page.
    bool ClosesForGood(const std::string& tabID) const;
    // Whether its sidebar row shows the close button: not for tabs Claude opened in its
    // folders (Claude closes them), unless they close for good.
    bool ShowsCloseButton(const std::string& tabID) const;
    // Whether the tab sits directly in one of Claude's folders (Folder::ephemeral).
    bool IsInEphemeralFolder(const std::string& tabID) const;
    // Removes a pinned tab without archiving it; with `droppingEmptyFolder`, a folder it
    // leaves empty goes too, and Claude folders left empty after that.
    bool RemovePinnedTab(const std::string& tabID, bool droppingEmptyFolder = false);
    // Ctrl+Shift+T: the last closed tab back where it was, selected. Its id, or none.
    std::optional<std::string> ReopenLastClosed(Timestamp now = Now());
    // Undo Archive Tab: that tab back, if it's still among the recently closed.
    std::optional<std::string> ReopenClosed(const std::string& tabID, Timestamp now = Now());
    // Unpinned tabs (and tabs in Claude's folders) untouched for `interval` seconds go to the
    // archive, except each space's selected tab. Returns the tabs that went.
    std::vector<Tab> ArchiveStaleTabs(double interval, Timestamp now = Now());
    // archiveAfter in seconds; none for never (or a value this build doesn't know).
    std::optional<double> ArchiveAfterSeconds() const;
    // A page that closed itself (window.close() after a sign-in): its tab closes, and a popup
    // that was on screen hands it back to the tab that opened it, as the Mac's PagePool does.
    void PageClosedItself(const std::string& tabID, const std::optional<std::string>& openerTabID);
    // Adds to the archive, stamped with when and why, dropping the oldest past kArchiveLimit.
    void AppendToArchive(std::vector<ClosedTab> tabs, ArchiveReason reason = ArchiveReason::Manual, Timestamp now = Now());
    // Splits keep only members that exist, each tab in one split, two panes or more.
    void NormalizeSplits();
    // The split holding a tab: its space (the selected one for a favorite split) and itself.
    const SplitView* SplitContaining(const std::string& tabID) const;

    bool operator==(const BrowserState&) const = default;

    const Tab* TabAt(const TabLocation& location) const;
    Tab* TabAt(const TabLocation& location);
};

// MARK: JSON (the Mac's Codable shapes)

json::Value Encode(const Tab&);
json::Value Encode(const Folder&);
json::Value Encode(const PinnedItem&);
json::Value Encode(const Theme&);
json::Value Encode(const Space&);
json::Value Encode(const BrowserState&);
json::Value Encode(const SplitView&);
json::Value Encode(const ClosedTab&);

// nullopt when a required member is missing or has the wrong type.
std::optional<Tab> DecodeTab(const json::Value&);
std::optional<PinnedItem> DecodePinnedItem(const json::Value&);
std::optional<Theme> DecodeTheme(const json::Value&);
std::optional<Space> DecodeSpace(const json::Value&);
std::optional<SplitView> DecodeSplitView(const json::Value&);
std::optional<ClosedTab> DecodeClosedTab(const json::Value&);
std::optional<BrowserState> DecodeBrowserState(const json::Value&);

}  // namespace kite
