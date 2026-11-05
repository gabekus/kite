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
//   desktop; only an app coming forward and drags while Kite is in front.
// - What's hooked is quiet: the system-wide events are a person's actions; per process, only
//   the occluders' destroys while Kite is covered; and per thread, the shell's shows on its
//   preview threads (the taskbars' and Alt+Tab's, never File Explorer's) while covered, and
//   their hides while a preview is up. Never moves, z-order, state changes, or anyone else's
//   shows and hides (core's Event says why).
// - Kite's own move or resize pokes the watcher once, at its end (WindowChanged isn't called
//   between WM_ENTERSIZEMOVE and WM_EXITSIZEMOVE).
// - What uncovers Kite without an event (a restore-down, a keyboard snap, leaving full screen,
//   a window turning translucent) is found by core's Heartbeat: only while Kite is covered, it
//   re-reads the windows that covered it twice a second, and runs a pass every 4 s. The first
//   pointer message to reach a covered Kite asks for a pass too (PointerRecovery, Kite's side).
// - Every event is filtered at once (core's FilterEvent), passes are debounced, and nothing
//   is enumerated while nothing changed.
//
// The lock notification is registered and asked from the watcher; the display's is a window
// message, registered on Kite's window (RegisterNotifications) and handed over (HandleMessage).

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

    // Registers for the display's notifications once the caller holds this object: Windows
    // answers at once, and the window's messages reach HandleMessage only through the caller.
    void RegisterNotifications();
    // The latest verdict, from Kite's UI thread.
    occlusion::Hidden Verdict() const { return static_cast<occlusion::Hidden>(verdict_.load()); }
    // Kite's window moved, resized, was minimized or restored; or (`display`) its monitors,
    // work area or DPI changed.
    void WindowChanged(bool display = false);
    // Kite's own move or resize loop (WM_ENTERSIZEMOVE, then false at WM_EXITSIZEMOVE): its
    // window changes at the display's rate meanwhile, so WindowChanged keeps quiet until the
    // end, which pokes once. Dragged, Kite is in front anyway.
    void SizeMoveLoop(bool inLoop);
    // Kite's app was activated (WM_ACTIVATEAPP): in front, it's seen.
    void Activated();
    // The pointer reached a covered Kite (PointerRecovery): look again.
    void RequestPass();
    // WM_WTSSESSION_CHANGE's lock and unlock and WM_POWERBROADCAST's display state, on Kite's
    // window: true when it acted on one, with `result` set; false for anything else.
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);

private:
    Occlusion(HWND window, const std::filesystem::path& log, UINT message);
    struct Worker;  // the thread's state (Occlusion.cpp)
    static DWORD WINAPI ThreadMain(LPVOID self);

    HWND window_;
    std::atomic<int> verdict_{static_cast<int>(occlusion::Hidden::No)};
    // From Kite's UI thread to the worker: -1 for no news, else 0 or 1.
    std::atomic<int> locked_{-1}, displayOff_{-1};
    std::atomic<bool> windowChanged_{false}, displayChanged_{false}, activated_{false}, passRequested_{false};
    // Auto-reset: the UI thread has news. Manual-reset: the worker stops.
    HANDLE poke_ = nullptr, stop_ = nullptr;
    std::unique_ptr<Worker> worker_;
    HANDLE thread_ = nullptr;
    HPOWERNOTIFY displayNotification_ = nullptr;
    // Kite's UI thread's alone: in a move or resize loop, and whether the window changed in it.
    bool inSizeMove_ = false, changedInSizeMove_ = false;
};

}  // namespace kite
