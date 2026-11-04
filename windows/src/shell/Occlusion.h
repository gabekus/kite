#pragma once
// Whether Kite's window can be seen: the session locked, the display off, the window cloaked
// (on another virtual desktop) or covered by other windows. The Mac gets this from AppKit's
// window occlusion, which stops a covered window's page from drawing; here the browser window
// hides the shown page's widget (as when minimized), skips the theme's crossfade and stops the
// frame clock while it can't be seen (BrowserWindowController::OcclusionChanged). The
// decisions are core's (core/Occlusion.h); this reads the system for them.
//
// Covered is found as Chromium's NativeWindowOcclusionTrackerWin does, from out-of-context
// WinEvent hooks and an EnumWindows pass that subtracts the opaque windows above Kite's from
// its rect. All of it runs on a thread of its own, so another app's windows moving wake that
// thread, never Kite's UI thread, which hears only when the verdict changes. To keep even
// that thread quiet, events are filtered at once (whole top-level windows only, and only those
// that could change the verdict now), passes are debounced, and the noisiest events
// (EVENT_OBJECT_LOCATIONCHANGE, hides) are hooked only for the processes that matter: the
// foreground app while Kite shows, the windows covering it while it's covered. Nothing is
// enumerated while nothing changed.
//
// The lock and display notifications are window messages, so they're registered on Kite's
// window and handed over (HandleMessage).

#include <windows.h>

#include <atomic>
#include <filesystem>
#include <memory>
#include <thread>

#include "core/Occlusion.h"

namespace kite {

class Occlusion {
public:
    // Starts watching `window`; `message` is posted to it when the verdict changes (read it
    // with Verdict). `log`, when not empty (--occlusion-log): a JSON line for each verdict
    // with what the pass saw, and the thread's counters when it stops. Null when the thread
    // couldn't start (Kite then simply never counts as hidden).
    static std::unique_ptr<Occlusion> Start(HWND window, UINT message, const std::filesystem::path& log);
    ~Occlusion();
    Occlusion(const Occlusion&) = delete;
    Occlusion& operator=(const Occlusion&) = delete;

    // The latest verdict, from Kite's UI thread.
    occlusion::Hidden Verdict() const { return static_cast<occlusion::Hidden>(verdict_.load()); }
    // Kite's window moved, resized, was minimized or restored (its WM_WINDOWPOSCHANGED).
    void WindowChanged();
    // WM_WTSSESSION_CHANGE and WM_POWERBROADCAST's display state, on Kite's window: true when
    // it was one of those, with `result` set.
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);

private:
    Occlusion(HWND window, UINT message, const std::filesystem::path& log);
    struct Worker;  // the thread's state (Occlusion.cpp)
    void Poke();

    HWND window_;
    std::atomic<int> verdict_{static_cast<int>(occlusion::Hidden::No)};
    // From Kite's UI thread to the worker: -1 for no news, else 0 or 1.
    std::atomic<int> locked_{-1}, displayOff_{-1};
    std::atomic<bool> windowChanged_{false};
    std::atomic<bool> poked_{false};
    std::unique_ptr<Worker> worker_;
    std::thread thread_;
    DWORD threadID_ = 0;
    HPOWERNOTIFY displayNotification_ = nullptr;
    bool sessionNotification_ = false;
};

}  // namespace kite
