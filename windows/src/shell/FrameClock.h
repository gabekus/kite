#pragma once
// A frame clock for animations, as the Mac's FrameClock (a display link): while it runs, the
// window gets `message` once per composition frame, at the display's refresh rate, and does
// nothing between animations. A worker thread waits for each frame (the compositor clock on
// Windows 11, DwmFlush before it) and posts the message, never more than one at a time. While
// it runs it boosts the compositor clock, so a display with a dynamic refresh rate runs at its
// highest. The compositor's clock is the system's, not this window's display's: on several
// displays it follows the fastest.
//
// Only for what has to draw again each frame (the theme's crossfade, a shader mix), and for
// stepping DirectManipulation's manual updates for a touchpad contact taken over the sidebar
// (shell/TouchpadInput.h): boosted while its gesture or momentum runs, unboosted while the
// fingers rest before moving (10 s at most, then the contact goes back to the system), as
// docs/windows-architecture.md allows. What a compositor property can do (an offset, an
// opacity) is an IDCompositionAnimation.
//
// Time() is when the frame being made will reach the screen (DirectComposition's estimate),
// as the Mac's targetTimestamp, in seconds on the QueryPerformanceCounter clock.

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

struct IDCompositionDevice;

namespace kite {

class FrameClock {
public:
    FrameClock(HWND window, UINT message);
    ~FrameClock();
    FrameClock(const FrameClock&) = delete;
    FrameClock& operator=(const FrameClock&) = delete;

    // Start, Stop and SetBoost come from the window's thread. Unboosted, it leaves the display's
    // refresh rate alone (frames only to poll, drawing nothing); a boosted Start while it runs
    // boosts it. The window says each frame whether it still should (SetBoost): a boost ends
    // with what needed it, not only when the clock stops.
    void Start(bool boost = true);
    void Stop();
    void SetBoost(bool boost);
    // The boost alone, with no frames (the window's thread): for an animation that runs on the
    // compositor (the sidebar's hide and show), on as it starts and off as it ends. Counted with the
    // clocks' boosts, so either ending leaves the other's on. Its own on-or-off is one flag for the
    // process: with several windows (W29a) it becomes each window's, or one window's slide ending
    // would end another's boost.
    static void BoostWithoutFrames(bool boost);
    bool Running() const { return running_; }
    bool Boosted() const { return boosted_; }
    // The window took the message: the next frame may post another.
    void Delivered() { posted_ = false; }

    // Now, in seconds (QueryPerformanceCounter).
    static double Now();
    // When the next frame reaches the screen, in Now()'s seconds; Now() when `device` can't say.
    // With `rateHz`, also the compositor's current rate (0 when it can't say), from the same
    // statistics.
    static double NextFrameTime(IDCompositionDevice* device, double* rateHz = nullptr);

private:
    void Run();

    HWND window_;
    UINT message_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool running_ = false;  // under mutex_ for the thread; read on the UI thread only
    bool boosted_ = false;  // the UI thread's
    bool quit_ = false;
    std::atomic<bool> posted_{false};
    std::thread thread_;
};

}  // namespace kite
