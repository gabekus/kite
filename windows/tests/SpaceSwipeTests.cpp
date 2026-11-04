// Paging between spaces (core/SpaceSwipe.h): the Mac's SpaceSwipeTests (SpacesTests.swift) and
// SpacePagingTests, case for case, plus the theme crossfade's timing.

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "Check.h"
#include "core/SpaceSwipe.h"

using namespace kite;

// SpaceSwipeTests

TEST(pagesFollowTheFingersTowardsANeighbour) {
    SpaceSwipe swipe(300, true, true);
    swipe.Move(-120, 1);
    CHECK(swipe.Offset() == -120);
    CHECK(swipe.Direction() == 1);
    CHECK(std::abs(swipe.Progress() - 0.4) < 1e-9);
}

TEST(pagesNeverPassAWholePage) {
    SpaceSwipe swipe(300, true, true);
    swipe.Move(500, 1);
    CHECK(swipe.Offset() == 300);
    CHECK(swipe.Progress() == 1);
}

TEST(pastTheLastSpaceItRubberBands) {
    SpaceSwipe swipe(300, true, false);
    swipe.Move(-300, 1);
    CHECK(swipe.Offset() < 0 && swipe.Offset() > -300 * 0.4);
    CHECK(swipe.Direction() == 0);
    CHECK(swipe.Progress() == 0);
    CHECK(swipe.Landing() == 0);
}

TEST(halfAPageLandsOnTheNeighbour) {
    SpaceSwipe shortSwipe(300, true, true);
    shortSwipe.Move(140, 1);
    CHECK(shortSwipe.Landing() == 0);
    SpaceSwipe far(300, true, true);
    far.Move(160, 1);
    CHECK(far.Landing() == -1);
}

TEST(aFlickGoesHoweverShort) {
    SpaceSwipe swipe(300, true, true);
    // 20pt every 10ms: 2000 points a second towards the next space.
    for (int i = 1; i <= 3; ++i) swipe.Move(-20, i * 0.01);
    CHECK(swipe.Landing() == 1);
}

TEST(aFlickBackStaysPut) {
    SpaceSwipe swipe(300, true, true);
    swipe.Move(-200, 0);
    for (int i = 1; i <= 4; ++i) swipe.Move(20, i * 0.01);
    CHECK(swipe.Offset() == -120);
    CHECK(swipe.Landing() == 0);
}

// Not in the Mac's suite: the edges of the model.

TEST(rubberBandingIsSymmetricAndBounded) {
    CHECK(SpaceSwipe::RubberBand(0, 300) == 0);
    CHECK(SpaceSwipe::RubberBand(-120, 300) == -SpaceSwipe::RubberBand(120, 300));
    CHECK(SpaceSwipe::RubberBand(1e9, 300) < 300);
    // Past the first space too, and a release there stays.
    SpaceSwipe swipe(300, false, true);
    swipe.Move(200, 1);
    CHECK(swipe.Offset() > 0 && swipe.Offset() < 200);
    CHECK(swipe.Direction() == 0);
    CHECK(swipe.Landing() == 0);
}

TEST(aSwipeCaughtMidSettleStartsWhereThePagesAre) {
    SpaceSwipe swipe(300, true, true, -90);
    CHECK(swipe.Offset() == -90);
    CHECK(swipe.Direction() == 1);
    // No velocity before a second event, and a page width under a point counts as one.
    swipe.Move(-10, 5);
    CHECK(swipe.Velocity() == 0);
    CHECK(SpaceSwipe(0, true, true).PageWidth() == 1);
}

// SpacePagingTests

TEST(settleIsCriticallyDampedAndLands) {
    CHECK(SpaceSwipe::Settle(240, 0, 0.1) == 240);
    // No overshoot: it never crosses rest on the way in.
    double last = 240;
    for (int step = 1; step <= 40; ++step) {
        const double x = SpaceSwipe::Settle(240, step / 120.0, 0.1);
        CHECK(x >= 0 && x <= last);
        last = x;
    }
    // Arc's slide: about 97% of the way 0.09s in, at rest by 0.2s.
    CHECK(std::abs(SpaceSwipe::Settle(240, 0.09, 0.1)) < 240 * 0.04);
    CHECK(SpaceSwipe::Settle(240, 0.25, 0.1) == 0);
}

