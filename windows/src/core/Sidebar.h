#pragma once
// The sidebar's model: what its space page lists and where each row sits, and what the address
// field and favicons show. Ports the Mac's SidebarSpaceList.buildRows and SidebarRowModel
// (SidebarList.swift), BrowserState's Collapse Pinned Tabs (BrowserState+ArcCommands.swift),
// FaviconSource (SidebarKit.swift), the header's address text (SidebarHeader.swift) and
// ArcMetrics.Sidebar. The shell draws it (shell/SidebarView).

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Models.h"

namespace kite {

// The rows' geometry from ArcMetrics.Sidebar, in points (the view keeps the rest of it).
namespace sidebar_metrics {
constexpr float kHeaderHeight = 36;
constexpr float kListTopSpacer = 3;
constexpr float kRowPitch = 41;
constexpr float kDividerRowHeight = 25;
}  // namespace sidebar_metrics

// View → Collapse Pinned Tabs, per space: the Mac's spacesWithCollapsedPinnedSections, which
// the session keeps (BrowserState.extra) under that name.
bool IsPinnedSectionCollapsed(const BrowserState& state, const std::string& spaceID);
void TogglePinnedSection(BrowserState& state, const std::string& spaceID);
// The pinned items the sidebar lists for a space. Collapsed, only the selected pinned tab stays
// (lifted out of its folder), the way a collapsed folder keeps its selected tab.
std::vector<PinnedItem> ShownPinnedItems(const BrowserState& state, const Space& space);

// Kite's own pages (kite://NAME, the Mac's InternalPage), which show a symbol for a favicon.
enum class InternalPage { History, Archive, SiteSettings, Settings, SearchEngines };
std::optional<InternalPage> InternalPageOf(const std::optional<std::string>& url);

// What a tab's favicon shows (the Mac's FaviconSource): the page's reported icon, else the
// site's /favicon.ico (so a tab that hasn't loaded still gets one), and a symbol for Kite's own
// pages. Neither: the globe.
struct FaviconSource {
    std::optional<std::string> url;
    std::optional<InternalPage> symbol;
    bool operator==(const FaviconSource&) const = default;
};
FaviconSource FaviconSourceOf(const std::optional<std::string>& page, const std::optional<std::string>& icon);

// Whether a favicon's bytes are an SVG document rather than a bitmap (the Mac's NSImage reads
// both): markup that starts with an element, with an <svg> near the start.
bool LooksLikeSvg(std::string_view bytes);

// The address field's text: the selected tab's host, else the Mac's "Search or enter URL".
std::string AddressFieldText(const BrowserState& state);

// One row of a space's page (the Mac's SidebarRowModel), top to bottom.
struct SidebarRow {
    enum class Kind { Header, Tab, Folder, Divider, NewTab };
    Kind kind = Kind::Tab;
    std::string id;     // the tab's or folder's; the space's for the header, divider and New Tab
    int depth = 0;      // folder levels above a pinned row
    std::string title;  // the space's name, the tab's DisplayTitle, the folder's name, "New Tab"
    // Header: the space's icon (an emoji, "symbol:NAME", "image:FILE" or empty), whether it has
    // pinned items, and whether they're collapsed.
    std::string icon;
    bool hasPinned = false;
    bool pinnedCollapsed = false;
    // Tab.
    bool pinned = false;
    bool selected = false;
    FaviconSource favicon;
    // Folder.
    bool expanded = true;
    // Divider: drawn only under pinned items.
    bool showsLine = false;
    // Where it sits: its top from the top of the space's page, and its height, in points.
    float top = 0;
    float height = 0;

    bool operator==(const SidebarRow&) const = default;
};

// The rows of space `space`: its header, the shown pinned items (folders open, or showing
// just their selected tab), the divider when there's anything to divide, New Tab, then the
// space's own tabs. Not yet: splits as one row, Tidy Tabs' group headers, live folders and
// Instant Links (the checkpoints that bring them add their rows).
std::vector<SidebarRow> SidebarRows(const BrowserState& state, size_t space);

}  // namespace kite
