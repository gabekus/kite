#pragma once
// Two fingers swiping sideways over the sidebar page between spaces: what the Mac's
// SpaceSwipeController.handle decides of each scroll event, platform-free. A gesture is the
// swipe's when its first movement over the sidebar is more sideways than up or down; one that
// starts vertically scrolls the tab list for its whole length; a swipe's momentum after the
// fingers lift is swallowed. The caller does what each step says (the pages, the theme, the
// release's settle) from the swipe it shows.

#include <functional>
#include <optional>

#include "core/SpaceSwipe.h"

namespace kite {

// One event of a touchpad's scroll (the Mac's NSEvent phase and momentumPhase).
struct SwipeInput {
    enum class Phase {
        Began,          // fingers down: the gesture starts (there may be no movement yet)
        Changed,        // the fingers moved
        Ended,          // the fingers lifted
        Cancelled,      // the system took the gesture back
        Momentum,       // the scroll carrying on after the fingers lifted
        MomentumEnded,  // and coming to rest
    };
    Phase phase = Phase::Changed;
    // How far the content moved this event, in points, as the fingers drag it: positive dx moves
    // the pages right (towards the previous space), positive dy moves the list down (back
    // towards its top).
    double dx = 0, dy = 0;
    double time = 0;  // seconds, any clock
};

// The spaces as a swipe begins: the page width (the sidebar's), whether there's a space either
// side of the selected one, and where the pages are (a settle caught mid-way).
struct SwipeStart {
    double pageWidth = 0;
    bool hasPrevious = false, hasNext = false;
    double travel = 0;
};

class SpaceSwipeGesture {
public:
    enum class Step {
        Pass,     // not the swipe's: a vertical gesture's scroll (dy) is the list's
        Swallow,  // the swipe's, with nothing to show (its momentum)
        Move,     // the pages and the theme follow Swipe()
        Release,  // let go: Landing() is where it lands
    };
    // The step for `input`, the pointer `overSidebar`. A swipe begins on the gesture's first
    // movement that is more sideways than vertical, over the sidebar; `begin` is asked for the
    // spaces then (after the caller has landed any settle it catches).
    Step Handle(const SwipeInput& input, bool overSidebar, const std::function<SwipeStart()>& begin);

    // Whether the last Handle asked where the pointer was, as the Mac asks isOverSidebar: for a
    // gesture's began, or its movement before the gesture is decided. Off the sidebar then, the
    // gesture isn't Kite's; asked nothing (the rest of a vertical gesture, its momentum), it
    // stays the list's wherever the pointer has gone.
    bool AskedWhere() const { return askedWhere_; }
    // The gesture was decided vertical (the list's), until the next one begins.
    bool Vertical() const { return vertical_; }
    // The swipe the fingers are making, until they let go.
    const std::optional<SpaceSwipe>& Swipe() const { return swipe_; }
    bool Swiping() const { return swipe_.has_value(); }
    // The last release's landing, relative to the selected space: -1, 0 or +1 (0 when cancelled).
    int Landing() const { return landing_; }
    // The spaces changed under the swipe (SpaceSwipeController.cancel): it's dropped, and the rest
    // of its gesture is swallowed rather than starting a new swipe from whatever space is
    // selected now, until a new gesture begins.
    void Abandon();

private:
    std::optional<SpaceSwipe> swipe_;
    // After the fingers lift, the touchpad's momentum events still belong to the swipe.
    bool swallowingMomentum_ = false;
    // A gesture that started vertically scrolls the tab list for its whole length.
    bool vertical_ = false;
    bool abandoned_ = false;  // the rest of an abandoned gesture is the swipe's, showing nothing
    bool askedWhere_ = false;  // by the last Handle
    int landing_ = 0;
};

}  // namespace kite
