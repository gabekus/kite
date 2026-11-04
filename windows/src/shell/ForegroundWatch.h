#pragma once
// Quiet test runs (--smoke-test, --capture) never come to the front: Gabe runs them beside his
// own work, as the Mac's KITE_DIAGNOSTICS launches (KiteCore's WindowPresentation, test-safe).
// This watches for the opposite: a window of Kite's process, Chromium's included, becoming the
// foreground window (EVENT_SYSTEM_FOREGROUND for this process, out of context, so the events
// come to the watching thread as it pumps messages), and the window in front when asked.
// --smoke-test fails on it.

#include <windows.h>

#include <string>

namespace kite {

class ForegroundWatch {
public:
    // Watches from now on. On Kite's UI thread, whose message loop receives the events.
    ForegroundWatch();
    ~ForegroundWatch();
    ForegroundWatch(const ForegroundWatch&) = delete;
    ForegroundWatch& operator=(const ForegroundWatch&) = delete;

    // Empty while no window of Kite's has been in front; otherwise which came first (its
    // class) and how many times one did. Looks at the window in front now as well.
    std::wstring Problem();

private:
    static void CALLBACK OnForeground(HWINEVENTHOOK hook, DWORD event, HWND window, LONG object, LONG child, DWORD thread,
                                      DWORD time);
    void Saw(HWND window);

    HWINEVENTHOOK hook_ = nullptr;
    int times_ = 0;
    std::wstring first_;
};

}  // namespace kite
