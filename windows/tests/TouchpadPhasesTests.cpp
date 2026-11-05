// DirectManipulation's statuses and content as the Mac's scroll phases (core/TouchpadPhases.h):
// the sequences a precision touchpad's gestures make, the viewport's reset among them.

#include <vector>

#include "Check.h"
#include "core/TouchpadPhases.h"

using namespace kite;

namespace {
using Phase = SwipeInput::Phase;
using S = ViewportStatus;

std::vector<Phase> Phases(const std::vector<SwipeInput>& events) {
    std::vector<Phase> phases;
    for (const SwipeInput& e : events) phases.push_back(e.phase);
    return phases;
}
}  // namespace

TEST(aGestureWithMomentumMakesTheMacsPhases) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    CHECK(!phases.StatusChanged(S::Running, S::Ready, 0, 0, 1, out));
    CHECK(phases.Moving());
    phases.ContentMoved(-30, 4, 2, 1.016, out);   // px, at 2 px a point
    phases.ContentMoved(-30, 4, 2, 1.032, out);   // no movement: nothing
    phases.ContentMoved(-50, 4, 2, 1.048, out);
    CHECK(!phases.StatusChanged(S::Inertia, S::Running, -50, 4, 1.05, out));
    phases.ContentMoved(-60, 4, 2, 1.066, out);
    const bool recentre = phases.StatusChanged(S::Ready, S::Inertia, -60, 4, 1.2, out);
    CHECK(recentre && !phases.Moving());
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Changed, Phase::Changed, Phase::Ended, Phase::Momentum,
                                             Phase::MomentumEnded}));
    CHECK(out[1].dx == -15 && out[1].dy == 2 && out[1].time == 1.016);
    CHECK(out[2].dx == -10 && out[2].dy == 0);
    CHECK(out[4].dx == -5);
}

TEST(liftedWithNoMomentumItEnds) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    phases.ContentMoved(10, 0, 1, 0.1, out);
    CHECK(phases.StatusChanged(S::Ready, S::Running, 10, 0, 0.2, out));
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Changed, Phase::Ended}));
}

TEST(aTapThatNeverMovesNeedsNoRecentre) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    CHECK(!phases.StatusChanged(S::Ready, S::Running, 0, 0, 0.1, out));
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Ended}));
}

TEST(fingersDownMidMomentumEndItAndBeginAgain) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    phases.ContentMoved(0, 40, 1, 0.1, out);
    phases.StatusChanged(S::Inertia, S::Running, 0, 40, 0.2, out);
    phases.ContentMoved(0, 60, 1, 0.3, out);
    out.clear();
    phases.StatusChanged(S::Running, S::Inertia, 0, 60, 0.4, out);
    phases.ContentMoved(0, 65, 1, 0.5, out);
    CHECK((Phases(out) == std::vector<Phase>{Phase::MomentumEnded, Phase::Began, Phase::Changed}));
    CHECK(out[2].dy == 5);
}

TEST(theSystemTakingTheViewportMidGestureCancelsIt) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    CHECK(!phases.StatusChanged(S::Suspended, S::Running, 0, 0, 0.1, out));
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Cancelled}));
    // And content reports at rest are no movement.
    out.clear();
    phases.ContentMoved(50, 50, 1, 0.2, out);
    phases.StatusChanged(S::Enabled, S::Suspended, 50, 50, 0.3, out);
    CHECK(out.empty());
}

TEST(theRecentresJumpIsNeverMovement) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    phases.ContentMoved(-400, 0, 1, 0.1, out);
    CHECK(phases.StatusChanged(S::Ready, S::Running, -400, 0, 0.2, out));
    phases.Recentred();
    // The reset's own pass, applied at once: running, the content back at 0, ready.
    out.clear();
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0.21, out);
    phases.ContentMoved(0, 0, 1, 0.21, out);
    CHECK(!phases.StatusChanged(S::Ready, S::Running, 0, 0, 0.22, out));
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Ended}));
}

TEST(aRecentreAppliedLateStillCountsFromTheMiddle) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 0, 0, 0, out);
    phases.ContentMoved(-400, 0, 1, 0.1, out);
    phases.StatusChanged(S::Ready, S::Running, -400, 0, 0.2, out);
    phases.Recentred();
    // The next gesture begins with the content still where the last left it; the reset lands
    // with its first movement.
    out.clear();
    phases.StatusChanged(S::Running, S::Ready, -400, 0, 1, out);
    phases.ContentMoved(6, 0, 1, 1.016, out);
    CHECK((Phases(out) == std::vector<Phase>{Phase::Began, Phase::Changed}));
    CHECK(out[1].dx == 6);
}

TEST(withNoRecentreAGestureCountsFromWhereTheContentIs) {
    TouchpadPhases phases;
    std::vector<SwipeInput> out;
    phases.StatusChanged(S::Running, S::Ready, 120, -8, 0, out);
    phases.ContentMoved(125, -8, 1, 0.016, out);
    CHECK(out.size() == 2 && out[1].dx == 5 && out[1].dy == 0);
}
