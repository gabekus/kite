// Which scroll events page the spaces (core/SpaceSwipeGesture.h): the Mac's
// SpaceSwipeController.handle, case by case (it has no suite of its own on the Mac).

#include <cmath>

#include "Check.h"
#include "core/SpaceSwipeGesture.h"

using namespace kite;

namespace {
using Phase = SwipeInput::Phase;
using Step = SpaceSwipeGesture::Step;

SwipeInput At(Phase phase, double dx, double dy, double time) { return SwipeInput{phase, dx, dy, time}; }

// The middle of three spaces, the pages at rest, 240pt wide.
struct Spaces {
    int begun = 0;
    SwipeStart start{240, true, true, 0};
    std::function<SwipeStart()> Begin() {
        return [this] {
            ++begun;
            return start;
        };
    }
};
}  // namespace

TEST(aSidewaysGestureOverTheSidebarSwipes) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    // Fingers down with no movement yet: undecided.
    CHECK(gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.Swiping() && spaces.begun == 0);
    CHECK(gesture.Handle(At(Phase::Changed, -12, 3, 0.016), true, spaces.Begin()) == Step::Move);
    CHECK(gesture.Swiping() && spaces.begun == 1);
    CHECK(gesture.Swipe()->Offset() == -12);
    CHECK(gesture.Swipe()->Direction() == 1);
    CHECK(gesture.Handle(At(Phase::Changed, -100, 0, 0.5), true, spaces.Begin()) == Step::Move);
    CHECK(gesture.Swipe()->Offset() == -112);
    CHECK(spaces.begun == 1);
}

TEST(aGestureMovingFirstOnItsBeganEventSwipes) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    CHECK(gesture.Handle(At(Phase::Began, 20, 0, 0), true, spaces.Begin()) == Step::Move);
    CHECK(gesture.Swipe()->Offset() == 20 && gesture.Swipe()->Direction() == -1);
}

TEST(aVerticalStartScrollsTheListForTheWholeGesture) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    // As much down as sideways counts as vertical.
    CHECK(gesture.Handle(At(Phase::Changed, 5, 5, 0.016), true, spaces.Begin()) == Step::Pass);
    // Sideways later in the same gesture stays the list's.
    CHECK(gesture.Handle(At(Phase::Changed, 80, 0, 0.032), true, spaces.Begin()) == Step::Pass);
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 0.048), true, spaces.Begin()) == Step::Pass);
    CHECK(gesture.Handle(At(Phase::Momentum, 40, 0, 0.064), true, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.Swiping() && spaces.begun == 0);
    // The next gesture decides afresh.
    gesture.Handle(At(Phase::Began, 0, 0, 1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, 30, 2, 1.016), true, spaces.Begin()) == Step::Move);
}

TEST(onlyGesturesOverTheSidebarSwipe) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), false, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, 30, 0, 0.016), false, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.Swiping());
    // Not decided vertical: the same gesture can still swipe once it's over the sidebar.
    CHECK(gesture.Handle(At(Phase::Changed, 30, 0, 0.032), true, spaces.Begin()) == Step::Move);
}

TEST(wherePointerIsIsAskedOnlyUntilTheGestureIsDecided) {
    // The Mac's isOverSidebar: for began, and for movement before the gesture is decided.
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    CHECK(gesture.AskedWhere());
    // No movement yet: still undecided, still asked.
    gesture.Handle(At(Phase::Changed, 0, 0, 0.008), true, spaces.Begin());
    CHECK(gesture.AskedWhere());
    CHECK(!gesture.Vertical());
    // Decided vertical on this one, asked first.
    CHECK(gesture.Handle(At(Phase::Changed, 1, -6, 0.016), true, spaces.Begin()) == Step::Pass);
    CHECK(gesture.AskedWhere() && gesture.Vertical());
    // The rest of it isn't asked, wherever the pointer is: off the sidebar it's still the list's.
    CHECK(gesture.Handle(At(Phase::Changed, 0, -6, 0.032), false, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 0.048), false, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::Momentum, 0, -4, 0.064), false, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::MomentumEnded, 0, 0, 0.08), false, spaces.Begin()) == Step::Pass);
    CHECK(!gesture.AskedWhere());
    // Off the sidebar before it's decided: asked, and passed. The next gesture is undecided again.
    gesture.Handle(At(Phase::Began, 0, 0, 1), true, spaces.Begin());
    CHECK(!gesture.Vertical());
    CHECK(gesture.Handle(At(Phase::Changed, -20, 0, 1.016), false, spaces.Begin()) == Step::Pass);
    CHECK(gesture.AskedWhere() && !gesture.Swiping());
    // A swipe's own events aren't asked: it's the swipe's wherever the pointer goes.
    CHECK(gesture.Handle(At(Phase::Changed, -20, 0, 1.032), true, spaces.Begin()) == Step::Move);
    CHECK(gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::Changed, -20, 0, 1.048), false, spaces.Begin()) == Step::Move);
    CHECK(!gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 1.064), false, spaces.Begin()) == Step::Release);
    CHECK(!gesture.AskedWhere());
    CHECK(gesture.Handle(At(Phase::Momentum, -10, 0, 1.08), false, spaces.Begin()) == Step::Swallow);
    CHECK(!gesture.AskedWhere());
}

TEST(eventsOutsideAGesturePass) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    CHECK(gesture.Handle(At(Phase::Ended, 30, 0, 0), true, spaces.Begin()) == Step::Pass);
    CHECK(gesture.Handle(At(Phase::Momentum, 30, 0, 0), true, spaces.Begin()) == Step::Pass);
    CHECK(gesture.Handle(At(Phase::MomentumEnded, 0, 0, 0), true, spaces.Begin()) == Step::Pass);
    CHECK(spaces.begun == 0);
}

