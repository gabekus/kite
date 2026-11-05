// See Occlusion.h.

#include "shell/Occlusion.h"

#include <dwmapi.h>
#include <wtsapi32.h>

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace kite {

namespace {

using occlusion::Event;
using occlusion::Hidden;
using occlusion::Rect;

// How long a pass waits after the event that asked for it, so a burst of events (a window
// animating over Kite) costs one pass per interval rather than one per event. It's also how
// long a covered Kite takes to show again when uncovered by anything but a drag, a thumbnail
// or Kite coming forward (those show it at once); Windows' own close and minimize animations
// take longer than this.
constexpr double kDebounceSeconds = 0.03;
// The settling pass after a drop or a monitor change: Windows refits maximized windows and a
// snap's animation lands after the event (a one-shot wait, not a timer).
constexpr double kFollowUpSeconds = 0.3;
// A drag that starts this close to Kite's frame may come over it (core's Tracker::Dragging).
constexpr int32_t kNearKitePixels = 64;

// Not in every SDK's headers (MinGW's among them).
constexpr DWORD kDwmSystemBackdropType = 38;  // DWMWA_SYSTEMBACKDROP_TYPE
// GUID_SESSION_DISPLAY_STATUS: the session's display is off (0), on (1) or dimmed (2).
constexpr GUID kDisplayStatus = {0x2b84c20e, 0xad23, 0x4ddf, {0x93, 0xdb, 0x05, 0xff, 0xbd, 0x7e, 0xfc, 0xa5}};
// WTSSessionInfoEx's answer (WTSINFOEXW), as far as the lock flag: the level, then a union
// that starts 8-byte aligned (it holds LARGE_INTEGERs) with WTSINFOEX_LEVEL1_W's first fields.
constexpr WTS_INFO_CLASS kWtsSessionInfoEx = static_cast<WTS_INFO_CLASS>(25);
constexpr LONG kWtsSessionStateLock = 0;  // WTS_SESSIONSTATE_LOCK
struct SessionInfoEx {
    DWORD level;
    DWORD padding;  // to the union's 8-byte alignment
    struct Level1 {
        ULONG sessionID;
        INT sessionState;
        LONG sessionFlags;
    } level1;
};
#ifdef _MSC_VER  // the SDK has the real one (MinGW's headers don't)
static_assert(offsetof(WTSINFOEXW, Data.WTSInfoExLevel1.SessionFlags) == offsetof(SessionInfoEx, level1.sessionFlags));
static_assert(WTSSessionInfoEx == kWtsSessionInfoEx && WTS_SESSIONSTATE_LOCK == kWtsSessionStateLock);
#endif

static_assert(EVENT_SYSTEM_FOREGROUND == occlusion::win_event::kForeground && EVENT_OBJECT_HIDE == occlusion::win_event::kHide &&
              EVENT_OBJECT_DESTROY == occlusion::win_event::kDestroy && OBJID_WINDOW == occlusion::win_event::kObjectWindow);
static_assert(WS_POPUP == occlusion::win32::kPopup && WS_EX_LAYERED == occlusion::win32::kExLayered &&
              WS_EX_TOOLWINDOW == occlusion::win32::kExToolWindow && COMPLEXREGION == occlusion::win32::kComplexRegion &&
              NULLREGION == occlusion::win32::kNullRegion && LWA_ALPHA == occlusion::win32::kLayeredAlpha);

double Seconds() {
    static const double frequency = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return static_cast<double>(now.QuadPart) / frequency;
}

Rect ToRect(const RECT& r) { return Rect{r.left, r.top, r.right, r.bottom}; }

// What the window covers on screen: DWM's frame, without the invisible resize borders that
// GetWindowRect includes (a window beside Kite would otherwise cover its edge).
Rect FrameRect(HWND hwnd) {
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r)) && !GetWindowRect(hwnd, &r)) return {};
    return ToRect(r);
}

bool CloakedWindow(HWND hwnd) {
    DWORD cloaked = 0;
    return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof cloaked)) && cloaked != 0;
}

bool IsPreview(HWND hwnd) {
    char buffer[64] = {};
    return GetClassNameA(hwnd, buffer, static_cast<int>(sizeof buffer)) > 0 && occlusion::IsPreviewWindowClass(buffer);
}

Rect MonitorRect(HMONITOR monitor, bool workArea) {
    MONITORINFO info{};
    info.cbSize = sizeof info;
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return {};
    return ToRect(workArea ? info.rcWork : info.rcMonitor);
}

