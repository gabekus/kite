#include "shell/FrameClock.h"

#include <dcomp.h>
#include <dwmapi.h>

namespace kite {

namespace {

// DCompositionWaitForCompositorClock (Windows 11): returns at the compositor's next frame, which
// follows the fastest display Kite is on. Looked up at run time: older Windows and MinGW's
// headers don't have it.
using WaitForCompositorClock = DWORD(WINAPI*)(UINT count, const HANDLE* handles, DWORD timeoutInMs);

WaitForCompositorClock CompositorClock() {
    static const WaitForCompositorClock wait = [] {
        HMODULE dcomp = GetModuleHandleW(L"dcomp.dll");
        if (!dcomp) dcomp = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return dcomp ? reinterpret_cast<WaitForCompositorClock>(
                           reinterpret_cast<void*>(GetProcAddress(dcomp, "DCompositionWaitForCompositorClock")))
                     : nullptr;
    }();
    return wait;
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
    wake_.notify_one();
}

void FrameClock::Stop() {
    std::lock_guard lock(mutex_);
    running_ = false;
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
    std::unique_lock lock(mutex_);
    for (;;) {
        wake_.wait(lock, [this] { return quit_ || running_; });
        if (quit_) return;
        lock.unlock();
        // One frame: the compositor's clock, or DWM's next composition. Either can return at
        // once (no display, a locked session): then a frame is ~16 ms.
        const double before = Now();
        if (!compositorClock || compositorClock(0, nullptr, 100) != WAIT_OBJECT_0) {
            if (FAILED(DwmFlush())) Sleep(16);
        }
        if (Now() - before < 0.002) Sleep(4);
        if (!posted_.exchange(true)) {
            if (!PostMessageW(window_, message_, 0, 0)) posted_ = false;
        }
        lock.lock();
    }
}

}  // namespace kite
