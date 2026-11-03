#include "shell/FrameClock.h"

#include <dcomp.h>
#include <dwmapi.h>

namespace kite {

namespace {

// DCompositionWaitForCompositorClock (Windows 11): returns at the compositor's next frame, which
// follows the fastest display Kite is on. Looked up at run time: older Windows and MinGW's
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

void Boost(bool enable) {
    static const auto boost = reinterpret_cast<BoostCompositorClock>(DcompFunction("DCompositionBoostCompositorClock"));
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

void FrameClock::Start() {
    {
        std::lock_guard lock(mutex_);
        if (running_) return;
        running_ = true;
    }
    Boost(true);
    wake_.notify_one();
}

void FrameClock::Stop() {
    {
        std::lock_guard lock(mutex_);
        if (!running_) return;
        running_ = false;
    }
    Boost(false);
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
    std::unique_lock lock(mutex_);
    for (;;) {
        wake_.wait(lock, [this] { return quit_ || running_; });
        if (quit_) return;
        lock.unlock();
        // One frame: the compositor's clock, or DWM's next composition. A 500 Hz display's
        // frames come every 2 ms, so only frames closer than any display's (0.25 ms, 4 kHz)
        // mean the wait returned without one (no display, a locked session): then a frame is
        // Sleep's ~16 ms.
        if (!compositorClock || compositorClock(0, nullptr, 100) != WAIT_OBJECT_0) {
            if (FAILED(DwmFlush())) Sleep(16);
        }
        if (Now() - lastFrame < 0.00025) Sleep(16);
        lastFrame = Now();
        if (!posted_.exchange(true)) {
            if (!PostMessageW(window_, message_, 0, 0)) posted_ = false;
        }
        lock.lock();
    }
}

}  // namespace kite
