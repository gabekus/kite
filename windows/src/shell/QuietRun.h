#pragma once
// A quiet run (main.cpp's `quiet`) never comes to the front, takes the focus or shows a dialog:
// Gabe runs them beside his own work, as the Mac's KITE_DIAGNOSTICS launches (KiteCore's
// WindowPresentation, WindowPresenter's test-safe mode). What such a run skips is reported as
// the Mac does (LogSkippedModal), and ForegroundWatch checks that nothing came to the front.

#include <windows.h>

#include <string>
#include <string_view>

namespace kite {

// A dialog or window a quiet run didn't show: "KITE_TEST_MODAL: <what>" on stderr, the Mac's
// WindowPresenter.logSkipped line (docs/automation.md), and in the debug output. One line: line
// breaks in `what` (a page's dialog text) become spaces. Any thread.
void LogSkippedModal(std::wstring_view what);

// Watches for a window of Kite's process (Chromium's included) becoming the foreground window:
// EVENT_SYSTEM_FOREGROUND for this process, out of context, so the events come to the watching
// thread as it pumps messages. --smoke-test fails on it. Clicking a quiet run's taskbar button
// brings it to the front, which fails a local smoke test too: that's Windows activating it on
// the user's behalf, which the watch can't tell apart.
class ForegroundWatch {
public:
    // Watches from now on, on Kite's UI thread (whose message loop receives the events). One
    // at a time.
    ForegroundWatch();
    ~ForegroundWatch();
    ForegroundWatch(const ForegroundWatch&) = delete;
    ForegroundWatch& operator=(const ForegroundWatch&) = delete;

    // Empty while no window of Kite's has been in front; otherwise which came first (its
    // class) and how many times one did. Takes the events still queued for this thread first
    // (leaving its posted messages queued), and looks at the window in front now as well. Asking again gives the same answer, plus
    // anything that happened since.
    std::wstring Problem();

private:
    static void CALLBACK OnForeground(HWINEVENTHOOK hook, DWORD event, HWND window, LONG object, LONG child, DWORD thread,
                                      DWORD time);

    static ForegroundWatch* current_;  // the one watching (a WinEvent callback has no context)
    HWINEVENTHOOK hook_ = nullptr;
    int times_ = 0;       // foreground events for Kite's windows
    std::wstring first_;  // the first one's window
};

}  // namespace kite