BOOL CALLBACK AddMonitor(HMONITOR, HDC, LPRECT rect, LPARAM monitors) {
    reinterpret_cast<std::vector<Rect>*>(monitors)->push_back(ToRect(*rect));
    return TRUE;
}

// Whether the session is locked now; none when Windows can't say.
std::optional<bool> SessionLocked() {
    SessionInfoEx* info = nullptr;
    DWORD bytes = 0;
    if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, kWtsSessionInfoEx, reinterpret_cast<LPWSTR*>(&info),
                                     &bytes) ||
        !info) {
        return std::nullopt;
    }
    std::optional<bool> locked;
    if (bytes >= sizeof(SessionInfoEx) && info->level == 1) locked = info->level1.sessionFlags == kWtsSessionStateLock;
    WTSFreeMemory(info);
    return locked;
}

const char* Json(bool value) { return value ? "true" : "false"; }

}  // namespace

struct Occlusion::Worker {
    Occlusion& owner;
    const HWND kite;
    const UINT message;
    const DWORD kiteProcess = GetCurrentProcessId();
    occlusion::Tracker tracker;
    occlusion::Heartbeat heartbeat;
    double deadline = 0;  // when the pending pass runs; 0 for none
    double followUp = 0;  // when the settling pass after a drop or a display change runs; 0 for none
    // The hooks on now: the system-wide ones (core's GlobalHooks), and per process.
    struct Global {
        HWINEVENTHOOK foreground = nullptr, moveSize = nullptr, minimize = nullptr, cloak = nullptr;
    } global;
    HWINEVENTHOOK kiteCloak = nullptr;
    // Per process (the occluders'), and per thread of the shell's (its preview threads).
    std::map<DWORD, HWINEVENTHOOK> destroyHooks, hideHooks, showHooks;
    DWORD hookedShell = 0;            // the shell process the thread hooks are on
    std::vector<uint32_t> shellThreads;
    // WTS: registered from here (Run); early in a login the service isn't up, so it's tried
    // again once Global\TermSrvReadyEvent is set, or at the next poke if that can't be opened.
    bool sessionRegistered = false;
    HANDLE sessionsReady = nullptr;
    HRGN scratch = CreateRectRgn(0, 0, 0, 0);
    // Reused by every pass and beat: no allocation once they've grown.
    occlusion::Tracker::Pass pass;
    std::vector<Rect> monitors, occluderRects;
    std::vector<DWORD> owners;
    std::vector<occlusion::OccluderState> atPass, now;
    // Whether each process with a window is a screen recorder, asked once per process.
    std::map<DWORD, bool> recorders;
    // DWM's answers for each window a pass asked about (core's DwmCache): asked again when the
    // window's rect changes, and for all on a reaction's refreshWindows and the heartbeat's
    // whole passes. Measured: re-asking every pass cost ~10 context switches a second.
    occlusion::DwmCache dwm;
    // A screen recorder found running: its process, waited on, so its exit runs a pass (the
    // verdict is visible while it runs, so there's no heartbeat to notice).
    HANDLE recorderProcess = nullptr;
    DWORD recorderID = 0;
    // What the last pass saw, for the log.
    int64_t visiblePixels = -1;
    size_t occluderCount = 0;
    bool previewing = false, covered = false;
    bool kiteInFront = false, kiteShown = false;  // what the last pass found of Kite
    bool loggedCovered = false;
    size_t loggedOccluders = 0;
    // Counters: every event delivered, those that changed something, passes and their time,
    // heartbeat beats and the passes they found a change for.
    uint64_t events = 0, relevant = 0, passes = 0, beats = 0, beatPasses = 0;
    double passSeconds = 0, passMaxSeconds = 0;
    std::ofstream log;
    const double started = Seconds();
    Hidden published = Hidden::No;

    Worker(Occlusion& o, HWND window, UINT msg) : owner(o), kite(window), message(msg) {}
    ~Worker() {
        if (scratch) DeleteObject(scratch);
    }

    static thread_local Worker* current;

