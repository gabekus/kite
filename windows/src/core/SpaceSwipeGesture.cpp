// See SpaceSwipeGesture.h.

#include "core/SpaceSwipeGesture.h"

#include <cmath>

namespace kite {

SpaceSwipeGesture::Step SpaceSwipeGesture::Handle(const SwipeInput& input, bool overSidebar,
                                                  const std::function<SwipeStart()>& begin) {
    using Phase = SwipeInput::Phase;
    const bool momentum = input.phase == Phase::Momentum || input.phase == Phase::MomentumEnded;
    if (swallowingMomentum_) {
        if (!momentum) {
            swallowingMomentum_ = false;
        } else {
            if (input.phase == Phase::MomentumEnded) swallowingMomentum_ = false;
            return Step::Swallow;
        }
    }

    if (!swipe_) {
        if (input.phase == Phase::Began) vertical_ = false;
        if (input.phase != Phase::Began && (input.phase != Phase::Changed || vertical_)) return Step::Pass;
        if (!overSidebar) return Step::Pass;
        const double dx = std::abs(input.dx), dy = std::abs(input.dy);
        // No movement yet: decide on the first event that has some.
        if (dx == 0 && dy == 0) return Step::Pass;
        if (dy >= dx) {
            vertical_ = true;
            return Step::Pass;
        }
        const SwipeStart start = begin();
        swipe_.emplace(start.pageWidth, start.hasPrevious, start.hasNext, start.travel);
    }

    if (input.phase == Phase::Began || input.phase == Phase::Changed) {
        swipe_->Move(input.dx, input.time);
        return Step::Move;
    }
    if (input.phase == Phase::Ended || input.phase == Phase::Cancelled) {
        landing_ = input.phase == Phase::Cancelled ? 0 : swipe_->Landing();
        swipe_.reset();
        swallowingMomentum_ = true;
        return Step::Release;
    }
    // Momentum while the fingers are still down (it doesn't come): the swipe's.
    return Step::Swallow;
}

}  // namespace kite
