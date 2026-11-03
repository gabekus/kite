#pragma once
// A precision touchpad's gesture as Windows' DirectManipulation reports it, turned into the
// Mac's scroll phases (SwipeInput) for SpaceSwipeGesture, platform-free so it can be tested.
// DirectManipulation reports the viewport's status (running while fingers move it, inertia
// after they lift, ready at rest) and where its content is, not how far it went; this tracks
// the content between reports and says when the viewport should go back over the content's
// middle after a gesture (shell/TouchpadInput.h does that).

#include <vector>

#include "core/SpaceSwipeGesture.h"

namespace kite {

// DIRECTMANIPULATION_STATUS, by value.
enum class ViewportStatus : int { Building = 0, Enabled = 1, Disabled = 2, Running = 3, Inertia = 4, Ready = 5, Suspended = 6 };

class TouchpadPhases {
public:
    // The viewport went from `previous` to `current` at `time`, its content at (x, y) px: the
    // phases that makes go on `out`. True when the viewport should now go back over the
    // middle (a gesture ended with the content moved off it); the caller then calls Recentred.
    bool StatusChanged(ViewportStatus current, ViewportStatus previous, float x, float y, double time, std::vector<SwipeInput>& out);
    // The content is at (x, y) px at `time`; `scale` is px per point.
    void ContentMoved(float x, float y, float scale, double time, std::vector<SwipeInput>& out);
    // The viewport was asked back over the middle (its content to (0, 0)). However late
    // DirectManipulation applies that, the next gesture's travel counts from there, so the
    // jump back is never movement.
    void Recentred();
    // Fingers moving it, or its momentum.
    bool Moving() const { return gesture_ != Gesture::None; }

private:
    enum class Gesture { None, Running, Inertia };
    Gesture gesture_ = Gesture::None;
    float lastX_ = 0, lastY_ = 0;  // the content as last heard in this gesture, px
    bool recentred_ = false;       // asked back over the middle since the last gesture
};

}  // namespace kite
