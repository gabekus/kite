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
// thread, never Kite's UI thread, which hears only when the verdict changes. To keep even that
// thread quiet (docs/windows-architecture.md, Performance):
// - Each hook is on only in the states where its events can change the verdict (core's
//   Tracker::Globals and Hooks): none while locked, display-off, minimized or on another
//   desktop; only another app coming forward while Kite is in front.
// - What's hooked per process is quiet: STATECHANGE (a maximize) for the foreground app and
//   the occluders, hides and destroys for the occluders. Never EVENT_OBJECT_LOCATIONCHANGE (a
//   caret moves on every key) or EVENT_OBJECT_REORDER, measured past the budget (core's Event).
// - Every event is filtered at once (core's FilterEvent), passes are debounced, and nothing
//   is enumerated while nothing changed.
//
// The lock and display notifications are window messages, so they're registered on Kite's
// window (RegisterNotifications) and handed over (HandleMessage).

#include <windows.h>

#include <atomic>
#include <filesystem>
#include <memory>

#include "core/Occlusion.h"

namespace kite {

class Occlusion {
public:
    // Starts the watcher thread for `window`; `message` is posted to it when the verdict
    // changes (read it with Verdict). `log`, when not empty (--occlusion-log): a JSON line for
    // each verdict and each change in what a pass found, with the thread's counters. Null
    // when the thread couldn't start (Kite then simply never counts as hidden).
    static std::unique_ptr<Occlusion> Start(HWND window, UINT message, const std::filesystem::path& log);
    ~Occlusion();
    Occlusion(const Occlusion&) = delete;
    Occlusion& operator=(const Occlusion&) = delete;

    // Registers for the lock and display notifications, once the caller holds this object:
    // Windows may answer the display's at once, and the window's messages reach
    // HandleMessage only through the caller.
    void RegisterNotifications();
    // The latest verdict, from Kite's UI thread.
    occlusion::Hidden Verdict() const { return static_cast<occlusion::Hidden>(verdict_.load()); }
    // Kite's window moved, resized, was minimized or restored, or its monitors, work area or
    // DPI changed.
    void WindowChanged();
    // Kite's app was activated (WM_ACTIVATEAPP): in front, it's seen.
    void Activated();
    // WM_WTSSESSION_CHANGE's lock and unlock and WM_POWERBROADCAST's display state, on Kite's
    // window: true when it acted on one, with `result` set; false for anything else.
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);

private:
    Occlusion(HWND window, const std::filesystem::path& log, UINT message);
    struct Worker;  // the thread's state (Occlusion.cpp)
    static DWORD WINAPI ThreadMain(LPVOID self);
    void Poke();

    HWND window_;
    std::atomic<int> verdict_{static_cast<int>(occlusion::Hidden::No)};
    // From Kite's UI thread to the worker: -1 for no news, else 0 or 1.
    std::atomic<int> locked_{-1}, displayOff_{-1};
    std::atomic<bool> windowChanged_{false}, activated_{false}, queryLock_{false}, waitForSessions_{false};
    std::atomic<bool> poked_{false};
    std::atomic<bool> sessionRegistered_{false};
    std::unique_ptr<Worker> worker_;
    HANDLE thread_ = nullptr;
    DWORD threadID_ = 0;
    HPOWERNOTIFY displayNotification_ = nullptr;
};

}  // namespace kite
