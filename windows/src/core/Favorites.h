#pragma once
// The favorites grid over the space's pinned tabs, platform-free: the Mac's FavoritesTrayView,
// FavoriteTileView and FavoritePaneView (SidebarFavorites.swift: which tiles show, where, what a
// press does, how each pane is filled), FavoritesTrayLayout (SidebarView.swift: the columns),
// SidebarGroup.group (SplitView.swift: a favorite split is one tile), NSImage.dominantColor
// (FaviconView.swift: the colour a selected tile takes from its favicon) and ArcMetrics.Sidebar's
// favorites grid. The shell draws it (shell/FavoritesView) between the address field and the
// space's page, which starts under it.
//
// Not yet: the empty state ("Drag to add Favorites", shown while there are none until it's
// dismissed; it needs the Mac's one-shot flags file), dragging tiles and the drop gap (W18b), the
// tile's menu (W17) and the preview cards over a hovered favorite (FavoritePreviewCard, W38).

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "core/Models.h"
#include "core/Sidebar.h"
#include "core/SpaceBar.h"

namespace kite {

// ArcMetrics.Sidebar's favorites grid, in points.
namespace favorites_metrics {
constexpr float kTopGap = 8;      // favoritesTopGap: under the address field
constexpr float kBottomGap = 8;   // favoritesBottomGap: above the space's page
constexpr int kColumns = 4;       // at most a row
constexpr float kHeight = 47;     // a tile's
constexpr float kSpacing = 8;     // between tiles, both ways
constexpr float kIconSize = 18;   // the favicon, centred in a pane
constexpr float kSplitSpacing = 2;  // between a favorite split's panes
constexpr float kCornerRadius = 12;
// A selected pane: white at 0.45 (dark) or 0.8 (light), the favicon's colour over it at 0.2,
// 0.3 hovered (dark), none, 0.1 hovered (light), and a 2pt ring of the colour on the pane inset by 1.
constexpr float kSelectedFill = 0.45f;
constexpr float kSelectedFillLight = 0.8f;
constexpr float kRingWidth = 2;
constexpr float kRingInset = 1;
constexpr float kTint = 0.2f;
constexpr float kTintHovered = 0.3f;
constexpr float kTintHoveredLight = 0.1f;
// The favicon's colour half way to white (fitted to a capture of Arc's selected YouTube favorite).
constexpr float kHighlightWhiten = 0.5f;
// An unselected pane: the address field's white wash (fieldFill), brighter by hoverFill hovered.
constexpr float kFieldFill = 0.10f;
constexpr float kHoverFill = 0.10f;
// A press that moves this far is a drag (FavoriteTileView.paneMouseDragged), never a click.
constexpr float kDragDistance = 4;
// NSImage.dominantColor draws the icon this many pixels a side and bins its colours.
constexpr uint32_t kColorSampleSide = 16;
}  // namespace favorites_metrics

// FavoritesTrayLayout.columns: as many columns as square tiles would allow in `width` (the
// sidebar's less its padding), at most four and no more than there are tiles, then rows balanced:
// 5 tiles are 3 + 2, 7 are 4 + 3, 9 are 3 × 3. One for none.
int FavoritesColumns(size_t count, float width);

// SidebarGroup.group: a list's items (by id) as its rows, each split's members in one (at its
// first member), each row its items' places in the list.
struct SidebarGroup {
    std::string id;                  // the split's, or the item's
    const SplitView* split = nullptr;  // into `splits`, valid while it is
    std::vector<size_t> indices;
};
std::vector<SidebarGroup> GroupBySplit(const std::vector<std::string>& ids, const std::vector<SplitView>& splits);

// The favorites grid a space shows: its profile's (the selected space's is BrowserState::Favorites).
const std::vector<Tab>& FavoritesOf(const BrowserState& state, size_t space);
const std::vector<SplitView>& FavoriteSplitsOf(const BrowserState& state, size_t space);

// One favorite in a tile (FavoritePaneView): its tab, what it shows, and where.
struct FavoritePane {
    std::string tabID;
    std::string title;  // its tooltip: the tab's DisplayTitle
    FaviconSource favicon;
    bool selected = false;  // the space's selected tab
    BarRect frame;          // in the sidebar's points, from its top-left
    bool operator==(const FavoritePane&) const = default;
};
// A slot in the grid (FavoriteTileView): one favorite, or a favorite split's panes side by side
// 2pt apart (stacked for a vertical split, a top/bottom one).
struct FavoriteTile {
    std::string id;  // the favorite's, or the split's
    bool split = false;
    bool vertical = false;
    std::vector<FavoritePane> panes;
    BarRect frame;
    bool operator==(const FavoriteTile&) const = default;
};
struct FavoritesTray {
    std::vector<FavoriteTile> tiles;
    int columns = 1;
    // The grid with its gaps above and below; 0 when it isn't shown (no favorites).
    float height = 0;
    bool operator==(const FavoritesTray&) const = default;
};

// The tiles space `space` shows, in the grid's order, not yet placed (rebuild's slots).
std::vector<FavoriteTile> FavoriteTilesOf(const BrowserState& state, size_t space);
// Placed in a sidebar `width` wide, under the address field (FavoritesTrayView.layout).
FavoritesTray LayOutFavorites(std::vector<FavoriteTile> tiles, float width);
FavoritesTray LayOutFavorites(const BrowserState& state, size_t space, float width);
// Where the grid starts (the address field's bottom), and where the space's page starts under it.
constexpr float FavoritesTop() { return sidebar_metrics::kHeaderAreaHeight; }
inline float SidebarListTop(const FavoritesTray& tray) { return sidebar_metrics::kHeaderAreaHeight + tray.height; }
// Whether (x, y) is on the grid's band, insets and gaps included: the tray's, never a window drag
// or a row (mouseDownCanMoveWindow false).
bool InFavorites(const FavoritesTray& tray, float width, float x, float y);

// The pane under (x, y): its tile and its place in it.
struct FavoriteHit {
    size_t tile = 0, pane = 0;
    bool operator==(const FavoriteHit&) const = default;
};
std::optional<FavoriteHit> FavoritePaneAt(const FavoritesTray& tray, float x, float y);
const FavoritePane* FavoritePaneWithTab(const FavoritesTray& tray, const std::string& tabID);

// A press on a pane, held by its tab, and where it began (FavoriteTileView.paneMouseDown).
struct FavoritePress {
    std::string tabID;
    float x = 0, y = 0;
    bool dragged = false;  // it moved kDragDistance: a drag, which lets go doing nothing (yet)
    bool operator==(const FavoritePress&) const = default;
};
// A left press at (x, y): a pane's. None off the panes, and none for the click that brings the
// window forward (the pane doesn't accept first mouse).
std::optional<FavoritePress> FavoritePressAt(const FavoritesTray& tray, float x, float y, bool activating = false);
// The pointer moved with the button down (paneMouseDragged's 4pt).
void FavoriteMove(FavoritePress& press, float x, float y);
// Letting go at (x, y) of the grid as it is now: the favorite to select (mouseUp: its tab, when
// it lets go inside the pane it pressed, without having dragged), else none.
std::optional<std::string> FavoriteRelease(const FavoritePress& press, const FavoritesTray& tray, float x, float y);

// How a pane is filled (FavoritePaneView.applyFill): the white wash's alpha, the favicon colour's
// alpha over it, and whether the colour's ring shows. With no colour (a grey or missing favicon,
// or one not loaded yet) a selected pane is just white.
struct FavoriteLook {
    float fill = 0;
    float tint = 0;
    bool ring = false;
    bool operator==(const FavoriteLook&) const = default;
};
FavoriteLook FavoriteLookOf(bool selected, bool hovered, bool dark, bool hasColor);

// NSImage.dominantColor over an icon drawn `width`×`height` (premultiplied BGRA, `stride` bytes a
// row): pixels more than half opaque, saturated over 0.25 and brighter than 0.15 go in twelve hue
// bins, and the fullest bin's average is the colour. None for a grey or empty icon. Of bins
// equally full the first in hue order wins (the Mac's dictionary picks one of them unordered).
std::optional<ThemeColor> DominantColor(const uint8_t* bgra, uint32_t width, uint32_t height, size_t stride);
// The ring's and the tint's colour: the favicon's, half way to white.
ThemeColor FavoriteHighlight(ThemeColor dominant);

}  // namespace kite
