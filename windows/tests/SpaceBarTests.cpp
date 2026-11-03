// The sidebar's bottom bar (core/SpaceBar.h): the Mac's SpaceReorderTests case for case (the
// drop's move comes with W9d's moveSpace), plus SpaceBarView's layout, the cells, their light
// along a page settle and the tip.

#include <cmath>
#include <optional>
#include <string>
#include <vector>

#include "Check.h"
#include "core/OKLab.h"
#include "core/SpaceBar.h"

using namespace kite;

namespace {
size_t Index(double x) { return space_reorder::DropIndex(x, 92.5, 3, 34, 36); }
}  // namespace

// SpaceReorderTests: Arc's three-space strip, cells 36 wide on a 34pt pitch from x 92.5.

TEST(dropsInTheSlotNearestThePointer) {
    // Arc moved the open slot between pointer x 128 and 134, and again between 162 and 168.
    CHECK(Index(110.5) == 0);
    CHECK(Index(127) == 0);
    CHECK(Index(128) == 1);
    CHECK(Index(161) == 1);
    CHECK(Index(162) == 2);
    // Past either end the first or last slot.
    CHECK(Index(40) == 0);
    CHECK(Index(240) == 2);
    CHECK(space_reorder::DropIndex(100, 0, 0, 34, 36) == 0);
}

TEST(opensASlotWhereTheDragAims) {
    using Slots = std::vector<std::optional<std::string>>;
    const std::vector<std::string> ids{"a", "b", "c"};
    CHECK(space_reorder::Slots(ids, "a", 1) == (Slots{"b", std::nullopt, "c"}));
    CHECK(space_reorder::Slots(ids, "a", 2) == (Slots{"b", "c", std::nullopt}));
    CHECK(space_reorder::Slots(ids, "c", 0) == (Slots{std::nullopt, "a", "b"}));
    // Off the strip the slot closes.
    CHECK(space_reorder::Slots(ids, "b", std::nullopt) == (Slots{"a", "c"}));
    // A target past the end opens the last slot.
    CHECK(space_reorder::Slots(ids, "a", 9) == (Slots{"b", "c", std::nullopt}));
}

TEST(stripWidth) {
    // Arc: three cells span x 92.5 to 196.5.
    CHECK(space_reorder::Width(3, 34, 36) == 104);
    CHECK(space_reorder::Width(2, 34, 36) == 70);
    CHECK(space_reorder::Width(0, 34, 36) == 0);
}

// SpaceBarView's layout.

TEST(theSpacesSitCentredBetweenTheEndButtons) {
    // Arc's tree at a 289pt sidebar: three 36x34 cells at x 92.5, 126.5, 160.5, y 8 into the bar.
    const SpaceBarLayout bar = LayOutSpaceBar(289, 3);
    CHECK(bar.fits);
    CHECK(bar.cells.size() == 3);
    CHECK(bar.cells[0] == (BarRect{92.5f, 8, 128.5f, 42}));
    CHECK(bar.cells[1].left == 126.5f && bar.cells[2].left == 160.5f);
    // The end buttons: 32pt, 8pt in, centred in the 50pt bar.
    CHECK(bar.library == (BarRect{8, 9, 40, 41}));
    CHECK(bar.plus == (BarRect{249, 9, 281, 41}));
    CHECK(bar.room == (BarRect{44, 0, 245, 50}));
    CHECK(bar.viewport == (BarRect{92.5f, 8, 196.5f, 42}));
    // Kite's 240pt sidebar.
    const SpaceBarLayout narrow = LayOutSpaceBar(240, 2);
    CHECK(narrow.cells[0].left == 85 && narrow.cells[1].left == 119);
    // No spaces: no cells, nothing to hit.
    CHECK(LayOutSpaceBar(240, 0).cells.empty());
    CHECK(!SpaceCellAt(LayOutSpaceBar(240, 0), 120, 25));
}

TEST(tooManySpacesScrollFromTheRoomsLeadingEdge) {
    // 240pt: a 152pt room fits four cells (138pt), not five (172pt).
    CHECK(LayOutSpaceBar(240, 4).fits);
    const SpaceBarLayout bar = LayOutSpaceBar(240, 5);
    CHECK(!bar.fits);
    CHECK(bar.cells[0].left == 44);
    CHECK(bar.viewport == (BarRect{44, 8, 196, 42}));
    // Scrolled, clamped to the strip's end.
    const SpaceBarLayout scrolled = LayOutSpaceBar(240, 5, 10);
    CHECK(scrolled.scroll == 10 && scrolled.cells[0].left == 34);
    CHECK(LayOutSpaceBar(240, 5, 500).scroll == 20);
    CHECK(LayOutSpaceBar(240, 5, -5).scroll == 0);
    // A strip that fits doesn't scroll.
    CHECK(LayOutSpaceBar(240, 2, 30).scroll == 0);
}

