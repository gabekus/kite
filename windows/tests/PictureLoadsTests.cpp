// Which space pictures are loaded and what a draw shows (core/PictureLoads.h), the rules
// SpaceIconPainter's worker-fed cache follows. The Mac reads a picture in its layout
// (SpaceIconImages.image(for:)), so it has no such states; these are Windows' own.

#include <set>
#include <string>
#include <vector>

#include "Check.h"
#include "core/PictureLoads.h"

using namespace kite;
using Show = PictureLoads::Show;
using Need = PictureLoads::Need;

TEST(aPictureDrawsNothingUntilItsReadThenItself) {
    PictureLoads loads;
    // The first draw asks; the next ones while it's read don't ask again.
    CHECK(loads.Prepare("a.png", 30, 0) == (Need{Show::Nothing, true}));
    CHECK(loads.Prepare("a.png", 30, 0.1) == (Need{Show::Nothing, false}));
    // The header's size asks too (the worker folds it into the same read).
    CHECK(loads.Prepare("a.png", 36, 0.1) == (Need{Show::Nothing, true}));
    const auto answer = loads.Arrived("a.png", {30, 36}, true, 0.2);
    CHECK(answer.changed && answer.evicted.empty());
    CHECK(loads.Prepare("a.png", 30, 0.3) == (Need{Show::Picture, false}));
    CHECK(loads.Shows("a.png", 36) == Show::Picture);
}

TEST(anUnreadablePictureKeepsItsPlaceholderWhileItsLookedForAgain) {
    PictureLoads loads;
    loads.Prepare("gone.png", 30, 0);
    CHECK(loads.Arrived("gone.png", {30}, false, 0.1).changed);
    // Redraws within 2 s show the placeholder and don't ask.
    CHECK(loads.Prepare("gone.png", 30, 1) == (Need{Show::Placeholder, false}));
    // 2 s on, a draw asks again, still showing the placeholder (no blink).
    CHECK(loads.Prepare("gone.png", 30, 2.2) == (Need{Show::Placeholder, true}));
    CHECK(loads.Shows("gone.png", 30) == Show::Placeholder);
    // Still unreadable: nothing changed, so nothing draws again (no loop while idle).
    CHECK(!loads.Arrived("gone.png", {30}, false, 2.3).changed);
    CHECK(loads.Prepare("gone.png", 30, 2.4) == (Need{Show::Placeholder, false}));
    // Back (copied in later): the next ask after 2 s finds it.
    CHECK(loads.Prepare("gone.png", 30, 4.4).ask);
    CHECK(loads.Arrived("gone.png", {30}, true, 4.5).changed);
    CHECK(loads.Shows("gone.png", 30) == Show::Picture);
}

TEST(anInvalidNameIsThePlaceholderWithoutAsking) {
    PictureLoads loads;
    CHECK(loads.Prepare("", 30, 0) == (Need{Show::Placeholder, false}));
    CHECK(loads.Shows("", 30) == Show::Placeholder);
}

TEST(aPictureNoLongerShownDropsItsAnswer) {
    PictureLoads loads;
    // A -> B while A is read: A's late answer is dropped, B still loads.
    loads.Prepare("a.png", 30, 0);
    loads.Retain({"b.png"});
    loads.Prepare("b.png", 30, 0);
    CHECK(!loads.Arrived("a.png", {30}, true, 0.1).changed);
    CHECK(!loads.Known("a.png") && loads.Shows("a.png", 30) == Show::Nothing);
    // ... and back to A: asked again, from scratch.
    loads.Retain({"a.png", "b.png"});
    CHECK(loads.Prepare("a.png", 30, 0.2) == (Need{Show::Nothing, true}));
}

TEST(aPictureKeepsItsTwoLatestSizes) {
    PictureLoads loads;
    loads.Prepare("a.png", 30, 0);
    loads.Prepare("a.png", 36, 0);
    loads.Arrived("a.png", {30, 36}, true, 0);
    // A move to a 125% monitor: 19 and 23px. The 2x sizes go as the new ones come.
    loads.Prepare("a.png", 19, 1);
    auto answer = loads.Arrived("a.png", {19}, true, 1);
    CHECK(answer.changed && answer.evicted == std::vector<unsigned>{30});
    loads.Prepare("a.png", 23, 1);
    answer = loads.Arrived("a.png", {23}, true, 1);
    CHECK(answer.evicted == std::vector<unsigned>{36});
    CHECK(loads.Shows("a.png", 19) == Show::Picture && loads.Shows("a.png", 30) == Show::Nothing);
}
