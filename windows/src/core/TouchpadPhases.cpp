#include "core/TouchpadPhases.h"

#include <cmath>

namespace kite {

namespace {
// Under this many px off the middle is at it.
constexpr float kAtMiddle = 0.01f;
}  // namespace

bool TouchpadPhases::StatusChanged(ViewportStatus current, ViewportStatus previous, float x, float y, double time,
                                   std::vector<SwipeInput>& out) {
    using Phase = SwipeInput::Phase;
    if (current == previous) return false;
    if (current == ViewportStatus::Running) {
        // Fingers down again mid-momentum: that ends, and a gesture of its own begins.
        if (gesture_ == Gesture::Inertia) out.push_back(SwipeInput{Phase::MomentumEnded, 0, 0, time});
        if (gesture_ == Gesture::Running) return false;
        gesture_ = Gesture::Running;
        // Where the content starts from: the middle when it was sent back there (applied by
        // now or not), else where it is.
        lastX_ = recentred_ ? 0 : x;
        lastY_ = recentred_ ? 0 : y;
        recentred_ = false;
        out.push_back(SwipeInput{Phase::Began, 0, 0, time});
        return false;
    }
    if (current == ViewportStatus::Inertia) {
        if (gesture_ == Gesture::Running) out.push_back(SwipeInput{Phase::Ended, 0, 0, time});
        if (gesture_ != Gesture::None) gesture_ = Gesture::Inertia;
        return false;
    }
    // At rest, or the system took the viewport away mid-gesture.
    const Gesture was = gesture_;
    gesture_ = Gesture::None;
    if (was == Gesture::Running) {
        out.push_back(SwipeInput{current == ViewportStatus::Ready ? Phase::Ended : Phase::Cancelled, 0, 0, time});
    } else if (was == Gesture::Inertia) {
        out.push_back(SwipeInput{Phase::MomentumEnded, 0, 0, time});
    }
    // Only a gesture that moved it: going back to the middle is itself a running-then-ready
    // pass, which asks nothing more.
    return current == ViewportStatus::Ready && was != Gesture::None && (std::abs(lastX_) > kAtMiddle || std::abs(lastY_) > kAtMiddle);
}

void TouchpadPhases::ContentMoved(float x, float y, float scale, double time, std::vector<SwipeInput>& out) {
    // Only a gesture's movement: the viewport going back to the middle is none.
    if (gesture_ == Gesture::None) return;
    const float dx = x - lastX_, dy = y - lastY_;
    lastX_ = x;
    lastY_ = y;
    if (dx == 0 && dy == 0) return;
    const double points = scale > 0 ? scale : 1;
    out.push_back(SwipeInput{gesture_ == Gesture::Running ? SwipeInput::Phase::Changed : SwipeInput::Phase::Momentum, dx / points,
                             dy / points, time});
}

void TouchpadPhases::Recentred() {
    recentred_ = true;
    lastX_ = lastY_ = 0;
}

}  // namespace kite