TEST(builtPagesKeepNeighboursAndTheAnchor) {
    using Pages = std::vector<size_t>;
    CHECK(SpaceSwipe::BuiltPages(0, std::nullopt, 3) == (Pages{0, 1}));
    CHECK(SpaceSwipe::BuiltPages(1, std::nullopt, 3) == (Pages{0, 1, 2}));
    // Mid-settle after landing on 2: the pages left behind stay, nothing new is built.
    CHECK(SpaceSwipe::BuiltPages(2, 1, 4) == (Pages{0, 1, 2}));
    // A far jump keeps the old neighbourhood and adds the new space.
    CHECK(SpaceSwipe::BuiltPages(4, 0, 6) == (Pages{0, 1, 4}));
    CHECK(SpaceSwipe::BuiltPages(0, std::nullopt, 0).empty());
    // Not in the Mac's suite: one space, and the last one.
    CHECK(SpaceSwipe::BuiltPages(0, std::nullopt, 1) == (Pages{0}));
    CHECK(SpaceSwipe::BuiltPages(2, std::nullopt, 3) == (Pages{1, 2}));
}

TEST(highlightHandsOverWithTheSlide) {
    const std::vector<size_t> built{0, 1, 2};
    const auto lit = [&](size_t i, double offset) { return SpaceSwipe::Highlight(i, 1, built, offset, 200); };
    CHECK(lit(1, 0) == 1);
    CHECK(lit(2, 0) == 0);
    // Halfway towards the next space.
    CHECK(std::abs(lit(1, -100) - 0.5) < 1e-9);
    CHECK(std::abs(lit(2, -100) - 0.5) < 1e-9);
    CHECK(lit(0, -100) == 0);
    // Rubber-banding past the first space keeps it fully lit.
    const std::vector<size_t> first{0, 1};
    CHECK(SpaceSwipe::Highlight(0, 0, first, 60, 200) == 1);
    CHECK(lit(1, 0) + lit(0, 0) + lit(2, 0) == 1);
    // Not in the Mac's suite: a page that isn't built is never lit, and no width lights the selection.
    CHECK(SpaceSwipe::Highlight(3, 1, built, -200, 200) == 0);
    CHECK(SpaceSwipe::Highlight(1, 1, built, 0, 0) == 1);
}

// The theme's crossfade (ThemeView.spring, ArcMetrics.Motion.spaceSwitch*).

TEST(theThemeCrossfadeSettlesWithinItsDuration) {
    CHECK(ThemeCrossfadeProgress(0) == 0);
    CHECK(ThemeCrossfadeProgress(-1) == 0);
    CHECK(ThemeCrossfadeProgress(space_motion::kThemeDuration) == 1);
    // Within half a percent of the end by then, and past halfway early (response 0.15 s).
    CHECK(ThemeCrossfadeProgress(space_motion::kThemeDuration - 1e-6) > 0.995);
    CHECK(ThemeCrossfadeProgress(0.05) > 0.5);
    // A let-go swipe starts from its progress and doesn't go back.
    CHECK(ThemeCrossfadeProgress(0, 0.4) == 0.4);
    double last = 0.4;
    for (int frame = 1; frame <= 36; ++frame) {
        const double p = ThemeCrossfadeProgress(frame / 120.0, 0.4);
        // Damping 0.95 overshoots by under 1e-4, which the clamp at 1 cuts off.
        CHECK(p >= last - 1e-4 && p <= 1);
        last = p;
    }
}

// The crossfade's state (ThemeView.setTheme): what an interruption does.

namespace {
Theme Solid(unsigned hex) { return Theme::Make({ThemeColor::FromHex(hex)}, 0, 1); }
}  // namespace

TEST(aCrossfadeComesToRestOnItsTheme) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    CHECK(!fade.Fading() && fade.Progress(5) == 1);
    CHECK(fade.Set(b, 10));
    CHECK(fade.from == a && fade.to == b && fade.Fading());
    CHECK(fade.Progress(10) == 0);
    CHECK(fade.Progress(10.1) > 0 && fade.Progress(10.1) < 1);
    CHECK(fade.Fading());
    // From its duration on it's at rest on the new theme.
    CHECK(fade.Progress(10 + space_motion::kThemeDuration) == 1);
    CHECK(!fade.Fading() && fade.from == b && fade.to == b);
}

TEST(theSameThemeIsNoCrossfade) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    CHECK(!fade.Set(a, 1));
    CHECK(!fade.Fading());
    // Asked again for the theme it's going to: the fade carries on from when it began.
    CHECK(fade.Set(b, 2));
    CHECK(!fade.Set(b, 2.1));
    CHECK(fade.start == 2.0);
}