    static void CALLBACK OnEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG object, LONG child, DWORD, DWORD) {
        if (current) current->Handle(event, hwnd, object, child);
    }

    static HWINEVENTHOOK Hook(DWORD first, DWORD last, DWORD process, DWORD thread = 0) {
        return SetWinEventHook(first, last, nullptr, &OnEvent, process, thread, WINEVENT_OUTOFCONTEXT);
    }

    // The shell's threads that show a picture of Kite's window: the taskbars' (its thumbnails)
    // and the hosts of Alt+Tab and Task View (core's IsPreviewWindowClass). Not the rest of
    // Explorer: File Explorer's windows and Win+R's box each have a thread of their own, and a
    // caret raises a SHOW per key. FindWindowEx walks the window list in win32k, with no round
    // trip to Explorer. A host Explorer makes later (its first Alt+Tab) is hooked from the pass
    // after it appears (the heartbeat's whole pass at the latest).
    static void ShellPreviewThreads(DWORD shell, std::vector<uint32_t>& threads) {
        threads.clear();
        static constexpr const wchar_t* kClasses[] = {L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd", L"TaskListThumbnailWnd",
                                                      L"MultitaskingViewFrame", L"XamlExplorerHostIslandWindow"};
        for (const wchar_t* name : kClasses) {
            for (HWND w = FindWindowExW(nullptr, nullptr, name, nullptr); w; w = FindWindowExW(nullptr, w, name, nullptr)) {
                DWORD process = 0;
                const DWORD thread = GetWindowThreadProcessId(w, &process);
                if (process == shell && thread) threads.push_back(thread);
            }
        }
        std::sort(threads.begin(), threads.end());
        threads.erase(std::unique(threads.begin(), threads.end()), threads.end());
    }

    // On the worker thread: a hook goes from the thread that set it.
    void Unhook() {
        for (HWINEVENTHOOK* hook : {&global.foreground, &global.moveSize, &global.minimize, &global.cloak, &kiteCloak}) {
            if (*hook) UnhookWinEvent(*hook);
            *hook = nullptr;
        }
        for (auto* hooks : {&destroyHooks, &hideHooks, &showHooks}) {
            for (auto& [pid, hook] : *hooks) UnhookWinEvent(hook);
            hooks->clear();
        }
    }

    void Run() {
        current = this;
        // The thread's queue (the hooks' events arrive through it).
        MSG first;
        PeekMessageW(&first, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
        Log("started");
        RegisterSessions();
        Poked();
        Schedule();  // the first pass, which sets the first hooks
        for (;;) {
            const double at = Seconds();
            double due = 0;
            for (double when : {deadline, followUp, heartbeat.Next().value_or(0)}) {
                if (when > 0 && (due == 0 || when < due)) due = when;
            }
            const DWORD timeout = due == 0 ? INFINITE : due <= at ? 0 : static_cast<DWORD>((due - at) * 1000) + 1;
            HANDLE waits[4] = {owner.stop_, owner.poke_};
            DWORD count = 2;
            const DWORD sessionsAt = sessionsReady ? count : 99;  // 99: none (never a wait result here)
            if (sessionsReady) waits[count++] = sessionsReady;
            const DWORD recorderAt = recorderProcess ? count : 99;
            if (recorderProcess) waits[count++] = recorderProcess;
            const DWORD woke = MsgWaitForMultipleObjectsEx(count, waits, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            if (woke == WAIT_OBJECT_0) break;
            if (woke == WAIT_OBJECT_0 + 1) Poked();
            if (woke == WAIT_OBJECT_0 + sessionsAt) {
                CloseHandle(sessionsReady);
                sessionsReady = nullptr;
                RegisterSessions();
            }
            if (woke == WAIT_OBJECT_0 + recorderAt) {
                // The recorder quit: a covered Kite can stop drawing again.
                WatchRecorder(0);
                Schedule();
            }
            MSG msg;
            // Dispatching delivers the hooks' events (OnEvent).
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
            const double t = Seconds();
            if (followUp > 0 && t >= followUp) {
                followUp = 0;
                Schedule();
            }
            if (deadline > 0 && t >= deadline) {
                deadline = 0;
                Pass();
            } else if (heartbeat.Next() && t >= *heartbeat.Next()) {
                Beat(t);
            }
        }
        Log("stopped");
        Unhook();
        if (sessionRegistered) WTSUnRegisterSessionNotification(kite);
        if (sessionsReady) CloseHandle(sessionsReady);
        WatchRecorder(0);
        current = nullptr;
    }

    void Schedule() {
        if (deadline == 0) deadline = Seconds() + kDebounceSeconds;
    }

    // What a reaction asks for: the verdict published at once, the hooks brought in line
    // (once, whether a signal or the foreground changed), a pass after the debounce, and one
    // more once things have settled.
    void Apply(occlusion::Tracker::Reaction reaction, bool hooksMayChange = false) {
        if (reaction.recompute || reaction.reevaluate) ++relevant;
        if (reaction.refreshWindows) dwm.Clear();
        if (reaction.reevaluate) Publish();
        if (reaction.reevaluate || hooksMayChange) UpdateHooks();
        if (reaction.recompute) Schedule();
        if (reaction.followUp) followUp = Seconds() + kFollowUpSeconds;
    }

    void RegisterSessions() {
        if (sessionRegistered || sessionsReady) return;
        sessionRegistered = WTSRegisterSessionNotification(kite, NOTIFY_FOR_THIS_SESSION) != 0;
        if (!sessionRegistered) {
            // Retried when the service says it's up; if even that can't be opened, at the
            // next poke.
            sessionsReady = OpenEventW(SYNCHRONIZE, FALSE, L"Global\\TermSrvReadyEvent");
            return;
        }
        // Registered first, then asked, so a lock in between isn't missed; a notification
        // that came meanwhile wins over the answer.
        if (const auto locked = SessionLocked()) {
            int none = -1;
            owner.locked_.compare_exchange_strong(none, *locked ? 1 : 0);
        }
    }

    void Poked() {
        RegisterSessions();
        // Asked again on any news while locked, in case an unlock was missed.
        if (tracker.Suspended()) {
            if (const auto locked = SessionLocked()) {
                int none = -1;
                owner.locked_.compare_exchange_strong(none, *locked ? 1 : 0);
            }
        }
        if (const int locked = owner.locked_.exchange(-1); locked >= 0) Apply(tracker.SetLocked(locked == 1));
        if (const int off = owner.displayOff_.exchange(-1); off >= 0) Apply(tracker.SetDisplayOff(off == 1));
        if (owner.activated_.exchange(false)) {
            // Back from another desktop, maybe: the pass reads Kite's cloak afresh, whether or
            // not the uncloak event came.
            Apply(tracker.KiteActivated());
        }
        if (owner.passRequested_.exchange(false)) Apply(tracker.PointerSeen());
        if (owner.displayChanged_.exchange(false)) Apply(tracker.DisplayChanged());
        if (owner.windowChanged_.exchange(false)) {
            Apply(tracker.KiteChanged());
            if (log.is_open()) Log("kiteChanged");
        }
    }

    void Handle(DWORD code, HWND hwnd, LONG object, LONG child) {
        ++events;
        const uintptr_t key = reinterpret_cast<uintptr_t>(hwnd);
        const bool occluder = tracker.IsOccluder(key);
        const std::optional<Event> event =
            occlusion::FilterEvent(code, hwnd != nullptr, object, child, occluder, [hwnd] { return GetAncestor(hwnd, GA_ROOT) == hwnd; });
        if (!event) return;
        occlusion::EventFacts facts;
        facts.event = *event;
        facts.window = key;
        facts.occluder = occluder;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        facts.kiteProcess = process == kiteProcess;
        facts.kiteWindow = hwnd == kite;
        const bool showOrHide = *event == Event::Show || *event == Event::Hide || *event == Event::Destroy || *event == Event::Cloaked ||
                                *event == Event::Uncloaked;
        if (showOrHide && process && process == ShellProcess()) facts.previewWindow = IsPreview(hwnd);
        if (tracker.NeedsOverKite(*event)) {
            // The window's rect holds its frame: one nowhere near Kite (a menu, a tooltip
            // elsewhere) is ruled out without a round trip to DWM.
            const Rect zone = *event == Event::MoveSizeStart ? KiteRect().Inflated(kNearKitePixels) : KiteRect();
            RECT outer{};
            facts.overKite = GetWindowRect(hwnd, &outer) && ToRect(outer).Intersects(zone) && FrameRect(hwnd).Intersects(zone);
        }
        // The foreground app's state follows it.
        Apply(tracker.OnEvent(facts), *event == Event::Foreground);
    }

    static DWORD ShellProcess() {
        DWORD process = 0;
        if (const HWND shell = GetShellWindow()) GetWindowThreadProcessId(shell, &process);
        return process;
    }

    // Kite's rect as the screen shows it: a maximized window's frame hangs off its monitor,
    // and DWM clips it there.
    Rect KiteRect() {
        RECT outer{};
        GetWindowRect(kite, &outer);
        Rect rect = Dwm(kite, outer).frame;
        if (IsZoomed(kite)) rect = rect.Intersection(MonitorRect(MonitorFromWindow(kite, MONITOR_DEFAULTTONEAREST), false));
        return rect;
    }

    // What the heartbeat compares: the window as it is now.
    static occlusion::OccluderState Read(HWND hwnd) {
        occlusion::OccluderState state;
        state.window = reinterpret_cast<uintptr_t>(hwnd);
        state.exists = IsWindow(hwnd) != 0;
        if (!state.exists) return state;
        state.visible = IsWindowVisible(hwnd) != 0;
        state.minimized = IsIconic(hwnd) != 0;
        state.maximized = IsZoomed(hwnd) != 0;
        state.owned = GetWindow(hwnd, GW_OWNER) != nullptr;
        state.style = static_cast<uint32_t>(GetWindowLongW(hwnd, GWL_STYLE));
        state.exStyle = static_cast<uint32_t>(GetWindowLongW(hwnd, GWL_EXSTYLE));
        if (state.exStyle & WS_EX_LAYERED) {
            BYTE alpha = 255;
            DWORD flags = 0;
            state.layeredKnown = GetLayeredWindowAttributes(hwnd, nullptr, &alpha, &flags) != 0;
            state.layeredFlags = flags;
            state.alpha = alpha;
        }
        RECT r{};
        if (GetWindowRect(hwnd, &r)) state.rect = ToRect(r);
        return state;
    }

    // A heartbeat (core's Heartbeat): the windows over Kite re-read, a pass if any changed,
    // and a whole pass every few beats for z-order changes and new windows.
    void Beat(double t) {
        ++beats;
        const occlusion::Heartbeat::Beat beat = heartbeat.Fire(t);
        if (beat == occlusion::Heartbeat::Beat::FullPass) {
            dwm.Clear();  // the occluders' cloak and backdrop asked afresh too
            return Pass();  // now: no second wake
        }
        now.clear();
        for (uintptr_t window : tracker.Occluders()) now.push_back(Read(reinterpret_cast<HWND>(window)));
        if (occlusion::OccludersChanged(atPass, now)) {
            ++beatPasses;
            Schedule();
        }
    }

    struct Enumeration {
        Worker* worker;
        Rect target;
        DWORD shell;
    };

    // One window above Kite's, top to bottom; false at Kite's own.
    bool Visit(HWND hwnd, Enumeration& e) {
        if (hwnd == kite) return false;
        if (!IsWindowVisible(hwnd)) return true;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        // A thumbnail or Alt+Tab up anywhere shows Kite's window as it is.
        if (process == e.shell && !pass.previewing && IsPreview(hwnd) && !CloakedWindow(hwnd)) pass.previewing = true;
        // The window's rect holds its frame: windows nowhere near Kite go without asking more.
        RECT outer{};
        if (!GetWindowRect(hwnd, &outer) || !ToRect(outer).Intersects(e.target)) return true;
        char className[96] = {};
        GetClassNameA(hwnd, className, static_cast<int>(sizeof className));
        occlusion::WindowFacts w;
        w.visible = true;
        w.minimized = IsIconic(hwnd) != 0;
        w.maximized = IsZoomed(hwnd) != 0;
        w.ownProcess = process == kiteProcess;
        w.owned = GetWindow(hwnd, GW_OWNER) != nullptr;
        w.style = static_cast<uint32_t>(GetWindowLongW(hwnd, GWL_STYLE));
        w.exStyle = static_cast<uint32_t>(GetWindowLongW(hwnd, GWL_EXSTYLE));
        w.className = className;
        if (w.exStyle & WS_EX_LAYERED) {
            BYTE alpha = 255;
            DWORD flags = 0;
            w.layeredKnown = GetLayeredWindowAttributes(hwnd, nullptr, &alpha, &flags) != 0;
            w.layeredFlags = flags;
            w.alpha = alpha;
        }
        w.rect = ToRect(outer);
        // What's left to ask DWM can only rule a window out: the cheap answer first.
        if (!occlusion::CanOcclude(w)) return true;
        w.region = scratch ? GetWindowRgn(hwnd, scratch) : 0;
        const occlusion::DwmAnswers& answers = Dwm(hwnd, outer);
        w.cloaked = answers.cloaked;
        w.backdrop = answers.backdrop;
        w.rect = answers.frame;
        if (w.maximized) w.workArea = MonitorRect(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), true);
        if (!occlusion::CanOcclude(w)) return true;
        const Rect covers = occlusion::OccludingRect(w);
        if (!covers.Intersects(e.target)) return true;
        occluderRects.push_back(covers);
        pass.occluders.push_back(reinterpret_cast<uintptr_t>(hwnd));
        pass.occluderProcesses.push_back(process);
        return true;
    }

    const occlusion::DwmAnswers& Dwm(HWND hwnd, const RECT& outer) {
        return dwm.Get(reinterpret_cast<uintptr_t>(hwnd), ToRect(outer), passes + 1, [hwnd] {
            occlusion::DwmAnswers answers;
            answers.cloaked = CloakedWindow(hwnd);
            int backdrop = 0;
            if (SUCCEEDED(DwmGetWindowAttribute(hwnd, kDwmSystemBackdropType, &backdrop, sizeof backdrop))) answers.backdrop = backdrop;
            answers.frame = FrameRect(hwnd);
            return answers;
        });
    }

    // Recorders and sharing hosts have windows (OBS's, a sharing toolbar), so the processes
    // that own a top-level window are the ones asked: far cheaper than listing every process
    // (~15 ms here). Each is asked its name once.
    bool RecorderRunning() {
        owners.clear();
        EnumWindows([](HWND hwnd, LPARAM data) -> BOOL {
            DWORD process = 0;
            GetWindowThreadProcessId(hwnd, &process);
            reinterpret_cast<std::vector<DWORD>*>(data)->push_back(process);
            return TRUE;
        }, reinterpret_cast<LPARAM>(&owners));
        std::sort(owners.begin(), owners.end());
        owners.erase(std::unique(owners.begin(), owners.end()), owners.end());
        std::erase_if(recorders, [&](const auto& entry) { return !std::binary_search(owners.begin(), owners.end(), entry.first); });
        DWORD running = 0;
        for (DWORD process : owners) {
            auto [it, added] = recorders.try_emplace(process, false);
            if (added) it->second = IsRecorderProcess(process);
            if (it->second && !running) running = process;
        }
        WatchRecorder(running);
        return running != 0;
    }

    // The recorder's exit runs a pass: a waited-on handle, not a poll.
    void WatchRecorder(DWORD process) {
        if (process == recorderID) return;
        if (recorderProcess) CloseHandle(recorderProcess);
        recorderID = process;
        recorderProcess = process ? OpenProcess(SYNCHRONIZE, FALSE, process) : nullptr;
    }

    static bool IsRecorderProcess(DWORD process) {
        const HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process);
        if (!handle) return false;
        wchar_t path[MAX_PATH];
        DWORD size = MAX_PATH;
        const bool named = QueryFullProcessImageNameW(handle, 0, path, &size) != 0;
        CloseHandle(handle);
        if (!named) return false;
        const wchar_t* file = path;
        for (const wchar_t* c = path; *c; ++c) {
            if (*c == L'\\') file = c + 1;
        }
        // Executable names are ASCII in practice; anything else isn't on the list.
        char name[MAX_PATH] = {};
        for (size_t i = 0; file[i] && i + 1 < sizeof name; ++i) name[i] = file[i] < 0x80 ? static_cast<char>(file[i]) : '?';
        return occlusion::IsScreenRecorder(name);
    }

    void Pass() {
        const double start = Seconds();
        DWORD foreground = 0;
        if (const HWND front = GetForegroundWindow()) GetWindowThreadProcessId(front, &foreground);
        pass.kiteForeground = foreground == kiteProcess;
        pass.kiteShown = IsWindowVisible(kite) && !IsIconic(kite);
        kiteInFront = pass.kiteForeground;
        kiteShown = pass.kiteShown;
        // The cloak as of now, asked of DWM every pass, never cached: a cached answer from
        // before a cloak event would undo it, and Kite would draw on another desktop. Published
        // with the rest below, once.
        tracker.SetCloaked(CloakedWindow(kite));
        // The dragged window gone (its process died mid-drag): its end won't come.
        if (tracker.Dragging() && !IsWindow(reinterpret_cast<HWND>(tracker.DraggingWindow()))) tracker.DragLost();
        visiblePixels = -1;
        occluderCount = 0;
        previewing = covered = false;
        occluderRects.clear();
        // Locked, display off, on another desktop, minimized (the browser window's own
        // business: it hides the page already) or in front: the windows can't matter.
        if (!tracker.Suspended() && !tracker.Cloaked() && pass.kiteShown && !pass.kiteForeground) {
            Enumeration e{this, KiteRect(), ShellProcess()};
            monitors.clear();
            EnumDisplayMonitors(nullptr, nullptr, &AddMonitor, reinterpret_cast<LPARAM>(&monitors));
            EnumWindows([](HWND hwnd, LPARAM data) -> BOOL {
                auto& e = *reinterpret_cast<Enumeration*>(data);
                return e.worker->Visit(hwnd, e) ? TRUE : FALSE;
            }, reinterpret_cast<LPARAM>(&e));
            visiblePixels = occlusion::VisiblePixels(e.target, monitors, occluderRects);
            occluderCount = occluderRects.size();
            pass.covered = occlusion::Covered(visiblePixels);
            previewing = pass.previewing;
            covered = pass.covered;
            if (pass.covered) pass.recording = RecorderRunning();
        }
        if (!pass.recording) WatchRecorder(0);
        dwm.Prune(passes + 1);
        tracker.SetPass(pass);  // hands back the last pass's buffers, emptied
        // What the heartbeat compares against.
        atPass.clear();
        for (uintptr_t window : tracker.Occluders()) atPass.push_back(Read(reinterpret_cast<HWND>(window)));
        Publish();
        UpdateHooks();
        // An occluder hidden between the pass and its hook's arrival would be missed: look.
        for (const occlusion::OccluderState& state : atPass) {
            if (!state.exists || !state.visible || state.minimized) {
                Schedule();
                break;
            }
        }
        const double took = Seconds() - start;
        ++passes;
        passSeconds += took;
        passMaxSeconds = std::max(passMaxSeconds, took);
        if (covered != loggedCovered || occluderCount != loggedOccluders) Log("pass");
    }

    void UpdateHooks() {
        using namespace occlusion::win_event;
        const occlusion::GlobalHooks globals = tracker.Globals();
        Set(global.foreground, globals.foreground, kForeground, kForeground, 0);
        // No drag hook, no drag's end to come: the hold on Covered goes with it.
        if (global.moveSize && !globals.moveSize) tracker.DragLost();
        Set(global.moveSize, globals.moveSize, kMoveSizeStart, kMoveSizeEnd, 0);
        Set(global.minimize, globals.minimize, kMinimizeStart, kMinimizeEnd, 0);
        Set(global.cloak, globals.cloak, kCloaked, kUncloaked, 0);
        const DWORD shell = ShellProcess();
        const occlusion::ProcessHooks wanted = tracker.Hooks(kiteProcess, shell);
        Set(kiteCloak, wanted.kiteCloak, kCloaked, kUncloaked, kiteProcess);
        Sync(destroyHooks, wanted.destroy, kDestroy, kDestroy, 0);
        // The shell's preview threads, found again each time they're wanted (Explorer may have
        // restarted, or made its Alt+Tab host since).
        static const std::vector<uint32_t> none;
        if (shell != hookedShell) {
            Sync(hideHooks, none, kHide, kHide, hookedShell);
            Sync(showHooks, none, kShow, kShow, hookedShell);
            hookedShell = shell;
        }
        if (wanted.shellShow || wanted.shellHide) ShellPreviewThreads(shell, shellThreads);
        Sync(hideHooks, wanted.shellHide ? shellThreads : none, kHide, kHide, shell);
        Sync(showHooks, wanted.shellShow ? shellThreads : none, kShow, kShow, shell);
    }

    static void Set(HWINEVENTHOOK& hook, bool wanted, DWORD first, DWORD last, DWORD process) {
        if (wanted == (hook != nullptr)) return;
        if (hook) {
            UnhookWinEvent(hook);
            hook = nullptr;
        } else {
            hook = Hook(first, last, process);
        }
    }

    // `wanted`: process ids, or with `threadsOf`, that process's thread ids.
    static void Sync(std::map<DWORD, HWINEVENTHOOK>& hooks, const std::vector<uint32_t>& wanted, DWORD first, DWORD last, DWORD threadsOf) {
        for (auto it = hooks.begin(); it != hooks.end();) {
            if (std::binary_search(wanted.begin(), wanted.end(), it->first)) {
                ++it;
                continue;
            }
            UnhookWinEvent(it->second);
            it = hooks.erase(it);
        }
        for (uint32_t id : wanted) {
            if (hooks.contains(id)) continue;
            HWINEVENTHOOK hook = threadsOf ? Hook(first, last, threadsOf, id) : Hook(first, last, id);
            if (hook) hooks.emplace(id, hook);
        }
    }

    size_t HookCount() const {
        size_t count = destroyHooks.size() + hideHooks.size() + showHooks.size();
        for (HWINEVENTHOOK hook : {global.foreground, global.moveSize, global.minimize, global.cloak, kiteCloak}) count += hook != nullptr;
        return count;
    }

    void Publish() {
        const Hidden verdict = tracker.Verdict();
        heartbeat.SetVerdict(verdict, Seconds());
        if (verdict == published) return;
        published = verdict;
        owner.verdict_ = static_cast<int>(verdict);
        PostMessageW(kite, message, 0, 0);
        Log("verdict");
    }

    void Log(const char* what) {
        if (!log.is_open()) return;
        loggedCovered = covered;
        loggedOccluders = occluderCount;
        char line[768];
        std::snprintf(line, sizeof line,
                      "{\"t\":%.4f,\"%s\":\"%s\",\"covered\":%s,\"visiblePixels\":%lld,\"occluders\":%zu,\"previewing\":%s,\"dragging\":%s,\"kiteInFront\":%s,\"kiteShown\":%s,"
                      "\"kiteCloaked\":%s,\"suspended\":%s,"
                      "\"events\":%llu,\"relevant\":%llu,\"passes\":%llu,\"beats\":%llu,\"beatPasses\":%llu,\"passMaxMs\":%.3f,"
                      "\"passTotalMs\":%.3f,\"hooks\":%zu,\"thread\":%lu}\n",
                      Seconds() - started, what, occlusion::Name(published).data(), Json(covered), static_cast<long long>(visiblePixels),
                      occluderCount, Json(previewing), Json(tracker.Dragging()), Json(kiteInFront), Json(kiteShown),
                      Json(tracker.Cloaked()), Json(tracker.Suspended()), static_cast<unsigned long long>(events),
                      static_cast<unsigned long long>(relevant), static_cast<unsigned long long>(passes), static_cast<unsigned long long>(beats),
                      static_cast<unsigned long long>(beatPasses), passMaxSeconds * 1000, passSeconds * 1000, HookCount(), GetCurrentThreadId());
        log << line;
        log.flush();
    }
};

