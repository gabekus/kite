#include "core/SpaceBar.h"

#include <algorithm>
#include <cmath>

#include "core/OKLab.h"

namespace kite {

namespace M = space_bar_metrics;

namespace space_reorder {

size_t DropIndex(double pointerX, double stripMinX, size_t count, double pitch, double cellWidth) {
    if (count == 0) return 0;
    const double first = stripMinX + cellWidth / 2;
    // Swift's rounded(): halves away from zero.
    const double slot = std::round((pointerX - first) / pitch);
    return static_cast<size_t>(std::clamp(slot, 0.0, static_cast<double>(count - 1)));
}

std::vector<std::optional<std::string>> Slots(const std::vector<std::string>& ids, const std::string& dragging,
                                              std::optional<size_t> target) {
    std::vector<std::optional<std::string>> slots;
    for (const std::string& id : ids) {
        if (id != dragging) slots.emplace_back(id);
    }
    if (target) slots.insert(slots.begin() + static_cast<std::ptrdiff_t>(std::min(*target, slots.size())), std::nullopt);
    return slots;
}

double Width(size_t slots, double pitch, double cellWidth) {
    return slots > 0 ? static_cast<double>(slots - 1) * pitch + cellWidth : 0;
}

}  // namespace space_reorder

SpaceBarLayout LayOutSpaceBar(float width, size_t count, float scroll, float scale) {
    SpaceBarLayout layout;
    // On the pixel grid when there's one: an edge to the nearest pixel, a scroll limit up to the
    // next (so the last cell shows whole).
    const auto snap = [scale](float v) { return scale > 0 ? std::round(v * scale) / scale : v; };
    const auto snapUp = [scale](float v) { return scale > 0 ? std::ceil(v * scale) / scale : v; };
    const float y = (M::kHeight - M::kButtonSize) / 2;
    layout.library = {M::kPadding, y, M::kPadding + M::kButtonSize, y + M::kButtonSize};
    layout.plus = {width - M::kPadding - M::kButtonSize, y, width - M::kPadding, y + M::kButtonSize};
    const float minX = M::kPadding + M::kButtonSize + M::kButtonGap;
    const float maxX = width - M::kPadding - M::kButtonSize - M::kButtonGap;
    layout.room = {minX, 0, minX + std::max(maxX - minX, 0.0f), M::kHeight};
    const float strip = static_cast<float>(space_reorder::Width(count, M::kCellPitch, M::kCellWidth));
    const float cellTop = snap((M::kHeight - M::kCellHeight) / 2);
    const float cellBottom = snap(cellTop + M::kCellHeight);
    layout.fits = strip <= layout.room.Width();
    if (layout.fits) {
        const float mid = (layout.room.left + layout.room.right) / 2;
        layout.stripMinX = mid - strip / 2;
        layout.viewport = {snap(layout.stripMinX), cellTop, snap(layout.stripMinX + strip), cellBottom};
    } else {
        // The scroll view's bounds stay inside the strip.
        layout.scroll = std::clamp(scroll, 0.0f, snapUp(strip - layout.room.Width()));
        layout.stripMinX = layout.room.left - layout.scroll;
        layout.viewport = {snap(layout.room.left), cellTop, snap(layout.room.right), cellBottom};
    }
    layout.cells.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const float left = layout.stripMinX + static_cast<float>(i) * M::kCellPitch;
        layout.cells.push_back({snap(left), cellTop, snap(left + M::kCellWidth), cellBottom});
    }
    return layout;
}

std::optional<size_t> SpaceCellAt(const SpaceBarLayout& layout, float x, float y) {
    if (!layout.viewport.Contains(x, y)) return std::nullopt;
    for (size_t i = layout.cells.size(); i-- > 0;) {
        if (layout.cells[i].Contains(x, y)) return i;
    }
    return std::nullopt;
}

std::vector<SpaceCell> SpaceCells(const BrowserState& state) {
    std::vector<SpaceCell> cells;
    cells.reserve(state.spaces.size());
    const size_t selected = state.SelectedSpaceIndex();
    for (size_t i = 0; i < state.spaces.size(); ++i) {
        const Space& space = state.spaces[i];
        cells.push_back({space.id, space.icon, SpaceIconLookOf(space.icon, space.theme), i + 1, i == selected ? 1.0 : 0.0, i == selected});
    }
    return cells;
}

std::optional<SpaceBarPress> SpaceBarPressAt(const SpaceBarLayout& layout, const std::vector<SpaceCell>& cells, float x, float y) {
    const std::optional<size_t> index = SpaceCellAt(layout, x, y);
    if (!index || *index >= cells.size()) return std::nullopt;
    return SpaceBarPress{cells[*index].spaceID, x, y, false};
}

void SpaceBarMove(SpaceBarPress& press, float x, float y) {
    if (!press.dragged) press.dragged = std::hypot(x - press.x, y - press.y) >= M::kDragDistance;
}

std::optional<std::string> SpaceBarRelease(const SpaceBarPress& press, const SpaceBarLayout& layout, const std::vector<SpaceCell>& cells,
                                           float x, float y) {
    if (press.dragged || !layout.viewport.Contains(x, y)) return std::nullopt;
    for (size_t i = 0; i < cells.size() && i < layout.cells.size(); ++i) {
        if (cells[i].spaceID == press.spaceID) return layout.cells[i].Contains(x, y) ? std::optional(press.spaceID) : std::nullopt;
    }
    return std::nullopt;
}

LinearLit HighlightAlongSettle(size_t index, size_t selected, const std::vector<size_t>& built, double from, double to, double pageWidth) {
    const double rest = SpaceSwipe::Highlight(index, selected, built, to, pageWidth);
    if (from == to) return {rest, 0};
    const double start = SpaceSwipe::Highlight(index, selected, built, from, pageWidth);
    return {rest, (start - rest) / (from - to)};
}

CellOpacity CellOpacityAt(bool dot, double lit) {
    if (dot) return {0, lit + M::kDotOpacity * (1 - lit)};  // exactly 1 when lit
    return {1 - lit, lit};
}

CellOpacityAlong CellOpacityAlongSettle(bool dot, const LinearLit& light) {
    // Each layer's opacity is linear in the light, so in the settle's value too.
    const CellOpacity rest = CellOpacityAt(dot, light.rest), next = CellOpacityAt(dot, light.rest + light.slope);
    return {{rest.grey, next.grey - rest.grey}, {rest.lit, next.lit - rest.lit}};
}

std::vector<CubicSegment> MapSegments(const std::vector<CubicSegment>& segments, double scale, double offset) {
    std::vector<CubicSegment> mapped;
    mapped.reserve(segments.size());
    for (const CubicSegment& s : segments) {
        mapped.push_back({s.begin, s.constant * scale + offset, s.linear * scale, s.quadratic * scale, s.cubic * scale});
    }
    return mapped;
}

SpaceTip SpaceTipOf(const Space& space, size_t number) {
    const ThemeColor accent = Accent(space.theme);
    Lab lab = oklab::FromSRGB(accent);
    lab.L *= 0.45f;
    return {space.name, number <= 9 ? std::optional<size_t>(number) : std::nullopt, oklab::ToSRGB(lab), accent};
}

}  // namespace kite
