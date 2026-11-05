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
#include "core/SpaceIcon.h"
#include "core/Sidebar.h"
#include "core/SpaceSwipe.h"

namespace kite {

// ArcMetrics.Sidebar's bottom bar, in points.
namespace space_bar_metrics {
constexpr float kHeight = sidebar_metrics::kBottomBarHeight;
constexpr float kPadding = 8;      // the end buttons sit this far in from the sidebar's sides
constexpr float kButtonSize = 32;  // the Library and + buttons, and a hovered cell's backing
constexpr float kButtonGap = 4;    // between an end button and the room for the spaces
constexpr float kButtonSymbolSize = 15;
constexpr float kButtonOpacity = 0.7f;  // SymbolButton's, over labelColor (itself 85% alpha)
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
constexpr float kDragDistance = 4;  // a press that moves this far drags (DragGesture(minimumDistance: 4))
// A drag's cells sliding aside and its drop landing (SpaceBarView.slide, unmeasured in Arc), on
// Core Animation's ease-in-ease-out.
constexpr double kReorderSlide = 0.2;
constexpr double kReorderTiming[4] = {0.42, 0.0, 0.58, 1.0};
}  // namespace space_bar_metrics

// The bar's top in points from the sidebar's top, for a sidebar `height` points tall: where the
// space's page ends (SidebarListBottom), and where the bar's clicks and drawing start.
inline float SpaceBarTop(float height) { return height - space_bar_metrics::kHeight; }

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
// On a display `scale` px a point, each cell's edge and the scroll's limit sit on whole pixels,
// so the cells draw where they take clicks (0 leaves them exact, as the Mac's points).
SpaceBarLayout LayOutSpaceBar(float width, size_t count, float scroll = 0, float scale = 0);
// The space whose cell is under (x, y) in bar points: cells overlap by 2pt, and the later one is
// on top (AppKit's hit test takes the last subview). None outside the room.
std::optional<size_t> SpaceCellAt(const SpaceBarLayout& layout, float x, float y);

// What one space's cell shows.
struct SpaceCell {
    std::string spaceID;
    std::string icon;   // as Space.icon holds it (for kitecore; `look` is what draws)
    SpaceIconLook look;  // what it shows (SpaceIconLookOf)
    size_t number = 1;  // 1-based place (the tip's Alt+n for the first nine)
    double lit = 0;     // 0 greyed (or a faint dot) ... 1 in colour
    bool selected = false;
    // The 8pt dot: an icon-less space's, or a symbol's with no stand-in.
    bool Dot() const { return look.kind == SpaceIconLook::Kind::Dot; }
    bool operator==(const SpaceCell&) const = default;
};
// The cells for the session at rest: the selected space lit, the rest greyed.
std::vector<SpaceCell> SpaceCells(const BrowserState& state);

// A press on a space's cell (the Mac's SpaceCellView mouseDown): the space, where it went down
// (bar points), and whether it has moved far enough to be a drag, which reorders (SpaceDrag)
// rather than selects.
struct SpaceBarPress {
    std::string spaceID;
    float x = 0, y = 0;
    bool dragged = false;
    bool operator==(const SpaceBarPress&) const = default;
};
std::optional<SpaceBarPress> SpaceBarPressAt(const SpaceBarLayout& layout, const std::vector<SpaceCell>& cells, float x, float y);
// The pointer at (x, y) while pressed: a drag from kDragDistance on.
void SpaceBarMove(SpaceBarPress& press, float x, float y);
// Letting go at (x, y): the space to select when it wasn't a drag and ends inside the cell it
// pressed, as it is now (mouseUp's bounds.contains), within the strip's viewport.
std::optional<std::string> SpaceBarRelease(const SpaceBarPress& press, const SpaceBarLayout& layout, const std::vector<SpaceCell>& cells,
                                           float x, float y);

// A space's icon dragged to a new place in the strip (the Mac's SpaceBarView.Reorder, cellDragged
// and cellDragEnded): picked up once its press has moved kDragDistance, it follows the pointer as
// a ghost (the cell it left shows nothing), the others slide aside for an open slot where it
// aims, and a drop lands it there, or back where it came from off the strip. Positions are bar
// points, as SpaceBarPress's.
struct SpaceDrag {
    std::string spaceID;
    size_t from = 0;                     // its place when picked up
    float startX = 0, startY = 0;        // where the press went down
    float x = 0, y = 0;                  // where the pointer is
    float pickedUpX = 0, pickedUpY = 0;  // its cell's centre when picked up
    // The open slot (its place among the others), none while the pointer is off the strip.
    std::optional<size_t> target;
    bool landing = false;  // dropped: settling into `target`, then moved there
    bool operator==(const SpaceDrag&) const = default;
};
// The drag a press becomes once it's dragged: its open slot its own place until the pointer
// says otherwise. None with a single space (nothing to reorder) or a press that isn't a drag.
std::optional<SpaceDrag> BeginSpaceDrag(const SpaceBarLayout& layout, const std::vector<SpaceCell>& cells, const SpaceBarPress& press);
// The slot a pointer at (x, y) aims at among `count` spaces: Arc's dock takes the drop anywhere
// over the strip's scroll view, which spans the bar's height between its end buttons (the
// room); off it, none.
std::optional<size_t> SpaceDropTarget(const SpaceBarLayout& layout, size_t count, float x, float y);
// The pointer moved to (x, y): the ghost follows it. True when the open slot moved (the cells
// slide). A landing drag doesn't move.
bool MoveSpaceDrag(SpaceDrag& drag, const SpaceBarLayout& layout, size_t count, float x, float y);
// Let go at (x, y): the slot it lands in (where it aims, else where it came from), and it's
// landing. The space moves there (BrowserState::MoveSpace) once it has settled.
size_t DropSpaceDrag(SpaceDrag& drag, const SpaceBarLayout& layout, size_t count, float x, float y);
// Where each of `ids`' cells sits while `drag` is on (SpaceBarView.placeCells): the others in
// the slots SpaceReorder::Slots gives them, the dragged one at the open slot (it shows nothing
// there), or the last slot while there's none. The slots are the layout's cells, on its pixels.
std::vector<BarRect> SpaceDragCells(const SpaceBarLayout& layout, const std::vector<std::string>& ids, const SpaceDrag& drag);
// The ghost's frame: a cell's size following the pointer from where it was picked up, or once
// landing, its slot.
BarRect SpaceDragGhost(const SpaceBarLayout& layout, const SpaceDrag& drag);

// How lit a cell is along a settle of the pages from offset `from` to `to` (SpaceSwipe::Highlight
// with the strip at v), as `rest + slope * s` with s = v - to, the settle's own value (core's
// SettleSegments run from from - to down to 0). Exact while `from` and `to` lie between the same
// two neighbouring pages (offsets k and k+1 page widths): there each cell's light is linear in the
// offset. A switch's settle (SpaceChanged's, from a page away to rest) always is; W9c's swipe
// settles must be split where they cross a page.
struct LinearLit {
    double rest = 0, slope = 0;
    double At(double s) const { return rest + slope * s; }
};
LinearLit HighlightAlongSettle(size_t index, size_t selected, const std::vector<size_t>& built, double from, double to, double pageWidth);

// The opacities of a cell's two layers for its light (the Mac's SpaceCellView.show): the greyed
// icon fades out as the coloured one fades in; a dot (one layer, `lit`) runs from its faint 23%.
struct CellOpacity {
    double grey = 0, lit = 0;
    bool operator==(const CellOpacity&) const = default;
};
CellOpacity CellOpacityAt(bool dot, double lit);
// The same along a settle, each layer linear in the settle's value.
struct CellOpacityAlong {
    LinearLit grey, lit;
};
CellOpacityAlong CellOpacityAlongSettle(bool dot, const LinearLit& light);
// Each segment's value v mapped to `scale * v + offset` (the settle's offset as a cell's opacity).
std::vector<CubicSegment> MapSegments(const std::vector<CubicSegment>& segments, double scale, double offset);

// The tip above a hovered cell (the Mac's SpaceTip, SidebarView.swift): the space's name, its
// profile's name in a white chip (the Mac shows it in every window but an incognito one, which
// Windows hasn't yet), then the keys that select it for the first nine: the Mac's ⌃n is Alt+n
// here (KeyBindings), so "Alt" and the digit, each in a keycap. Its fill is the accent at 45% of
// its OKLab lightness, like Arc's navy pill over an indigo theme.
struct SpaceTip {
    std::string name;
    std::optional<std::string> profile;
    std::optional<size_t> number;
    std::vector<std::string> keys;  // the keycaps' labels: Alt and the number, for the first nine
    ThemeColor fill, accent;
    bool operator==(const SpaceTip&) const = default;
};
SpaceTip SpaceTipOf(const Space& space, size_t number, std::optional<std::string> profile = std::nullopt);
// Space `index`'s tip (its 1-based place, its profile's name).
SpaceTip SpaceTipOf(const BrowserState& state, size_t index);

// The tip's sizes in points, from SpaceTip's SwiftUI.
namespace space_tip_metrics {
constexpr float kHeight = 28;
constexpr float kPadding = 10;  // either side, inside the capsule
constexpr float kSpacing = 8;   // between the name, the chip and the keys
constexpr float kBorderWidth = 1;
constexpr float kBorderOpacity = 0.15f;  // white, inside the edge
constexpr float kNameFontSize = 13;       // white; SF's semibold inks as heavy as Segoe's bold (the UI gate)
constexpr float kChipHeight = 21;
constexpr float kChipPadding = 7;
constexpr float kChipSpacing = 4;  // the face to the profile's name
constexpr float kChipFontSize = 13;      // semibold (Segoe's bold), in the accent
// face.smiling at 11pt semibold, as the Mac's 2x capture inks it: a disc 11.25pt across in its
// 13.5pt image, with the eyes and the smile cut out of it (in points from the disc's centre).
constexpr float kChipFaceWidth = 13.5f;
constexpr float kChipFaceDiameter = 11.25f;
constexpr float kChipFaceDrop = 0.5f;  // its centre below the chip's (SF's symbol baseline)
constexpr float kChipFaceEyeX = 1.5f, kChipFaceEyeY = -1.1f;       // each eye's centre (x either side)
constexpr float kChipFaceEyeWidth = 1.0f, kChipFaceEyeHeight = 1.3f;
constexpr float kChipFaceSmileX = 1.9f, kChipFaceSmileY = 1.35f;   // the smile's ends
constexpr float kChipFaceSmileDepth = 2.3f;                         // its lowest point, from the centre
constexpr float kChipFaceSmileWidth = 0.9f;                         // its stroke
constexpr float kChipOpacity = 0.9f;     // white
constexpr float kKeySize = 18;           // a keycap's side (the Mac's ⌃ and digit fit it)
constexpr float kKeySpacing = 3;
constexpr float kKeyRadius = 4;
constexpr float kKeyFontSize = 12;      // bold, in the accent
constexpr float kKeyOpacity = 0.85f;    // white
// Windows' "Alt" doesn't fit 18pt as the Mac's ⌃ does: a wider label gets this either side.
constexpr float kKeyLabelPadding = 4;
constexpr double kFadeIn = 0.15;  // SpaceTipWindow's alpha, 0 to 1
}  // namespace space_tip_metrics

// Where the tip's parts sit, in points from its top-left. The shell measures the text (DirectWrite
// advances, in points) and draws these.
struct SpaceTipWidths {
    float name = 0;
    float chipSymbol = space_tip_metrics::kChipFaceWidth, chipText = 0;  // the profile chip's face and name (ignored without a profile)
    std::vector<float> keys;             // each keycap's label
};
struct SpaceTipLayout {
    float width = 0, height = space_tip_metrics::kHeight;
    float nameX = 0;
    std::optional<BarRect> chip;
    float chipSymbolX = 0, chipTextX = 0;
    std::vector<BarRect> keys;
    bool operator==(const SpaceTipLayout&) const = default;
};
SpaceTipLayout LayOutSpaceTip(const SpaceTip& tip, const SpaceTipWidths& widths);
// The tip's top-left in window points: centred over `cell` (window points), kTipGap above it, on
// whole pixels at `scale` px a point (the Mac rounds its x to whole points; its window may reach
// past the browser window's edges, as Arc's does).
struct TipOrigin {
    float x = 0, y = 0;
    bool operator==(const TipOrigin&) const = default;
};
TipOrigin SpaceTipOrigin(const BarRect& cell, float width, float height, float scale);

}  // namespace kite
