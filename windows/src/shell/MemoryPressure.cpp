// See MemoryPressure.h.

#include "shell/MemoryPressure.h"

#include "core/LiveTabPolicy.h"

namespace kite {

MemoryPressureWatch::MemoryPressureWatch(HWND window, UINT message) : window_(window), message_(message) {
    low_ = CreateMemoryResourceNotification(LowMemoryResourceNotification);
    high_ = CreateMemoryResourceNotification(HighMemoryResourceNotification);
    if (low_ && high_) wait_ = CreateThreadpoolWait(Signalled, this, nullptr);
    if (!wait_) {
        OutputDebugStringW(L"Kite: no memory resource notification; background pages stay under memory pressure\n");
        return;
    }
    SetThreadpoolWait(wait_, low_, nullptr);
}

MemoryPressureWatch::~MemoryPressureWatch() {
    if (wait_) {
        stopping_ = true;
        SetThreadpoolWait(wait_, nullptr, nullptr);
        WaitForThreadpoolWaitCallbacks(wait_, TRUE);
        SetThreadpoolWait(wait_, nullptr, nullptr);  // in case a callback re-armed it before it saw stopping_
        CloseThreadpoolWait(wait_);
    }
    // The memory manager's events: not to be closed while a wait is registered on them.
    if (low_) CloseHandle(low_);
    if (high_) CloseHandle(high_);
}

void CALLBACK MemoryPressureWatch::Signalled(PTP_CALLBACK_INSTANCE, void* context, PTP_WAIT wait, TP_WAIT_RESULT result) {
    auto* self = static_cast<MemoryPressureWatch*>(context);
    if (result != WAIT_OBJECT_0 || self->stopping_) return;
    if (self->waitingForLow_) {
        // Entered low memory: the window discards what it can, on its own thread.
        PostMessageW(self->window_, self->message_, static_cast<WPARAM>(MemoryPressure::Critical), 0);
        self->waitingForLow_ = false;
        if (!self->stopping_) SetThreadpoolWait(wait, self->high_, nullptr);
    } else {
        // Recovered: the next spell of low memory is reported again.
        PostMessageW(self->window_, self->message_, static_cast<WPARAM>(MemoryPressure::Normal), 0);
        self->waitingForLow_ = true;
        if (!self->stopping_) SetThreadpoolWait(wait, self->low_, nullptr);
    }
}

}  // namespace kite
