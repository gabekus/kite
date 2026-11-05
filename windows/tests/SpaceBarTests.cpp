// The sidebar's bottom bar (core/SpaceBar.h): the Mac's SpaceReorderTests case for case (but
// dropMovesTheSpaceKeepingTheCurrentOne, with moveSpace in SpaceEditingTests.cpp), plus
// SpaceBarView's layout, presses, the cells, their light along a page settle and the tip.

#include <algorithm>
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

TEST(onTheScreensPixelsTheCellsSitOnWholePixels) {
    // 125%: 34pt is 42.5px, so each cell's edges round to the nearest pixel, as they draw.
    for (size_t count : {2u, 3u, 6u}) {
        for (float scroll : {0.0f, 7.0f, 500.0f}) {
            const SpaceBarLayout bar = LayOutSpaceBar(240, count, scroll, 1.25f);
            for (const BarRect& r : bar.cells) {
                for (float edge : {r.left, r.right, r.top, r.bottom}) CHECK(std::abs(edge * 1.25f - std::round(edge * 1.25f)) < 1e-3f);
            }
            CHECK(std::abs(bar.viewport.left * 1.25f - std::round(bar.viewport.left * 1.25f)) < 1e-3f);
        }
    }
    // Scrolled to the end, the limit is a whole pixel too (67.5px up to 68), so the last cell shows whole.
    const SpaceBarLayout end = LayOutSpaceBar(240, 6, 500, 1.25f);
    CHECK(std::abs(end.scroll - 54.4f) < 1e-4f);
    CHECK(end.cells.back().right <= end.viewport.right);
    // At 2x (the Mac's Retina) Arc's numbers are whole pixels already.
    CHECK(LayOutSpaceBar(289, 3, 0, 2).cells[0].left == 92.5f);
    // The bar starts where the space's page ends.
    CHECK(SpaceBarTop(800) == 750 && SidebarListBottom(800) == SpaceBarTop(800));
}

TEST(aPressSelectsWhenLetGoInItsCell) {
    const SpaceBarLayout bar = LayOutSpaceBar(240, 2);  // cells 85...121 and 119...155
    std::vector<SpaceCell> cells(2);
    cells[0].spaceID = "a";
    cells[1].spaceID = "b";
    // Outside the cells nothing is pressed.
    CHECK(!SpaceBarPressAt(bar, cells, 60, 25));
    auto press = SpaceBarPressAt(bar, cells, 100, 25);
    CHECK(press && press->spaceID == "a");
    // A move under 4pt is still a click; let go in the shared 2pt it's still the pressed cell's.
    SpaceBarMove(*press, 103.9f, 25);
    CHECK(!press->dragged);
    CHECK(SpaceBarRelease(*press, bar, cells, 120, 25) == std::optional<std::string>("a"));
    // Let go outside its cell, nothing.
    CHECK(!SpaceBarRelease(*press, bar, cells, 130, 25));
    CHECK(!SpaceBarRelease(*press, bar, cells, 100, 45));
    // 4pt is a drag (it reorders, from W9d), never a click, even back over the cell.
    SpaceBarMove(*press, 100, 29);
    CHECK(press->dragged);
    SpaceBarMove(*press, 100, 25);
    CHECK(press->dragged && !SpaceBarRelease(*press, bar, cells, 100, 25));
    // A space gone by the time it's let go selects nothing.
    auto gone = SpaceBarPressAt(bar, cells, 140, 25);
    CHECK(!SpaceBarRelease(*gone, bar, {cells[0]}, 140, 25));
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
    c.icon = "symbol:star.fill";
    state.spaces = {a, b, c};
    state.SelectSpace("b");
    const auto cells = SpaceCells(state);
    CHECK(cells.size() == 3);
    CHECK(cells[0].lit == 0 && !cells[0].selected && cells[0].icon == "🏃" && !cells[0].Dot() && cells[0].number == 1);
    CHECK(cells[0].look.kind == SpaceIconLook::Kind::Emoji && cells[0].look.text == "🏃");
    CHECK(cells[1].lit == 1 && cells[1].selected && cells[1].icon.empty() && cells[1].Dot() && cells[1].number == 2);
    // An SF Symbol is drawn (in its theme's accent), not a dot.
    CHECK(cells[2].lit == 0 && cells[2].spaceID == "c" && !cells[2].Dot() && cells[2].number == 3);
    CHECK(cells[2].look.kind == SpaceIconLook::Kind::Symbol && cells[2].look.accent == Accent(c.theme));
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
            const LinearLit lit = HighlightAlongSettle(i, c.selected, built, from, 0, w);
            for (double f : {0.0, 0.1, 0.37, 0.5, 0.81, 1.0}) {
                const double v = from * f;
                CHECK(std::abs(lit.At(v) - SpaceSwipe::Highlight(i, c.selected, built, v, w)) < 1e-9);
            }
            total += lit.At(from * 0.4);
        }
        // Mid-slide the light is shared out, not lost.
        CHECK(std::abs(total - 1) < 1e-9);
        // At rest only the selected space is lit.
        CHECK(HighlightAlongSettle(c.selected, c.selected, built, from, 0, w).rest == 1);
    }
    // A settle that ends off the selected page (W9c's swipe): the light is the strip's at each
    // point, the segments' value s being the offset less where it ends.
    const auto built = SpaceSwipe::BuiltPages(1, 0, 3);
    for (size_t i = 0; i < 3; ++i) {
        const LinearLit lit = HighlightAlongSettle(i, 1, built, 200, 40, w);
        for (double v : {200.0, 120.0, 40.0}) CHECK(std::abs(lit.At(v - 40) - SpaceSwipe::Highlight(i, 1, built, v, w)) < 1e-9);
    }
    // No distance: nothing changes.
    const LinearLit still = HighlightAlongSettle(0, 0, {0, 1}, 0, 0, w);
    CHECK(still.rest == 1 && still.slope == 0);
}