thread_local Occlusion::Worker* Occlusion::Worker::current = nullptr;

std::unique_ptr<Occlusion> Occlusion::Start(HWND window, UINT message, const std::filesystem::path& log) {
    std::unique_ptr<Occlusion> occlusion(new Occlusion(window, log, message));
    if (!occlusion->thread_) return nullptr;
    return occlusion;
}

DWORD WINAPI Occlusion::ThreadMain(LPVOID self) {
    static_cast<Occlusion*>(self)->worker_->Run();
    return 0;
}

Occlusion::Occlusion(HWND window, const std::filesystem::path& log, UINT message) : window_(window) {
    worker_ = std::make_unique<Worker>(*this, window, message);
    if (!log.empty()) worker_->log.open(log, std::ios::binary | std::ios::trunc);
    poke_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    // CreateThread rather than std::thread, which throws. Without its events there's no thread.
    if (poke_ && stop_) thread_ = CreateThread(nullptr, 0, &ThreadMain, this, 0, nullptr);
}

Occlusion::~Occlusion() {
    if (thread_) {
        SetEvent(stop_);
        WaitForSingleObject(thread_, INFINITE);
        CloseHandle(thread_);
    }
    if (displayNotification_) UnregisterPowerSettingNotification(displayNotification_);
    if (poke_) CloseHandle(poke_);
    if (stop_) CloseHandle(stop_);
}

