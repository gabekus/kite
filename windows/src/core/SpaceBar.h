#pragma once
// The sidebar's bottom bar, platform-free: the Mac's SpaceBarView layout (SidebarSpaceBar.swift),
// KiteCore's SpaceReorder, and what each space's cell shows. Arc's Library button sits at the
// leading end and the + menu at the trailing end; the spaces sit between them on a 34pt pitch,
// centred, or from the leading edge of the room and scrolling when they don't fit. The shell
// draws it (shell/SpaceBarView).

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

#include "core/Models.h"
#include "core/SpaceSwipe.h"

namespace kite {

// ArcMetrics.Sidebar's bottom bar, in points.
namespace space_bar_metrics {
constexpr float kHeight = 50;
constexpr float kPadding = 8;      // the end buttons sit this far in from the sidebar's sides
constexpr float kButtonSize = 32;  // the Library and + buttons, and a hovered cell's backing
constexpr float kButtonGap = 4;    // between an end button and the room for the spaces
constexpr float kButtonSymbolSize = 15;
constexpr float kButtonOpacity = 0.7f;
constexpr float kCellWidth = 36, kCellHeight = 34;
constexpr float kCellPitch = 34;
constexpr float kDotSize = 8;
constexpr float kDotOpacity = 0.23f;  // an icon-less space's dot when it isn't the one you're in
constexpr float kIconFontSize = 12.5f;
constexpr float kGreyOpacity = 0.45f;  // a greyed icon, inside its own fade
constexpr float kBackingRadius = 8;
constexpr float kBackingOpacity = 0.08f;  // labelColor's, under the pointer (not for the space you're in)
constexpr float kTipGap = 2;
constexpr double kTipDelay = 0.4;
}  // namespace space_bar_metrics

// SpaceReorder: dragging a space's icon along the strip (Arc's SidebarDock). Positions are x
// offsets in points along the bar.
namespace space_reorder {
// Which slot a drop at `pointerX` lands in, for a strip of `count` spaces (the dragged one
// included) whose first cell starts at `stripMinX`, cells `pitch` apart.
size_t DropIndex(double pointerX, double stripMinX, size_t count, double pitch, double cellWidth);
// The order the strip shows during a drag: the spaces without the dragged one, with nullopt for
// the open slot when the drag aims at the strip.
std::vector<std::optional<std::string>> Slots(const std::vector<std::string>& ids, const std::string& dragging,
                                              std::optional<size_t> target);
// The strip's width for `slots` cells: `pitch` apart, the last one its full width.
double Width(size_t slots, double pitch, double cellWidth);
}  // namespace space_reorder

struct BarRect {
    float left = 0, top = 0, right = 0, bottom = 0;
    float Width() const { return right - left; }
    float Height() const { return bottom - top; }
    bool Contains(float x, float y) const { return x >= left && x < right && y >= top && y < bottom; }
    bool operator==(const BarRect&) const = default;
};

// Where everything in the bar sits, in points from the bar's top-left (the sidebar's left edge).
struct SpaceBarLayout {
    BarRect library, plus;
    // Between the end buttons, the bar's full height: where the spaces are and take clicks.
    BarRect room;
    // The strip's cells may draw here (the scroll view's frame): the strip itself when it fits,
    // else the room's width.
    BarRect viewport;
    bool fits = true;
    // How far the strip is scrolled (0 when it fits), and where its first cell starts.
    float scroll = 0;
    float stripMinX = 0;
    std::vector<BarRect> cells;  // one per space, in order, at the scroll
    bool operator==(const SpaceBarLayout&) const = default;
};

// The bar for a sidebar `width` points wide with `count` spaces, scrolled by `scroll` (clamped).
SpaceBarLayout LayOutSpaceBar(float width, size_t count, float scroll = 0);
// The space whose cell is under (x, y) in bar points: cells overlap by 2pt, and the later one is
// on top (AppKit's hit test takes the last subview). None outside the room.
std::optional<size_t> SpaceCellAt(const SpaceBarLayout& layout, float x, float y);

// What one space's cell shows.
struct SpaceCell {
    std::string spaceID;
    std::string icon;  // empty: a dot
    size_t number = 1;  // 1-based place (the tip's Alt+n for the first nine)
    double lit = 0;     // 0 greyed (or a faint dot) ... 1 in colour
    bool selected = false;
    bool operator==(const SpaceCell&) const = default;
};
// The cells for the session at rest: the selected space lit, the rest greyed.
std::vector<SpaceCell> SpaceCells(const BrowserState& state);

// How lit a cell is along a settle of the pages from `from` points to rest (SpaceSwipe::Highlight
// with the strip at v), as `rest + slope * v`. Exact for any settle from at most a page's width
// away: there the lit of each cell changes linearly with the strip's offset.
struct LinearLit {
    double rest = 0, slope = 0;
    double At(double v) const { return rest + slope * v; }
};
LinearLit HighlightAlongSettle(size_t index, size_t selected, const std::vector<size_t>& built, double from, double pageWidth);
// Each segment's value v mapped to `scale * v + offset` (the settle's offset as a cell's opacity).
std::vector<CubicSegment> MapSegments(const std::vector<CubicSegment>& segments, double scale, double offset);

// The tip above a hovered cell (the Mac's SpaceTip): the space's name, then Alt and its number
// for the first nine (the Mac's ⌃n is Alt+n here). Its fill is the accent at 45% of its OKLab
// lightness, like Arc's navy pill over an indigo theme.
struct SpaceTip {
    std::string name;
    std::optional<size_t> number;
    ThemeColor fill, accent;
    bool operator==(const SpaceTip&) const = default;
};
SpaceTip SpaceTipOf(const Space& space, size_t number);

}  // namespace kite