TEST(aCellsLayersFadeAcrossEachOther) {
    // An icon: greyed out as it lights up; a dot, one layer, from its faint 23%.
    CHECK(CellOpacityAt(false, 0) == (CellOpacity{1, 0}));
    CHECK(CellOpacityAt(false, 1) == (CellOpacity{0, 1}));
    CHECK(std::abs(CellOpacityAt(false, 0.3).grey - 0.7) < 1e-9 && std::abs(CellOpacityAt(false, 0.3).lit - 0.3) < 1e-9);
    CHECK(CellOpacityAt(true, 1) == (CellOpacity{0, 1}));
    CHECK(std::abs(CellOpacityAt(true, 0).lit - 0.23) < 1e-6 && CellOpacityAt(true, 0).grey == 0);
    // Along a settle each layer is the light's opacity at every point, ending at rest.
    const LinearLit light = HighlightAlongSettle(0, 1, {0, 1}, 240, 0, 240);  // the space you left
    for (bool dot : {false, true}) {
        const CellOpacityAlong along = CellOpacityAlongSettle(dot, light);
        for (double s : {240.0, 100.0, 7.5, 0.0}) {
            const CellOpacity at = CellOpacityAt(dot, light.At(s));
            CHECK(std::abs(along.grey.At(s) - at.grey) < 1e-9 && std::abs(along.lit.At(s) - at.lit) < 1e-9);
        }
        CHECK(along.lit.At(0) == CellOpacityAt(dot, 0).lit);
    }
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
    CHECK(!SpaceTipOf(space, 10).number && SpaceTipOf(space, 10).keys.empty());
    CHECK(SpaceTipOf(space, 9).number == 9u);
    // The Mac's ⌃3 is Alt+3 on Windows.
    CHECK((tip.keys == std::vector<std::string>{"Alt", "3"}));
}

TEST(aTipNamesTheSpacesProfile) {
    // SpaceCellView's profileName: state.profile(space.profile).name, the default's "Default"
    // for the default folder or a profile that has gone.
    BrowserState state;
    Space a, b, c;
    a.id = "a";
    b.id = "b";
    c.id = "c";
    b.extra["profile"] = json::Value(std::string("Profile 1"));
    c.extra["profile"] = json::Value(std::string("Profile 9"));
    state.spaces = {a, b, c};
    state.extra["profiles"] = json::Value(json::Array{json::Value(json::Object{{"directory", json::Value(std::string("Profile 1"))},
                                                                              {"name", json::Value(std::string("Komado"))}})});
    CHECK(SpaceTipOf(state, 0).profile == "Default");
    CHECK(SpaceTipOf(state, 1).profile == "Komado" && SpaceTipOf(state, 1).number == 2u);
    CHECK(SpaceTipOf(state, 2).profile == "Default");
}

