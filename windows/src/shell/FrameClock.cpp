// See FrameClock.h.

#include "shell/FrameClock.h"

#include <dcomp.h>
#include <dwmapi.h>

namespace kite {

namespace {

// DCompositionWaitForCompositorClock (Windows 11): returns at the compositor's next frame. Its
// clock is the system's: with several displays it follows the fastest. Looked up at run time: older Windows and MinGW's
// headers don't have it.
using WaitForCompositorClock = DWORD(WINAPI*)(UINT count, const HANDLE* handles, DWORD timeoutInMs);
// DCompositionBoostCompositorClock (Windows 11): while boosted, a display with a dynamic
// refresh rate runs at its highest (the Mac's preferredFrameRateRange at the screen's maximum).
using BoostCompositorClock = HRESULT(WINAPI*)(BOOL enable);

void* DcompFunction(const char* name) {
    HMODULE dcomp = GetModuleHandleW(L"dcomp.dll");
    if (!dcomp) dcomp = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return dcomp ? reinterpret_cast<void*>(GetProcAddress(dcomp, name)) : nullptr;
}

WaitForCompositorClock CompositorClock() {
    static const auto wait = reinterpret_cast<WaitForCompositorClock>(DcompFunction("DCompositionWaitForCompositorClock"));
    return wait;
}

// The boost, counted on the UI thread: on while any clock or compositor animation wants it, and
// off when the last lets go, whether or not Windows counts the calls itself.
int boosts = 0;
void Boost(bool enable) {
    static const auto boost = reinterpret_cast<BoostCompositorClock>(DcompFunction("DCompositionBoostCompositorClock"));
    if (enable ? boosts++ != 0 : (boosts == 0 || --boosts != 0)) return;
    if (boost) boost(enable ? TRUE : FALSE);
}

double Frequency() {
    static const double frequency = [] {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    return frequency;
}

}  // namespace

FrameClock::FrameClock(HWND window, UINT message) : window_(window), message_(message), thread_([this] { Run(); }) {}

FrameClock::~FrameClock() {
    Stop();
    {
        std::lock_guard lock(mutex_);
        quit_ = true;
    }
    wake_.notify_one();
    thread_.join();
}

void FrameClock::Start(bool boost) {
    bool wasRunning = false;
    {
        std::lock_guard lock(mutex_);
        wasRunning = running_;
        running_ = true;
    }
    if (boost) SetBoost(true);
    if (!wasRunning) wake_.notify_one();
}

void FrameClock::SetBoost(bool boost) {
    // Only a running clock boosts: Stop has dropped it.
    if (boost == boosted_ || (boost && !running_)) return;
    Boost(boost);
    boosted_ = boost;
}

void FrameClock::BoostWithoutFrames::Set(bool boost) {
    if (boost == on_) return;
    on_ = boost;
    Boost(boost);
}

int FrameClock::ProcessBoosts() { return boosts; }

void FrameClock::SetManual(bool manual) {
    {
        std::lock_guard lock(mutex_);
        manual_ = manual;
    }
    wake_.notify_one();
}

void FrameClock::Stop() {
    {
        std::lock_guard lock(mutex_);
        if (!running_) return;
        running_ = false;
    }
    SetBoost(false);
}

double FrameClock::Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return static_cast<double>(now.QuadPart) / Frequency();
}

double FrameClock::NextFrameTime(IDCompositionDevice* device) {
    DCOMPOSITION_FRAME_STATISTICS statistics{};
    if (!device || FAILED(device->GetFrameStatistics(&statistics)) || statistics.timeFrequency.QuadPart <= 0) return Now();
    const double next = static_cast<double>(statistics.nextEstimatedFrameTime.QuadPart) /
                        static_cast<double>(statistics.timeFrequency.QuadPart);
    // Its clock is QueryPerformanceCounter's; an estimate behind now (an idle compositor) is now.
    const double now = Now();
    return next > now ? next : now;
}

void FrameClock::Run() {
    const WaitForCompositorClock compositorClock = CompositorClock();
    double lastFrame = 0;
    int tooSoon = 0;  // frames in a row that came too soon after the last
    std::unique_lock lock(mutex_);
    for (;;) {
        wake_.wait(lock, [this] { return quit_ || (running_ && !manual_); });
        if (quit_) return;
        lock.unlock();
        // One frame: the compositor's clock, or DWM's next composition. A 500 Hz display's
        // frames come every 2 ms, so only frames closer than any display's (0.25 ms, 4 kHz)
        // mean the wait returned without one (no display, a locked session): then a frame is
        // Sleep's ~16 ms. With the display off, the compositor clock's wait fails at once
        // (STATUS_GRAPHICS_PRESENT_OCCLUDED) and DwmFlush paces the frames at DWM's displayless
        // 500 Hz, stalling now and then for a few hundred ms (measured, Windows 11 26200).
        if (!compositorClock || compositorClock(0, nullptr, 100) != WAIT_OBJECT_0) {
            // DwmFlush returns at once when DWM has nothing outstanding: no faster than a
            // millisecond, so the thread never spins.
            const double flushed = Now();
            if (FAILED(DwmFlush())) Sleep(16);
            else if (Now() - flushed < 0.001) Sleep(1);
        }
        // One short return is a late wake catching up with the next tick; three in a row is a
        // wait that isn't waiting.
        if (Now() - lastFrame < 0.00025) {
            if (++tooSoon >= 3) Sleep(16);
        } else {
            tooSoon = 0;
        }
        lastFrame = Now();
        if (!posted_.exchange(true)) {
            if (!PostMessageW(window_, message_, 0, 0)) posted_ = false;
        }
        lock.lock();
    }
}

}  // namespace kite
