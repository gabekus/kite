// See MemoryPressure.h.

#include "shell/MemoryPressure.h"

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
        {
            // Under the lock, so a callback either re-armed the wait before this (and the clear
            // below undoes it) or sees stopping_ and doesn't.
            std::lock_guard lock(mutex_);
            stopping_ = true;
            SetThreadpoolWait(wait_, nullptr, nullptr);
        }
        // Cancels callbacks queued but not started, and waits for one that's running; then once
        // more, for a wait a callback re-armed in the moment before it took the lock.
        WaitForThreadpoolWaitCallbacks(wait_, TRUE);
        SetThreadpoolWait(wait_, nullptr, nullptr);
        WaitForThreadpoolWaitCallbacks(wait_, TRUE);
        CloseThreadpoolWait(wait_);
    }
    // The memory manager's events: not to be closed while a wait is registered on them.
    if (low_) CloseHandle(low_);
    if (high_) CloseHandle(high_);
}

bool MemoryPressureWatch::IsLow() const {
    BOOL low = FALSE;
    return low_ && QueryMemoryResourceNotification(low_, &low) && low;
}

void MemoryPressureWatch::Recovered() {
    std::lock_guard lock(mutex_);
    if (wait_ && !stopping_ && latch_.Recovered()) SetThreadpoolWait(wait_, low_, nullptr);
}

void CALLBACK MemoryPressureWatch::Signalled(PTP_CALLBACK_INSTANCE, void* context, PTP_WAIT wait, TP_WAIT_RESULT result) {
    auto* self = static_cast<MemoryPressureWatch*>(context);
    if (result != WAIT_OBJECT_0) return;
    std::optional<MemoryPressure> report;
    {
        std::lock_guard lock(self->mutex_);
        if (self->stopping_) return;
        // Low is checked as it's handled: a signal that's over already is no spell.
        const MemoryPressureLatch::Step step = self->latch_.Signalled(self->IsLow());
        report = step.report;
        SetThreadpoolWait(wait, step.waitForLow ? self->low_ : self->high_, nullptr);
    }
    // The window discards what it can, on its own thread.
    if (report) PostMessageW(self->window_, self->message_, static_cast<WPARAM>(*report), 0);
}

}  // namespace kite