TEST(aClickFindsTheCellOnTop) {
    const SpaceBarLayout bar = LayOutSpaceBar(240, 2);  // cells 85...121 and 119...155
    CHECK(SpaceCellAt(bar, 90, 25) == 0u);
    // The 2pt they share is the later cell's.
    CHECK(SpaceCellAt(bar, 120, 25) == 1u);
    CHECK(SpaceCellAt(bar, 150, 25) == 1u);
    // Above or below the cells, or beside the strip, nothing.
    CHECK(!SpaceCellAt(bar, 90, 5));
    CHECK(!SpaceCellAt(bar, 90, 45));
    CHECK(!SpaceCellAt(bar, 60, 25));
    // Scrolled out of the room: a cell can't be hit outside it.
    const SpaceBarLayout scrolled = LayOutSpaceBar(240, 6, 30);  // cell 0 at 14...50
    CHECK(SpaceCellAt(scrolled, 46, 25) == 0u);
    CHECK(!SpaceCellAt(scrolled, 30, 25));
}

// What the cells show.

TEST(theSpaceYoureInIsLit) {
    BrowserState state;
    Space a, b, c;
    a.id = "a";
    a.icon = "🏃";
    b.id = "b";
    c.id = "c";
    c.icon = "symbol:star";
    state.spaces = {a, b, c};
    state.SelectSpace("b");
    const auto cells = SpaceCells(state);
    CHECK(cells.size() == 3);
    CHECK(cells[0].lit == 0 && !cells[0].selected && cells[0].icon == "🏃" && cells[0].number == 1);
    CHECK(cells[1].lit == 1 && cells[1].selected && cells[1].icon.empty() && cells[1].number == 2);
    CHECK(cells[2].lit == 0 && cells[2].spaceID == "c" && cells[2].number == 3);
}

TEST(aCellsLightFollowsTheSlideLinearly) {
    const double w = 240;
    // Each case: a switch's selected space, the space it left (the anchor) and the count, with
    // the slide's start offset as SpaceChanged gives it.
    struct Case {
        size_t selected, anchor, count;
    };
    for (const Case& c : {Case{1, 0, 2}, Case{0, 1, 2}, Case{0, 3, 4}, Case{3, 0, 4}, Case{4, 1, 6}, Case{2, 1, 3}}) {
        const auto built = SpaceSwipe::BuiltPages(c.selected, c.anchor, c.count);
        const double from = (c.selected > c.anchor ? 1 : -1) * w;
        double total = 0;
        for (size_t i = 0; i < c.count; ++i) {
            const LinearLit lit = HighlightAlongSettle(i, c.selected, built, from, w);
            for (double f : {0.0, 0.1, 0.37, 0.5, 0.81, 1.0}) {
                const double v = from * f;
                CHECK(std::abs(lit.At(v) - SpaceSwipe::Highlight(i, c.selected, built, v, w)) < 1e-9);
            }
            total += lit.At(from * 0.4);
        }
        // Mid-slide the light is shared out, not lost.
        CHECK(std::abs(total - 1) < 1e-9);
        // At rest only the selected space is lit.
        CHECK(HighlightAlongSettle(c.selected, c.selected, built, from, w).rest == 1);
    }
    // No distance: nothing changes.
    const LinearLit still = HighlightAlongSettle(0, 0, {0, 1}, 0, w);
    CHECK(still.rest == 1 && still.slope == 0);
}

TEST(segmentsMapToACellsOpacity) {
    const auto segments = SettleSegments(240, space_motion::kPageResponse);
    const double end = SettleDuration(240, space_motion::kPageResponse);
    // The selected cell's light as the strip settles from a page to the right: 1 - v / 240.
    const auto lit = MapSegments(segments, -1.0 / 240, 1);
    CHECK(lit.size() == segments.size());
    for (double t : {0.0, 0.01, 0.05, 0.1, end * 0.99}) {
        CHECK(std::abs(ValueAt(lit, end, t) - (1 - ValueAt(segments, end, t) / 240)) < 1e-9);
    }
    CHECK(std::abs(ValueAt(lit, end, 0) - 0) < 1e-3);
}

TEST(aTipShowsTheNameAndTheFirstNinesKeys) {
    Space space;
    space.name = "Work";
    space.theme = Theme::Make({ThemeColor::FromHex(0x5B4BF5), ThemeColor::FromHex(0x1E1E2E)});
    const SpaceTip tip = SpaceTipOf(space, 3);
    CHECK(tip.name == "Work" && tip.number == 3u);
    CHECK(tip.accent == Accent(space.theme));
    // The fill is the accent darkened in OKLab: 45% of its lightness, then clamped into sRGB
    // (which lifts it a little for a vivid accent), the hue kept.
    const Lab accent = oklab::FromSRGB(tip.accent), fill = oklab::FromSRGB(tip.fill);
    CHECK(fill.L < accent.L * 0.6f && fill.L > accent.L * 0.4f);
    CHECK(std::abs(std::atan2(fill.b, fill.a) - std::atan2(accent.b, accent.a)) < 0.1f);
    CHECK(!SpaceTipOf(space, 10).number);
    CHECK(SpaceTipOf(space, 9).number == 9u);
}
