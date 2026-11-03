// Paging between spaces (core/SpaceSwipe.h): the Mac's SpaceSwipeTests (SpacesTests.swift) and
// SpacePagingTests, case for case, plus the theme crossfade's timing.

#include <cmath>
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
