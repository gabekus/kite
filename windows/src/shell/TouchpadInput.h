#pragma once
// A precision touchpad's two-finger scrolls over the sidebar, through DirectManipulation: the
// gesture's phases (fingers down, moving, lifted) and its momentum after they lift, which the
// window's wheel messages don't carry, as the Mac's NSEvent phase and momentumPhase do (core's
// SwipeInput, for SpaceSwipeGesture).
//
// The window asks on DM_POINTERHITTEST: a contact it takes (a touchpad's, over the sidebar) is
// DirectManipulation's until the fingers lift and its momentum ends, and makes no wheel messages
// meanwhile; the rest go on as the system's wheel messages. The viewport runs on manual updates
// (Chromium's way): the caller calls Update once a frame while Active, and hears what moved.
// What moved is the content's travel, which follows the fingers as Windows' touchpad scrolling
// direction setting has it.

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

#include "core/SpaceSwipeGesture.h"

struct IDirectManipulationManager;
struct IDirectManipulationUpdateManager;
struct IDirectManipulationViewport;

namespace kite {

class TouchpadInput {
public:
    // Null with `error` when there's no DirectManipulation (no touchpad is fine: it never
    // hears anything). `input` runs on the window's thread, from Update.
    static std::unique_ptr<TouchpadInput> Create(HWND window, std::function<void(const SwipeInput&)> input, std::wstring& error);
    ~TouchpadInput();
    TouchpadInput(const TouchpadInput&) = delete;
    TouchpadInput& operator=(const TouchpadInput&) = delete;

    // The window's DM_POINTERHITTEST (its wParam): a touchpad's contact is taken (true) when
    // `take` (the point, in client px) says so.
    bool HitTest(WPARAM wParam, const std::function<bool(POINT)>& take);
    // Where the contact taken last was, in client px.
    POINT Contact() const { return contact_; }
    // A gesture or its momentum is under way, or a contact was just taken: Update once a frame.
    bool Active() const;
    void Update();
    // The window's px per point (its DPI / 96): what moved is reported in points.
    void SetScale(float scale) { scale_ = scale > 0 ? scale : 1; }

private:
    class Handler;
    // The event handler's: DirectManipulation's state and its content's transform changed.
    void StatusChanged(int current, int previous);
    void ContentMoved(float x, float y);
    TouchpadInput(HWND window, std::function<void(const SwipeInput&)> input) : window_(window), input_(std::move(input)) {}
    std::wstring Init();
    void Emit(SwipeInput::Phase phase, double dx, double dy);
    // The primary content's translation now, in px.
    bool ContentTransform(float& x, float& y) const;
    // The viewport back over the content's middle, after a gesture.
    void Recentre();

    HWND window_;
    std::function<void(const SwipeInput&)> input_;
    IDirectManipulationManager* manager_ = nullptr;
    IDirectManipulationUpdateManager* updates_ = nullptr;
    IDirectManipulationViewport* viewport_ = nullptr;
    Handler* handler_ = nullptr;
    DWORD cookie_ = 0;
    bool activated_ = false;

    enum class Gesture { None, Running, Inertia };
    Gesture gesture_ = Gesture::None;
    // The content's transform as last heard, in px.
    float lastX_ = 0, lastY_ = 0;
    bool baseline_ = false;  // lastX_/lastY_ are this gesture's
    float scale_ = 1;
    POINT contact_{};
    // A contact taken waits for DirectManipulation's first word for this long (s), updating.
    double pollUntil_ = 0;
};

}  // namespace kite