void Occlusion::RegisterNotifications() {
    // Windows answers this at once with the display's state (a message to the window, which
    // the caller hands to HandleMessage), then on each change.
    displayNotification_ = RegisterPowerSettingNotification(window_, &kDisplayStatus, DEVICE_NOTIFY_WINDOW_HANDLE);
}

void Occlusion::WindowChanged(bool display) {
    if (!display && inSizeMove_) {
        changedInSizeMove_ = true;
        return;
    }
    (display ? displayChanged_ : windowChanged_) = true;
    SetEvent(poke_);
}

void Occlusion::SizeMoveLoop(bool inLoop) {
    inSizeMove_ = inLoop;
    if (inLoop || !changedInSizeMove_) return;
    changedInSizeMove_ = false;
    WindowChanged();
}

void Occlusion::Activated() {
    activated_ = true;
    SetEvent(poke_);
}

void Occlusion::RequestPass() {
    passRequested_ = true;
    SetEvent(poke_);
}

bool Occlusion::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    if (message == WM_WTSSESSION_CHANGE && (wParam == WTS_SESSION_LOCK || wParam == WTS_SESSION_UNLOCK)) {
        locked_ = wParam == WTS_SESSION_LOCK ? 1 : 0;
        SetEvent(poke_);
        result = 0;
        return true;
    }
    if (message == WM_POWERBROADCAST && wParam == PBT_POWERSETTINGCHANGE && lParam) {
        const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lParam);
        if (!IsEqualGUID(setting->PowerSetting, kDisplayStatus) || setting->DataLength < sizeof(DWORD)) return false;
        DWORD state = 0;
        std::memcpy(&state, setting->Data, sizeof state);
        displayOff_ = state == 0 ? 1 : 0;  // dimmed still shows
        SetEvent(poke_);
        result = TRUE;
        return true;
    }
    return false;
}

}  // namespace kite
