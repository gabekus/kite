#pragma once
// A frame clock for animations, as the Mac's FrameClock (a display link): while it runs, the
// window gets `message` once per composition frame, at the display's refresh rate, and does
// nothing between animations. A worker thread waits for each frame (the compositor clock on
// Windows 11, DwmFlush before it) and posts the message, never more than one at a time.
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

    void Start();
    void Stop();
    bool Running() const { return running_; }
    // The window took the message: the next frame may post another.
    void Delivered() { posted_ = false; }

    // Now, in seconds (QueryPerformanceCounter).
    static double Now();
    // When the next frame reaches the screen, in Now()'s seconds; Now() when `device` can't say.
    static double NextFrameTime(IDCompositionDevice* device);

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