TEST(anEarlyInterruptionCarriesOnFromTheSideShowingMore) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC), c = Solid(0x445566);
    // 0.1 s in (under half of 0.3 s): `a` still shows more, so the fade to `c` starts from it.
    ThemeCrossfade fade(a);
    fade.Set(b, 0);
    CHECK(fade.Set(c, 0.1));
    CHECK(fade.from == a && fade.to == c && fade.start == 0.1);
    CHECK(fade.Progress(0.1) == 0);
}

TEST(aLateInterruptionCarriesOnFromTheNewTheme) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC), c = Solid(0x445566);
    // 0.2 s in (past halfway): `b` shows more.
    ThemeCrossfade fade(a);
    fade.Set(b, 0);
    CHECK(fade.Set(c, 0.2));
    CHECK(fade.from == b && fade.to == c && fade.start == 0.2);
}

TEST(goingBackEarlyIsNoCrossfade) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.Set(b, 0);
    // Back to `a` 0.1 s in: `a` was showing more, so it's simply there.
    CHECK(!fade.Set(a, 0.1));
    CHECK(!fade.Fading() && fade.from == a && fade.to == a && fade.Progress(0.1) == 1);
    // Back after halfway: a real fade from `b`.
    fade.Set(b, 1);
    CHECK(fade.Set(a, 1.2));
    CHECK(fade.from == b && fade.to == a);
}

TEST(aSnapEndsAFade) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.Set(b, 0);
    fade.Snap(a);
    CHECK(!fade.Fading() && fade.from == a && fade.to == a);
}

// The settle as compositor segments (not in the Mac's suite: the Mac steps it per frame).

TEST(theSettlesSegmentsFollowTheSpring) {
    for (double from : {240.0, -240.0, 37.5}) {
        const double end = SettleDuration(from, space_motion::kPageResponse);
        CHECK(SpaceSwipe::Settle(from, end, space_motion::kPageResponse) == 0);
        CHECK(SpaceSwipe::Settle(from, end * 0.99, space_motion::kPageResponse) != 0);
        const auto segments = SettleSegments(from, space_motion::kPageResponse);
        CHECK(segments.size() == 16);
        CHECK(segments.front().begin == 0 && segments.front().constant == from);
        double worst = 0;
        for (int k = 0; k < 2000; ++k) {
            const double t = end * k / 2000;
            const double spring = from * (1 + 2 * 3.14159265358979323846 / 0.1 * t) * std::exp(-2 * 3.14159265358979323846 / 0.1 * t);
            worst = std::max(worst, std::abs(ValueAt(segments, end, t) - spring));
        }
        CHECK(worst < 0.05);
        CHECK(ValueAt(segments, end, end) == 0);
    }
    // Arc's slide from a page away is at rest within 0.2 s; at rest there's nothing to animate.
    CHECK(SettleDuration(240, space_motion::kPageResponse) < 0.2);
    CHECK(SettleDuration(0.05, space_motion::kPageResponse) == 0);
    CHECK(SettleSegments(0, space_motion::kPageResponse).empty());
}

// The crossfade following a swipe (ThemeView.setInteractiveTheme, finishInteractiveTheme).

TEST(aSwipesCrossfadeFollowsTheFingers) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 0.4f);
    CHECK(fade.Interactive() && !fade.Fading());
    CHECK(fade.from == a && fade.to == b);
    // Held whatever the time: it moves when the fingers do.
    CHECK(fade.Progress(10) == 0.4f && fade.Progress(20) == 0.4f);
    fade.SetInteractive(a, b, 1.5f);
    CHECK(fade.Progress(0) == 1);
    // A switch mid-swipe waits for the release.
    CHECK(!fade.Set(Solid(0x445566), 1));
    CHECK(fade.Interactive() && fade.to == b);
}

TEST(aReleasedSwipeSettlesFromWhereTheFingersLeftIt) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 0.6f);
    fade.FinishInteractive(b, 5);
    CHECK(!fade.Interactive() && fade.Fading());
    CHECK(fade.from == a && fade.to == b);
    CHECK(std::abs(fade.Progress(5) - 0.6f) < 1e-6);
    CHECK(fade.Progress(5.05) > 0.6f);
    CHECK(fade.Progress(5.5) == 1);
    CHECK(!fade.Fading() && fade.from == b && fade.to == b);
    // The next switch starts from nothing again.
    CHECK(fade.Set(a, 6));
    CHECK(fade.Progress(6) == 0);
}

