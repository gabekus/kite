#pragma once
// A precision touchpad's two-finger scrolls over the sidebar, through DirectManipulation: the
// gesture's phases (fingers down, moving, lifted) and its momentum after they lift, which the
// window's wheel messages don't carry, as the Mac's NSEvent phase and momentumPhase do (core's
// SwipeInput, for SpaceSwipeGesture).
//
// The window asks on DM_POINTERHITTEST: a contact it takes (a touchpad's, over the sidebar) is
// DirectManipulation's until the fingers lift and its momentum ends, and makes no wheel messages
// meanwhile; the rest go on as the system's wheel messages. The viewport runs on manual updates
// (Chromium's way): the caller calls Update once a frame while Active, and hears what moved
// (core's TouchpadPhases turns the viewport's reports into phases). What moved is the content's
// travel, which follows the fingers as Windows' touchpad scrolling direction setting has it.

#include <windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "core/TouchpadPhases.h"

struct IDirectManipulationManager;
struct IDirectManipulationUpdateManager;
struct IDirectManipulationViewport;

namespace kite {

class TouchpadInput {
public:
    // Null with `error` when there's no DirectManipulation (no touchpad is fine: it never
    // hears anything). `input` runs on the window's thread, from Update or the window's
    // messages; `wantsFrames` when a gesture starts moving (the caller's clock may have
    // stopped).
    static std::unique_ptr<TouchpadInput> Create(HWND window, std::function<void(const SwipeInput&)> input,
                                                 std::function<void()> wantsFrames, std::wstring& error);
    ~TouchpadInput();
    TouchpadInput(const TouchpadInput&) = delete;
    TouchpadInput& operator=(const TouchpadInput&) = delete;

    // The window's DM_POINTERHITTEST (its wParam and lParam, the contact's screen point): a
    // touchpad's contact is taken (true) when `take` (the point, in client px) says so.
    bool HitTest(WPARAM wParam, LPARAM lParam, const std::function<bool(POINT)>& take);
    // Where the contact taken last was, in client px.
    POINT Contact() const { return contact_; }
    // A gesture or its momentum is under way, a contact taken is still held (or was just taken),
    // or the viewport's recentring needs applying: Update once a frame.
    bool Active() const;
    void Update();
    // The window's px per point (its DPI / 96): what moved is reported in points.
    void SetScale(float scale) { scale_ = scale > 0 ? scale : 1; }
    // For a frame log: each status change and content report, one JSON object a line.
    std::function<void(const std::string&)> log;

private:
    class Handler;
    // The event handler's: DirectManipulation's state and its content's transform changed.
    void StatusChanged(int current, int previous);
    void ContentMoved(float x, float y);
    TouchpadInput(HWND window, std::function<void(const SwipeInput&)> input, std::function<void()> wantsFrames)
        : window_(window), input_(std::move(input)), wantsFrames_(std::move(wantsFrames)) {}
    std::wstring Init();
    void Deliver();
    // The primary content's translation now, in px.
    bool ContentTransform(float& x, float& y) const;
    // The viewport back over the content's middle, after a gesture.
    void Recentre();

    HWND window_;
    std::function<void(const SwipeInput&)> input_;
    std::function<void()> wantsFrames_;
    IDirectManipulationManager* manager_ = nullptr;
    IDirectManipulationUpdateManager* updates_ = nullptr;
    IDirectManipulationViewport* viewport_ = nullptr;
    Handler* handler_ = nullptr;
    DWORD cookie_ = 0;
    bool activated_ = false;

    TouchpadPhases phases_;
    std::vector<SwipeInput> pending_;  // what the last report made, delivered after it
    float scale_ = 1;
    POINT contact_{};
    UINT32 pointer_ = 0;
    bool contactTaken_ = false;
    // Frames for at least this long after a contact is taken (s), held or not.
    double pollUntil_ = 0;
    bool recentring_ = false;  // the viewport was sent back over the middle: one Update applies it
};

}  // namespace kite
