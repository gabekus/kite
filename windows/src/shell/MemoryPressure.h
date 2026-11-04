#pragma once
// Windows' memory pressure for the Mac's PagePool.watchMemoryPressure: a low-memory resource
// notification (CreateMemoryResourceNotification), reported to the window as the Mac's
// pressure levels (core/LiveTabPolicy.h's MemoryPressure).
//
// The memory manager signals LowMemoryResourceNotification while available memory is under
// its low threshold, and HighMemoryResourceNotification while it's over the high one (three
// times the low). Both are level-triggered, so the watch alternates: it waits for low, posts
// Critical, then waits for high before it waits for low again, so one spell of low memory is
// reported once (as the Mac's source fires on entering a level), and the watch costs nothing
// between: each wait is a thread-pool wait on a kernel event, with no thread of its own and no
// timer. Windows has no earlier signal to report Warning with.

#include <windows.h>

#include <atomic>

namespace kite {

class MemoryPressureWatch {
public:
    // Posts `message` to `window` (wParam: the MemoryPressure level) each time memory runs
    // low. Does nothing if Windows can't give the notifications.
    MemoryPressureWatch(HWND window, UINT message);
    // Stops the watch and waits for a callback that's running.
    ~MemoryPressureWatch();
    MemoryPressureWatch(const MemoryPressureWatch&) = delete;
    MemoryPressureWatch& operator=(const MemoryPressureWatch&) = delete;

    bool IsWatching() const { return wait_ != nullptr; }

private:
    static void CALLBACK Signalled(PTP_CALLBACK_INSTANCE, void* context, PTP_WAIT wait, TP_WAIT_RESULT result);

    HWND window_;
    UINT message_;
    HANDLE low_ = nullptr;
    HANDLE high_ = nullptr;
    PTP_WAIT wait_ = nullptr;
    bool waitingForLow_ = true;  // the thread pool's callback only, one at a time
    std::atomic<bool> stopping_{false};  // a callback running as the watch stops doesn't wait again
};

}  // namespace kite
