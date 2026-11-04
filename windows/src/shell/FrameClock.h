#pragma once
// A frame clock for animations, as the Mac's FrameClock (a display link): while it runs, the
// window gets `message` once per composition frame, at the display's refresh rate, and does
// nothing between animations. A worker thread waits for each frame (the compositor clock on
// Windows 11, DwmFlush before it) and posts the message, never more than one at a time. While
// it runs it boosts the compositor clock, so a display with a dynamic refresh rate runs at its
// highest. The compositor's clock is the system's, not this window's display's: on several
// displays it follows the fastest.
//
// Only for what has to draw again each frame (the theme's crossfade, a shader mix):
// what a compositor property can do (an offset, an opacity) is an IDCompositionAnimation.
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

    // Start and Stop come from the window's thread.
    void Start();
    void Stop();
    bool Running() const { return running_; }
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
    bool quit_ = false;
    std::atomic<bool> posted_{false};
    std::thread thread_;
};

}  // namespace kite
