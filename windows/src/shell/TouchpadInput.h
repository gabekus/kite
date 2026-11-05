#pragma once
// A precision touchpad's two-finger scrolls over the sidebar, through DirectManipulation: the
// gesture's phases (fingers down, moving, lifted) and its momentum after they lift, which the
// window's wheel messages don't carry, as the Mac's NSEvent phase and momentumPhase do (core's
// SwipeInput, for SpaceSwipeGesture).
//
// The window asks on DM_POINTERHITTEST: a contact it takes (a touchpad's, over the sidebar) is
// DirectManipulation's until the fingers lift and its momentum ends, or until the window lets it
// go (ReleaseContact), and makes no wheel messages meanwhile; the rest go on as the system's
// wheel messages. The viewport runs on manual updates (Chromium's way): the caller calls Step
// once a frame while it says so, and hears what moved (core's TouchpadPhases turns the
// viewport's reports into phases). What moved is the content's travel, which follows the
// fingers as Windows' touchpad scrolling direction setting has it.

#include <windows.h>
#include <wrl/client.h>

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
    // hears anything). `input` runs on the window's thread, from Step or the window's
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
    // The contact taken goes back to the system, whose wheel messages carry the rest of the
    // gesture to whatever is under the pointer (a gesture that turned out not to be the
    // sidebar's). Nothing when there's none. Done by the next Step, after DirectManipulation's
    // update (this may be asked from within one of its reports).
    void ReleaseContact();
    // How many times ReleaseContact was asked, held contact or not (the smoke test's, which
    // has no contact to let go).
    size_t ReleasesAsked() const { return releasesAsked_; }
    // Once a frame while the clock runs: DirectManipulation's manual update, when it needs one
    // (a gesture or its momentum under way, a contact taken and still held, or the viewport's
    // recentring to apply). A contact held past kLongestRest without moving is released. True
    // while it still needs frames.
    bool Step();
    // Fingers moving, or their momentum: what's worth the display's highest rate.
    bool Moving() const { return phases_.Moving(); }
    // The window's px per point (its DPI / 96): what moved is reported in points.
    void SetScale(float scale) { scale_ = scale > 0 ? scale : 1; }
    // For the smoke test, which can't make a touchpad's input: frames for `seconds`, as after a
    // contact is taken.
    void PollFor(double seconds);
    // For a frame log: each status change and content report, one JSON object a line.
    std::function<void(const std::string&)> log;

private:
    class Handler;
    TouchpadInput(HWND window, std::function<void(const SwipeInput&)> input, std::function<void()> wantsFrames);
    // The event handler's: DirectManipulation's state and its content's transform changed.
    void StatusChanged(int current, int previous);
    void ContentMoved(float x, float y);
    std::wstring Init();
    void Deliver();
    bool NeedsFrames(double now) const;
    // ReleaseContact's work, from Step.
    void Release();
    // The primary content's translation now, in px; false when it can't be read.
    bool ContentTransform(float& x, float& y) const;
    // The viewport back over the content's middle, after a gesture.
    void Recentre();

    HWND window_;
    std::function<void(const SwipeInput&)> input_;
    std::function<void()> wantsFrames_;
    Microsoft::WRL::ComPtr<IDirectManipulationManager> manager_;
    Microsoft::WRL::ComPtr<IDirectManipulationUpdateManager> updates_;
    Microsoft::WRL::ComPtr<IDirectManipulationViewport> viewport_;
    Microsoft::WRL::ComPtr<Handler> handler_;
    DWORD cookie_ = 0;
    bool activated_ = false;

    TouchpadPhases phases_;
    std::vector<SwipeInput> pending_;  // what the last report made, delivered after it
    float scale_ = 1;
    float contentX_ = 0, contentY_ = 0;  // the content as last reported, px
    UINT32 pointer_ = 0;
    bool contactHeld_ = false;   // taken and not yet released or lifted
    bool contactTaken_ = false;  // held and not yet moving: polled until it does
    bool releaseWanted_ = false;  // ReleaseContact was asked: the next Step lets it go
    size_t releasesAsked_ = 0;
    // Frames for at least this long after a contact is taken (s), held or not.
    double pollUntil_ = 0;
    double restUntil_ = 0;     // and while held without moving, until this
    size_t reports_ = 0;       // status and content reports heard, for the log's polls
    bool recentring_ = false;  // the viewport was sent back over the middle: one Step applies it
};

}  // namespace kite