TEST(aReleasePastHalfAPageLandsOnTheNeighbour) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    // 130pt slowly (no flick): past half of 240.
    for (int i = 1; i <= 13; ++i) gesture.Handle(At(Phase::Changed, -10, 0, i * 0.1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 1.4), true, spaces.Begin()) == Step::Release);
    CHECK(gesture.Landing() == 1 && !gesture.Swiping());
}

TEST(aShortSlowReleaseStays) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    for (int i = 1; i <= 5; ++i) gesture.Handle(At(Phase::Changed, 10, 0, i * 0.1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 0.6), true, spaces.Begin()) == Step::Release);
    CHECK(gesture.Landing() == 0);
}

TEST(aFlickLandsHoweverShort) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    for (int i = 1; i <= 3; ++i) gesture.Handle(At(Phase::Changed, 15, 0, i * 0.01), true, spaces.Begin());
    gesture.Handle(At(Phase::Ended, 0, 0, 0.04), true, spaces.Begin());
    CHECK(gesture.Landing() == -1);
}

TEST(aCancelledGestureGoesBack) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -200, 0, 0.1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Cancelled, 0, 0, 0.2), true, spaces.Begin()) == Step::Release);
    CHECK(gesture.Landing() == 0);
}

TEST(aSwipesMomentumIsSwallowed) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -50, 0, 0.1), true, spaces.Begin());
    gesture.Handle(At(Phase::Ended, 0, 0, 0.2), true, spaces.Begin());
    // Sideways and down alike, until it comes to rest: nothing scrolls the list, nothing swipes.
    CHECK(gesture.Handle(At(Phase::Momentum, -30, 0, 0.216), true, spaces.Begin()) == Step::Swallow);
    CHECK(gesture.Handle(At(Phase::Momentum, 0, 20, 0.232), true, spaces.Begin()) == Step::Swallow);
    CHECK(gesture.Handle(At(Phase::MomentumEnded, 0, 0, 0.3), true, spaces.Begin()) == Step::Swallow);
    CHECK(!gesture.Swiping() && spaces.begun == 1);
    // Then the next gesture's events are its own.
    CHECK(gesture.Handle(At(Phase::Momentum, 0, 20, 0.4), true, spaces.Begin()) == Step::Pass);
}

TEST(aNewGestureEndsTheSwallowing) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -50, 0, 0.1), true, spaces.Begin());
    gesture.Handle(At(Phase::Ended, 0, 0, 0.2), true, spaces.Begin());
    gesture.Handle(At(Phase::Momentum, -30, 0, 0.216), true, spaces.Begin());
    // Fingers down again mid-momentum: a gesture of its own, with no momentum's end first.
    gesture.Handle(At(Phase::Began, 0, 0, 0.3), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, 0, 10, 0.316), true, spaces.Begin()) == Step::Pass);
}

TEST(aSwipeCaughtMidSettleCarriesOnFromThePages) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    spaces.start.travel = -90;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -10, 0, 0.016), true, spaces.Begin());
    CHECK(gesture.Swipe()->Offset() == -100);
}

TEST(pastTheLastSpaceTheSwipeRubberBandsAndStays) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    spaces.start.hasNext = false;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -200, 0, 0.5), true, spaces.Begin());
    CHECK(gesture.Swipe()->Offset() > -200 && gesture.Swipe()->Offset() < 0);
    CHECK(gesture.Swipe()->Direction() == 0 && gesture.Swipe()->Progress() == 0);
    gesture.Handle(At(Phase::Ended, 0, 0, 1), true, spaces.Begin());
    CHECK(gesture.Landing() == 0);
}

// SpaceSwipeController.cancel's abandonedGesture: the spaces changed under the swipe, which is
// dropped; the rest of that gesture shows nothing, and the next one swipes again.
TEST(anAbandonedSwipeSwallowsTheRestOfItsGesture) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, -30, 0, 0.016), true, spaces.Begin()) == Step::Move);
    gesture.Abandon();
    CHECK(!gesture.Swiping() && gesture.Landing() == 0);
    CHECK(gesture.Handle(At(Phase::Changed, -30, 0, 0.032), true, spaces.Begin()) == Step::Swallow);
    CHECK(!gesture.Swiping() && spaces.begun == 1);
    CHECK(gesture.Handle(At(Phase::Ended, 0, 0, 0.048), true, spaces.Begin()) == Step::Swallow);
    // Its momentum is swallowed too, then a new gesture is a swipe of its own.
    CHECK(gesture.Handle(At(Phase::Momentum, -20, 0, 0.064), true, spaces.Begin()) == Step::Swallow);
    CHECK(gesture.Handle(At(Phase::MomentumEnded, 0, 0, 0.08), true, spaces.Begin()) == Step::Swallow);
    gesture.Handle(At(Phase::Began, 0, 0, 1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, -30, 0, 1.016), true, spaces.Begin()) == Step::Move);
    CHECK(spaces.begun == 2);
}

TEST(anAbandonedGestureWhoseEndNeverCameEndsAtTheNextOne) {
    SpaceSwipeGesture gesture;
    Spaces spaces;
    gesture.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin());
    gesture.Handle(At(Phase::Changed, -30, 0, 0.016), true, spaces.Begin());
    gesture.Abandon();
    gesture.Handle(At(Phase::Began, 0, 0, 1), true, spaces.Begin());
    CHECK(gesture.Handle(At(Phase::Changed, -30, 0, 1.016), true, spaces.Begin()) == Step::Move);
    // Abandoning nothing changes nothing.
    SpaceSwipeGesture idle;
    idle.Abandon();
    CHECK(idle.Handle(At(Phase::Began, 0, 0, 0), true, spaces.Begin()) == Step::Pass);
}
