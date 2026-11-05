#pragma once
// The favorites grid over the space's pinned tabs, platform-free: the Mac's FavoritesTrayView,
// FavoriteTileView, FavoritePaneView and FavoritesEmptyStateView (SidebarFavorites.swift: which
// tiles show, where, what a press does, how each pane is filled, the empty state),
// FavoritesTrayLayout (SidebarView.swift: the columns), SidebarGroup.group (SplitView.swift: a
// favorite split is one tile), NSImage.dominantColor (FaviconView.swift: the colour a selected
// tile takes from its favicon) and ArcMetrics.Sidebar's favorites grid. The shell draws it
// (shell/FavoritesView) between the address field and the space's page, which starts under it.
//
// Not yet: dragging tiles and the drop gap (W18b, which also shows the tray while a drag is on with
// no favorites), the tile's menu and its Ctrl+click (W17), the preview cards over a hovered favorite
// (FavoritePreviewCard, W38), and accessibility for the panes (W35c). The Mac hides the whole tray
// while + › New Space's Create a Space page shows in the space (rebuild's `creating`): that comes
// with Create a Space (W9f).

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

// Arc's empty tray (FavoritesEmptyStateView), in points: its title and subtitle 2pt apart in the
// 16pt insets, centred in a box at least a tile high, 6pt above and below; a 1.5pt dashed outline
// (5 on, 4 off) of labelColor at 0.2 on the box inset by 0.75 with the sidebar's corners less that;
// and the close button (xmark, 8pt bold, at 0.5) 4pt in from the top-right, shown while hovered.
namespace favorites_empty {
constexpr const char* kTitle = "Drag to add Favorites";
constexpr const char* kSubtitle = "Favorites keep your most used sites and apps close";
constexpr float kInset = 16;
constexpr float kPadding = 6;
constexpr float kTextGap = 2;
constexpr float kTitleSize = 12;     // semibold, labelColor at 0.7
constexpr float kSubtitleSize = 11;  // regular, at 0.45
constexpr float kTitleOpacity = 0.7f;
constexpr float kSubtitleOpacity = 0.45f;
constexpr float kOutlineWidth = 1.5f;
constexpr float kDashOn = 5, kDashOff = 4;
constexpr float kOutlineOpacity = 0.2f;
constexpr float kCornerRadius = 11;  // ArcMetrics.Sidebar.cornerRadius
constexpr float kCloseSize = 18;
constexpr float kCloseInset = 4;
constexpr float kCloseSymbolSize = 8;
constexpr float kCloseOpacity = 0.5f;
// CenteredLabel's line box: one line is SF's ascender plus descender (plus leading) rounded up; a
// wrapped one's lines are each the ascender and the descender rounded up (15 for 12pt semibold,
// 14 for 11pt).
float LineHeight(float size);
float LinePitch(float size);
float LabelHeight(float size, int lines);
// The box's height for its title's and subtitle's lines at its width (FavoritesEmptyStateView's
// height(forWidth:)): 59 for Kite's 240pt sidebar, whose subtitle wraps onto two lines.
float Height(int titleLines, int subtitleLines);
constexpr int kTitleLines = 1, kSubtitleLines = 2;  // in a 240pt sidebar, as the Mac's wrap them
}  // namespace favorites_empty

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
    // The grid (or the empty state) with its gaps above and below; 0 when it isn't shown.
    float height = 0;
    // With no favorites, until it's dismissed: Arc's empty state, and its close button.
    bool emptyState = false;
    BarRect emptyFrame, closeFrame;
    bool operator==(const FavoritesTray&) const = default;
};

// The tiles space `space` shows, in the grid's order, not yet placed (rebuild's slots).
std::vector<FavoriteTile> FavoriteTilesOf(const BrowserState& state, size_t space);
// Placed in a sidebar `width` wide, under the address field (FavoritesTrayView.layout). With no
// tiles the tray shows the empty state unless it was dismissed, `emptyHeight` tall (as the shell
// measures its text; the Mac's 240pt wrap by default).
FavoritesTray LayOutFavorites(std::vector<FavoriteTile> tiles, float width, bool emptyStateDismissed,
                              float emptyHeight = favorites_empty::Height(favorites_empty::kTitleLines, favorites_empty::kSubtitleLines));