TEST(aSwipeLetGoBackSettlesOnTheThemeItLeft) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 0.3f);
    fade.FinishInteractive(a, 1);
    // The same mix read from the other end: 30% of the way to `b` is 70% of the way back.
    CHECK(fade.from == b && fade.to == a);
    CHECK(std::abs(fade.Progress(1) - 0.7f) < 1e-6);
    CHECK(fade.Progress(1.5) == 1);
    CHECK(fade.from == a && fade.to == a);
}

TEST(aSwipeBetweenOneThemeFadesNothing) {
    const Theme a = Solid(0x112233);
    ThemeCrossfade fade(a);
    // Past the last space (or to a neighbour with the same theme): the progress never moves.
    fade.SetInteractive(a, a, 0.2f);
    const float held = fade.Progress(0);
    fade.SetInteractive(a, a, 0.7f);
    CHECK(fade.Progress(0) == held);
    // And the release is at rest at once: no frames for a fade between identical themes.
    fade.FinishInteractive(a, 1);
    CHECK(!fade.Fading() && !fade.Interactive() && fade.from == a && fade.to == a && fade.Progress(1) == 1);
}

TEST(aSpaceSelectedUnderTheSwipeSettlesOnItsTheme) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC), c = Solid(0x445566);
    // Swiping from a towards b, 30% in, when the keyboard selects c: c fades in from a.
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 0.3f);
    fade.FinishInteractive(c, 2);
    CHECK(fade.from == a && fade.to == c && fade.Fading() && fade.Progress(2) == 0);
    CHECK(fade.Progress(3) == 1 && fade.from == c);
    // Past halfway it comes from b.
    fade.SetInteractive(c, b, 0.8f);
    fade.FinishInteractive(a, 4);
    CHECK(fade.from == b && fade.to == a);
}

TEST(aSwipeLetGoAlreadyThereFadesNothing) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 1.0f);
    fade.FinishInteractive(b, 1);
    CHECK(!fade.Fading() && fade.from == b && fade.to == b);
    fade.SetInteractive(b, a, 0.0f);
    fade.FinishInteractive(b, 2);
    CHECK(!fade.Fading() && fade.from == b && fade.to == b);
}

TEST(aSnapEndsASwipesCrossfade) {
    const Theme a = Solid(0x112233), b = Solid(0xAABBCC);
    ThemeCrossfade fade(a);
    fade.SetInteractive(a, b, 0.5f);
    fade.Snap(b);
    CHECK(!fade.Interactive() && !fade.Fading() && fade.from == b && fade.to == b && fade.Progress(0) == 1);
}

// SpacesTests' neighbour guard (SpaceSwipe.Neighbours), which the controller checks on every
// swipe event and its release.
TEST(neighboursAreCapturedByID) {
    const std::vector<std::string> ids{"A", "B", "C"};
    const auto first = SpaceSwipe::Neighbours::Make(ids, 0);
    CHECK(first && !first->previous && first->current == "A" && first->next == "B");
    const auto last = SpaceSwipe::Neighbours::Make(ids, 2);
    CHECK(last && last->Towards(-1) == "B" && !last->Towards(1));
    CHECK(!SpaceSwipe::Neighbours::Make(ids, 3));
    CHECK(!SpaceSwipe::Neighbours::Make({}, 0));
}

TEST(aSwipeWhoseSpacesChangedHasNoTarget) {
    const std::vector<std::string> ids{"A", "B", "C"};
    const SpaceSwipe::Neighbours swipe = *SpaceSwipe::Neighbours::Make(ids, 2);
    CHECK(swipe.Target(-1, ids, "C") == "B");
    // The neighbour was deleted mid-swipe: the old index would now be out of range.
    CHECK(!swipe.Target(-1, {"A", "C"}, "C"));
    // The space it started on was deleted.
    CHECK(!swipe.Target(0, {"A", "B"}, "B"));
    // Something else switched space (a shortcut, a click in the bar).
    CHECK(!swipe.Target(0, ids, "A"));
    // Moved but still its neighbour on that side: found by id.
    CHECK(swipe.Target(-1, {"B", "C", "A"}, "C") == "B");
    // Moved to the other side, or away: the pages on screen are no longer its neighbours.
    CHECK(!swipe.Target(-1, {"C", "B", "A"}, "C"));
    CHECK(!swipe.Target(-1, {"B", "A", "C"}, "C"));
}