TEST(aTipLaysOutItsNameChipAndKeysInOneLine) {
    // SpaceTip: HStack(spacing: 8) in 10pt of padding, 28pt tall; the chip 21pt with 7pt inside
    // and 4pt from the face to the name; keycaps 18pt square 3pt apart, wider for "Alt".
    Space space;
    space.name = "Work";
    const SpaceTip tip = SpaceTipOf(space, 3, "Default");
    const SpaceTipLayout layout = LayOutSpaceTip(tip, SpaceTipWidths{30, 11, 40, {19, 7}});
    CHECK(layout.nameX == 10 && layout.height == 28);
    CHECK(layout.chip && *layout.chip == (BarRect{48, 3.5f, 117, 24.5f}));
    CHECK(layout.chipSymbolX == 55 && layout.chipTextX == 70);
    CHECK(layout.keys.size() == 2);
    CHECK(layout.keys[0] == (BarRect{125, 5, 152, 23}));  // "Alt": 19 + 4 either side
    CHECK(layout.keys[1] == (BarRect{155, 5, 173, 23}));  // a digit fits 18
    CHECK(layout.width == 183);
    // Without a profile or keys (a tenth space in an incognito window): the name alone.
    SpaceTip bare = SpaceTipOf(space, 10);
    const SpaceTipLayout alone = LayOutSpaceTip(bare, SpaceTipWidths{30, 0, 0, {}});
    CHECK(!alone.chip && alone.keys.empty() && alone.width == 50);
}

TEST(aTipSitsCentredJustAboveItsCellOnWholePixels) {
    // SpaceTipWindow: x (cell.midX - width / 2).rounded(), its bottom 2pt above the cell; it may
    // start left of the window (Arc's reaches past the browser window's edge).
    const BarRect cell{60, 790, 96, 824};
    CHECK(SpaceTipOrigin(cell, 183, 28, 2) == (TipOrigin{-13.5f, 760}));
    CHECK(SpaceTipOrigin(cell, 100, 28, 2) == (TipOrigin{28, 760}));
    // At 125%, on a pixel: 78 - 91.7 = -13.7pt is -17.125px, so -17px.
    const TipOrigin odd = SpaceTipOrigin(cell, 183.4f, 28, 1.25f);
    CHECK(std::abs(odd.x * 1.25f - std::round(odd.x * 1.25f)) < 1e-4f && std::abs(odd.x * 1.25f + 17) < 1e-4f);
}

TEST(aTipFadesInOnCoreAnimationsDefaultCurve) {
    // The Mac's panel alpha (CGWindowListCopyWindowInfo, every 6-10 ms) fits kCAMediaTimingFunctionDefault
    // over 0.15 s ten times better than easeInEaseOut, easeOut or linear.
    const double* c = kDefaultTiming;
    CHECK(TimingCurveAt(c[0], c[1], c[2], c[3], 0) == 0 && TimingCurveAt(c[0], c[1], c[2], c[3], 1) == 1);
    // Fast start, long settle: past 80% at half the time.
    CHECK(TimingCurveAt(c[0], c[1], c[2], c[3], 0.5) > 0.8);
    // linear: y = x.
    CHECK(std::abs(TimingCurveAt(0, 0, 1, 1, 0.3) - 0.3) < 1e-6);
    const double duration = space_tip_metrics::kFadeIn;
    const auto segments = TimingCurveSegments(c[0], c[1], c[2], c[3], duration);
    CHECK(segments.size() == 8 && segments.front().begin == 0);
    double worst = 0;
    for (int i = 0; i <= 300; ++i) {
        const double t = duration * i / 300;
        auto it = std::upper_bound(segments.begin(), segments.end(), t, [](double v, const CubicSegment& s) { return v < s.begin; });
        const CubicSegment& s = *std::prev(it);
        const double u = t - s.begin;
        const double v = s.constant + u * (s.linear + u * (s.quadratic + u * s.cubic));
        worst = std::max(worst, std::abs(v - TimingCurveAt(c[0], c[1], c[2], c[3], t / duration)));
    }
    CHECK(worst < 0.002);
}
