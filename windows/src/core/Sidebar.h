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
#include "core/SpaceIcon.h"

namespace kite {

// The sidebar's layout from ArcMetrics.Sidebar, in points: where the rows, the address field and
// what takes clicks sit (the view keeps how they're painted).
namespace sidebar_metrics {
constexpr float kPadding = 8;  // the list, address field and pills sit this far in from each side
constexpr float kTopRowY = 7.5f;
constexpr float kTopRowHeight = 32;
constexpr float kUrlFieldTopGap = 6.5f;
constexpr float kUrlFieldHeight = 36;
constexpr float kUrlFieldTop = kTopRowY + kTopRowHeight + kUrlFieldTopGap;
// The header (top row and address field) the space's page starts under.
constexpr float kHeaderAreaHeight = kUrlFieldTop + kUrlFieldHeight;
constexpr float kBottomBarHeight = 50;  // the space bar, under the page
constexpr float kHeaderHeight = 36;
constexpr float kListTopSpacer = 3;
constexpr float kHeaderIconSize = 26;
constexpr float kHeaderIconTop = 5;
constexpr float kRowPitch = 41;
constexpr float kPillHeight = 36;
constexpr float kIconInset = 9;  // the favicon's leading edge in the pill
constexpr float kDividerRowHeight = 25;
constexpr float kCloseButtonSize = 24;      // a tab's close button (SidebarRowCell's place(close))
constexpr float kCloseButtonEndInset = 6;  // from the pill's end
// Back to Pinned URL (TabRowCell's reset): 24pt, left of the close button (place(reset)), the
// trailing gap (iconTextGap) after each.
constexpr float kResetButtonSize = 24;
constexpr float kTrailingGap = 8;
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
    SpaceIconLook look;  // what the icon shows (SpaceIconLookOf); `icon` is kept for kitecore
    bool hasPinned = false;
    bool pinnedCollapsed = false;
    // Tab.
    bool pinned = false;
    bool selected = false;
    bool showsClose = true;  // its close button shows on hover (BrowserState::ShowsCloseButton)
    // A pinned tab off its pinned page (Tab::HasLeftPinnedURL): Back to Pinned URL shows on hover
    // (SidebarSpaceList's canReset).
    bool canReset = false;
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

// Where the space's page sits, in points from the sidebar's top, for a sidebar `height` tall:
// from `listTop` (under the header, and the favorites when there are any: core/Favorites.h's
// SidebarListTop) down to the space bar (the Mac's list scroll view). It scrolls up to
// SidebarMaxScroll, so its last row can reach the bottom.
float SidebarListBottom(float height, float listTop = sidebar_metrics::kHeaderAreaHeight);
float SidebarContentHeight(const std::vector<SidebarRow>& rows);
float SidebarMaxScroll(const std::vector<SidebarRow>& rows, float height);
// The scroll limit on a display `scale` px a point, floored to whole pixels: scrolling stays
// on the pixel grid at the bottom too (a `scale` of 0 leaves it unfloored, as the two-argument one).
float SidebarMaxScroll(const std::vector<SidebarRow>& rows, float height, float scale,
                       float listTop = sidebar_metrics::kHeaderAreaHeight);

// What's under a point of a sidebar `width`×`height` points scrolled `scroll` down, its page
// starting at `listTop` (the Mac's
// hitTest and acceptsPress): the address field's text button, a row's pill (tabs, folders, New
// Tab), the space header (all of its cell) or its chevron (Collapse Pinned Tabs, while the space has
// pinned items), or a tab's close button. The divider and the space around pills take nothing.
struct SidebarHit {
    enum class Target { None, AddressField, Row, PinnedChevron, CloseButton, ResetButton };
    Target target = Target::None;
    size_t row = 0;  // Row, PinnedChevron, CloseButton and ResetButton: which row
    bool operator==(const SidebarHit&) const = default;
};
SidebarHit SidebarHitTest(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y,
                          float listTop = sidebar_metrics::kHeaderAreaHeight);
// The row whose bounds hold a point (its whole height across the list, as the Mac's cell), for
// a release that ends a press on it: a click is a tap only when it lets go inside its row.
std::optional<size_t> SidebarRowAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y,
                                   float listTop = sidebar_metrics::kHeaderAreaHeight);

// A press in the sidebar, held by what it pressed (not where: rows can move under it, as a
// Mac row cell stays its item's), and what letting go does (the Mac's mouseUp, tapped(at:)
// and the header's buttons).
struct SidebarPress {
    SidebarHit::Target target = SidebarHit::Target::None;
    SidebarRow::Kind kind = SidebarRow::Kind::Tab;  // all but AddressField: the row's
    std::string id;
    int clicks = 1;  // NSEvent's clickCount: 2 for the second press of a double-click
    bool operator==(const SidebarPress&) const = default;
};
// Nothing when the point takes no presses. An activating click (the window was in the
// background) presses only what accepts first mouse on the Mac: the address field, the
// chevron and a close button, not the rows.
std::optional<SidebarPress> SidebarPressAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x,
                                           float y, int clicks, bool activating = false,
                                           float listTop = sidebar_metrics::kHeaderAreaHeight);