FavoritesTray LayOutFavorites(const BrowserState& state, size_t space, float width, bool emptyStateDismissed);
// Where the grid starts (the address field's bottom), and where the space's page starts under it.
constexpr float FavoritesTop() { return sidebar_metrics::kHeaderAreaHeight; }
inline float SidebarListTop(const FavoritesTray& tray) { return sidebar_metrics::kHeaderAreaHeight + tray.height; }
// Whether (x, y) is on the tray's band, insets and gaps included: the tray's, never a window drag
// or a row (mouseDownCanMoveWindow false).
bool InFavorites(const FavoritesTray& tray, float width, float x, float y);
// Every pane in the grid's order, and the panes' count.
size_t FavoritePaneCount(const FavoritesTray& tray);

// The pane under (x, y): its tile, its place in it, and its place among all the panes.
struct FavoriteHit {
    size_t tile = 0, pane = 0, index = 0;
    bool operator==(const FavoriteHit&) const = default;
};
std::optional<FavoriteHit> FavoritePaneAt(const FavoritesTray& tray, float x, float y);
const FavoritePane* FavoritePaneWithTab(const FavoritesTray& tray, const std::string& tabID);
// Whether (x, y) is over the empty state (where its close button shows), and over the button.
bool OverEmptyState(const FavoritesTray& tray, float x, float y);
bool OverEmptyStateClose(const FavoritesTray& tray, float x, float y);

// A press in the tray (FavoriteTileView.paneMouseDown, or the empty state's close button), held by
// what it pressed, and where it began.
struct FavoritePress {
    enum class Target { Pane, CloseEmptyState };
    Target target = Target::Pane;
    std::string tabID;  // a pane's
    float x = 0, y = 0;
    bool dragged = false;  // a pane's moved kDragDistance: a drag, which lets go doing nothing (yet)
    bool operator==(const FavoritePress&) const = default;
};
// A left press at (x, y): a pane's, or the empty state's close button (shown under the pointer).
// None anywhere else, and a pane takes none from the click that brings the window forward (it
// doesn't accept first mouse; the close button, a SymbolButton, does).
std::optional<FavoritePress> FavoritePressAt(const FavoritesTray& tray, float x, float y, bool activating = false);
// The pointer moved with the button down (paneMouseDragged's 4pt).
void FavoriteMove(FavoritePress& press, float x, float y);
// Letting go at (x, y) of the tray as it is now: a pane's tab to select (mouseUp: let go inside the
// pane it pressed, without having dragged), or the empty state dismissed (let go over the button).
struct FavoriteTap {
    enum class Action { None, SelectTab, DismissEmptyState };
    Action action = Action::None;
    std::string tabID;
    bool operator==(const FavoriteTap&) const = default;
};
FavoriteTap FavoriteRelease(const FavoritePress& press, const FavoritesTray& tray, float x, float y);

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

// What a pane drawn for `drawn` (none: never drawn) has to draw again to show `now`: its wash, its
// tint and ring, its favicon. A new frame draws all three; a new favicon draws its icon and its
// colour's (whatever it was drawn with is the old icon's); a new appearance redraws the icon (the
// globe is labelColor). A selection or title changing draws nothing.
struct FavoriteRedraw {
    bool wash = false, tint = false, icon = false;
    bool operator==(const FavoriteRedraw&) const = default;
};
FavoriteRedraw FavoriteRedrawFor(const std::optional<std::pair<BarRect, FaviconSource>>& drawn, const FavoritePane& now,
                                 bool appearanceChanged);

// NSImage.dominantColor over an icon drawn `width`×`height` (premultiplied BGRA, `stride` bytes a
// row): pixels more than half opaque, saturated over 0.25 and brighter than 0.15 go in twelve hue
// bins, and the fullest bin's average is the colour. None for a grey or empty icon. Of bins
// equally full the first in hue order wins (the Mac's dictionary picks one of them unordered).
std::optional<ThemeColor> DominantColor(const uint8_t* bgra, uint32_t width, uint32_t height, size_t stride);
// The ring's and the tint's colour (FavoritePaneView.color): the favicon's half way to white, as
// NSColor.blended(withFraction: 0.5, of: .white) mixes them, in calibrated RGB (Apple's Generic
// RGB, gamma 1.8, which the sRGB colour is converted into and clipped to first), back in sRGB.
ThemeColor FavoriteHighlight(ThemeColor dominant);

}  // namespace kite
