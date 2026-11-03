#pragma once
// Kite's browser model, the C++ counterpart of KiteCore's Models.swift and BrowserState.swift.
//
// session.json is the contract with the Mac app: every type reads and writes the Mac's
// JSON (Swift Codable) shape, and keeps members it doesn't model yet in `extra`, so a
// session that goes Mac → Windows → Mac loses nothing.
//
// Ported so far: tabs, folders, spaces, themes, favorites (default profile), selection,
// opening and selecting tabs, spaces. Not yet: closing/archiving, splits, profiles,
// live folders, Tidy Tabs. Those arrive as Helix checkpoints (docs/helix.md).

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

// Every tab in sidebar order, depth first.
std::vector<Tab> TabsIn(const std::vector<PinnedItem>& items);
Tab* FindTab(std::vector<PinnedItem>& items, const std::string& id);

struct ThemeColor {
    float r = 0, g = 0, b = 0;  // sRGB, 0...1
    bool operator==(const ThemeColor&) const = default;
    static ThemeColor FromHex(uint32_t hex);
};

struct Theme {
    static constexpr size_t kMaxColors = 4;
    static constexpr float kDefaultTint = 0.55f;

    std::vector<ThemeColor> colors;
    float grain = 0.35f;
    float tint = kDefaultTint;

    // Clamps like the Mac's Theme.init: at most four colors, grain and tint in 0...1.
    static Theme Make(std::vector<ThemeColor> colors, float grain = 0.35f, float tint = kDefaultTint);
    static const std::vector<Theme>& Presets();
    bool operator==(const Theme&) const = default;
};

struct Space {
    std::string id;
    std::string name;
    std::string icon;  // emoji, "symbol:NAME", "image:FILE" or empty
    Theme theme;
    std::vector<PinnedItem> pinnedItems;
    std::vector<Tab> tabs;  // unpinned, newest first
    std::optional<std::string> selectedTabID;
    json::Object extra;  // splits, tabGroups, profile, about

    std::vector<Tab> Pinned() const { return TabsIn(pinnedItems); }
    // Sidebar order: pinned, then unpinned.
    std::vector<Tab> AllTabs() const;
    bool operator==(const Space&) const = default;
};

enum class TabSection { Favorite, Pinned, Unpinned };

struct TabLocation {
    std::optional<size_t> space;  // none for favorites, which belong to no space
    TabSection section;
    size_t index;
};

struct BrowserState {
    std::vector<Space> spaces;  // never empty
    std::string selectedSpaceID;
    std::vector<Tab> favorites;  // the default profile's grid
    std::string searchEngine = "google";
    json::Object extra;  // everything else the Mac stores

    // Personal (with one tab when seedURL is set) and Work, like BrowserState.makeDefault().
    static BrowserState MakeDefault(std::optional<std::string> seedURL = std::string("https://www.wikipedia.org"));

    size_t SelectedSpaceIndex() const;
    const Space& SelectedSpace() const { return spaces[SelectedSpaceIndex()]; }
    const Tab* SelectedTab() const;
    // Favorites, then the space's pinned and unpinned tabs.
    std::vector<Tab> SidebarTabs(size_t space) const;
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
    std::string AddSpace(std::string name, std::string icon, Theme theme);

    bool operator==(const BrowserState&) const = default;

private:
    Tab* MutableTab(const TabLocation& location);
};

// MARK: JSON (the Mac's Codable shapes)

json::Value Encode(const Tab&);
json::Value Encode(const Folder&);
json::Value Encode(const PinnedItem&);
json::Value Encode(const Theme&);
json::Value Encode(const Space&);
json::Value Encode(const BrowserState&);

// nullopt when a required member is missing or has the wrong type.
std::optional<Tab> DecodeTab(const json::Value&);
std::optional<PinnedItem> DecodePinnedItem(const json::Value&);
std::optional<Theme> DecodeTheme(const json::Value&);
std::optional<Space> DecodeSpace(const json::Value&);
std::optional<BrowserState> DecodeBrowserState(const json::Value&);

}  // namespace kite
