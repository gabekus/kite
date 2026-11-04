#pragma once
// Windows' memory pressure for the Mac's PagePool.watchMemoryPressure: a low-memory resource
// notification (CreateMemoryResourceNotification), reported to the window as the Mac's
// pressure levels (core/LiveTabPolicy.h's MemoryPressure).
//
// The memory manager signals LowMemoryResourceNotification while available memory is under
// its low threshold, and HighMemoryResourceNotification while it's over the high one (three
// times the low). Both are level-triggered, so the watch alternates (core's MemoryPressureLatch):
// it waits for low, posts Critical, then waits for high before it waits for low again, so one
// spell of low memory is reported once (as the Mac's source fires on entering a level), and the
// watch costs nothing between: each wait is a thread-pool wait on a kernel event, with no thread
// of its own and no timer. Windows has no earlier signal to report Warning with, and the low
// one comes late: by default at about 32 MB free per 4 GB of memory (64 MB at most), when
// paging has begun, where the Mac's warning comes well before.
//
// A low signal is checked again as the callback handles it, and the window checks again
// (IsLow) as it handles the report; when that finds memory recovered it calls Recovered, so
// the watch waits for low again rather than for high, and a spell after memory hovered
// between the two levels is still reported.

#include <windows.h>

#include <mutex>
#include <optional>

#include "core/LiveTabPolicy.h"

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
    // Whether memory is low right now (the notification's state, queried, not waited for).
    bool IsLow() const;
    // The window handled a report and memory is no longer low: wait for low again.
    void Recovered();

private:
    static void CALLBACK Signalled(PTP_CALLBACK_INSTANCE, void* context, PTP_WAIT wait, TP_WAIT_RESULT result);

    HWND window_;
    UINT message_;
    HANDLE low_ = nullptr;
    HANDLE high_ = nullptr;
    PTP_WAIT wait_ = nullptr;
    // The callback's and Recovered's, under the lock (with the wait they set).
    std::mutex mutex_;
    MemoryPressureLatch latch_;
    bool stopping_ = false;  // a callback running as the watch stops doesn't wait again
};

}  // namespace kite