struct SidebarTap {
    enum class Action { None, EditAddress, TogglePinnedSection, SelectTab, SetFolderExpanded, NewTab, CloseTab, ResetTab };
    Action action = Action::None;
    std::string id;         // the tab, folder or space
    bool expanded = false;  // SetFolderExpanded: open (true) or closed
    bool operator==(const SidebarTap&) const = default;
};
// Letting go of `press` at a point of the sidebar as it is now: the field, the chevron, a close
// button and Back to Pinned URL act when it ends over them; a row taps when it ends inside its
// bounds, on a single click (the second click of a double-click renames instead:
// SidebarRenameOnPress). The space's header takes no tap (a click on its name renames).
SidebarTap SidebarRelease(const SidebarPress& press, const std::vector<SidebarRow>& rows, float width, float height, float scroll,
                          float x, float y, float listTop = sidebar_metrics::kHeaderAreaHeight);
// The tab a press renames as it goes down: the second press of a double-click on a tab's row
// (SidebarRowCell.mouseDown's clickCount == 2, TabRowCell.doubleTapped). Folders don't.
std::optional<std::string> SidebarRenameOnPress(const SidebarPress& press);

// A middle click on a tab's row closes it, as the tab's close button does (Windows' convention,
// Chrome's and Edge's; a Windows addition: the Mac has none). The press: on a tab's pill, its
// buttons included, when the row has a close button (BrowserState::ShowsCloseButton; a tab in
// one of Claude's folders has none, so it takes no middle press); nothing on a folder, the header,
// New Tab or the divider. Held by the tab, as a left press is.
std::optional<SidebarPress> SidebarMiddlePressAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x,
                                                 float y, float listTop = sidebar_metrics::kHeaderAreaHeight);
// Letting go of it: CloseTab when the release is inside the pressed tab's row (its bounds, as a
// left tap's), wherever that row is now; nothing once it's moved off the row, or the row went.
SidebarTap SidebarMiddleRelease(const SidebarPress& press, const std::vector<SidebarRow>& rows, float width, float height, float scroll,
                                float x, float y, float listTop = sidebar_metrics::kHeaderAreaHeight);

// Where a tab's trailing buttons sit in its row, as TabRowCell.layout places them right to left
// (close, then Back to Pinned URL), for a sidebar `width` wide: each one's left and right in
// sidebar points (none for one that doesn't show: only while `hovered`), and where its title ends.
struct TabRowTrailing {
    std::optional<std::pair<float, float>> close, reset;
    float titleEnd = 0;
};
TabRowTrailing TabRowTrailingOf(const SidebarRow& row, float width, bool hovered);

// Whether space `space`'s page lists the row (by kind and id) as the session is now: what a rename
// in it needs to stay open.
bool SidebarShowsRow(const BrowserState& state, size_t space, SidebarRow::Kind kind, const std::string& id);

}  // namespace kite
