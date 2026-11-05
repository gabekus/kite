// See Occlusion.h.

#include "shell/Occlusion.h"

#include <dwmapi.h>
#include <wtsapi32.h>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace kite {

namespace {

using occlusion::Event;
using occlusion::Hidden;
using occlusion::Rect;

// Posted to the worker thread: Kite's UI thread has news (Occlusion's atomics). A thread
// message, but numbered from the shared WM_APP allocation all the same (P2 has +12 and +13).
constexpr UINT kPokeMessage = WM_APP + 13;
// How long a pass waits after the event that asked for it, so a burst of events (a window
// animating over Kite) costs one pass per interval rather than one per event. It's also how
// long a covered Kite takes to show again when uncovered by anything but a drag, a thumbnail
// or Kite coming forward (those show it at once); Windows' own close and minimize animations
// take longer than this.
constexpr double kDebounceSeconds = 0.03;

// Not in every SDK's headers (MinGW's among them).
constexpr DWORD kEventObjectCloaked = 0x8017;
constexpr DWORD kEventObjectUncloaked = 0x8018;
constexpr DWORD kDwmUseHostBackdropBrush = 17;  // DWMWA_USE_HOSTBACKDROPBRUSH
constexpr DWORD kDwmSystemBackdropType = 38;    // DWMWA_SYSTEMBACKDROP_TYPE
constexpr int kBackdropAcrylic = 3;             // DWMSBT_TRANSIENTWINDOW
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

bool Cloaked(HWND hwnd) {
    DWORD cloaked = 0;
    return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof cloaked)) && cloaked != 0;
}

bool ClassIs(HWND hwnd, const char* name) {
    char buffer[64] = {};
    return GetClassNameA(hwnd, buffer, static_cast<int>(sizeof buffer)) > 0 && std::strcmp(buffer, name) == 0;
}

bool IsPreview(HWND hwnd) {
    char buffer[64] = {};
    return GetClassNameA(hwnd, buffer, static_cast<int>(sizeof buffer)) > 0 && occlusion::IsPreviewWindowClass(buffer);
}

BOOL CALLBACK AddMonitor(HMONITOR, HDC, LPRECT rect, LPARAM monitors) {
    reinterpret_cast<std::vector<Rect>*>(monitors)->push_back(ToRect(*rect));
    return TRUE;
}

std::string_view Json(bool value) { return value ? "true" : "false"; }

}  // namespace

struct Occlusion::Worker {
    Occlusion& owner;
    const HWND kite;
    const UINT message;
    DWORD kiteProcess = GetCurrentProcessId();
    occlusion::Tracker tracker;
    double deadline = 0;  // when the pending pass runs; 0 for none
    std::vector<HWINEVENTHOOK> globalHooks;
    std::map<DWORD, HWINEVENTHOOK> locationHooks, hideHooks;
    HRGN scratch = CreateRectRgn(0, 0, 0, 0);
    // Whether each process with a window is a screen recorder, asked once per process.
    std::map<DWORD, bool> recorders;
    // What the last pass saw, for the log.
    int64_t visiblePixels = -1;
    size_t occluderCount = 0;
    bool previewing = false;
    bool covered = false;
    // What the log last said of a pass, so it notes each change (test runs only).
    bool loggedCovered = false;
    size_t loggedOccluders = 0;
    // Counters: every event delivered, those that changed something, passes and their time.
    uint64_t events = 0, relevant = 0, passes = 0;
    double passSeconds = 0, passMaxSeconds = 0;
    std::ofstream log;
    const double started = Seconds();
    Hidden published = Hidden::No;

    Worker(Occlusion& o, HWND window, UINT msg) : owner(o), kite(window), message(msg) {}
    ~Worker() {
        if (scratch) DeleteObject(scratch);
    }

    // On the worker thread: a hook goes from the thread that set it.
    void Unhook() {
        for (HWINEVENTHOOK hook : globalHooks) UnhookWinEvent(hook);
        for (auto& [pid, hook] : locationHooks) UnhookWinEvent(hook);
        for (auto& [pid, hook] : hideHooks) UnhookWinEvent(hook);
        globalHooks.clear();
        locationHooks.clear();
        hideHooks.clear();
    }

    static thread_local Worker* current;

    static void CALLBACK OnEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG object, LONG child, DWORD, DWORD) {
        if (current) current->Handle(event, hwnd, object, child);
    }

    HWINEVENTHOOK Hook(DWORD first, DWORD last, DWORD process) {
        return SetWinEventHook(first, last, nullptr, &OnEvent, process, 0, WINEVENT_OUTOFCONTEXT);
    }

    void Run() {
        current = this;
        // Always: what can cover a visible Kite or show a covered one without a process of
        // its own to watch (an app coming forward, a drag, a restore, a window shown, a
        // desktop switched). Each is a burst only on a person's action, but EVENT_OBJECT_SHOW,
        // which carets and tooltips send too: those are dropped at the first check.
        const std::pair<DWORD, DWORD> ranges[] = {{EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND},
                                                  {EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND},
                                                  {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND},
                                                  {EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW},
                                                  {kEventObjectCloaked, kEventObjectUncloaked}};
        for (const auto& [first, last] : ranges) {
            if (HWINEVENTHOOK hook = Hook(first, last, 0)) globalHooks.push_back(hook);
        }
        Log("started");
        Schedule();  // the first pass
        for (;;) {
            DWORD timeout = INFINITE;
            if (deadline > 0) {
                const double wait = deadline - Seconds();
                timeout = wait <= 0 ? 0 : static_cast<DWORD>(wait * 1000) + 1;
            }
            MsgWaitForMultipleObjectsEx(0, nullptr, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            MSG msg;
            // Dispatching delivers the hooks' events (OnEvent).
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) {
                    Log("stopped");
                    Unhook();
                    current = nullptr;
                    return;
                }
                if (msg.message == kPokeMessage && !msg.hwnd) Poked();
                DispatchMessageW(&msg);
            }
            if (deadline > 0 && Seconds() >= deadline) {
                deadline = 0;
                Pass();
            }
        }
    }

    void Schedule() {
        if (deadline == 0) deadline = Seconds() + kDebounceSeconds;
    }

    void React(occlusion::Tracker::Reaction reaction) {
        if (reaction.recompute || reaction.reevaluate) ++relevant;
        if (reaction.reevaluate) {
            Publish();
            UpdateHooks();
        }
        if (reaction.recompute) Schedule();
    }

    void Poked() {
        owner.poked_ = false;
        if (const int locked = owner.locked_.exchange(-1); locked >= 0) React(tracker.SetLocked(locked == 1));
        if (const int off = owner.displayOff_.exchange(-1); off >= 0) React(tracker.SetDisplayOff(off == 1));
        if (owner.windowChanged_.exchange(false)) React(tracker.KiteChanged());
    }

    void Handle(DWORD code, HWND hwnd, LONG object, LONG child) {
        ++events;
        // Whole windows only: carets, cursors, scroll bars and a window's parts go at once.
        if (!hwnd || object != OBJID_WINDOW || child != CHILDID_SELF) return;
        occlusion::EventFacts facts;
        switch (code) {
        case EVENT_SYSTEM_FOREGROUND: facts.event = Event::Foreground; break;
        case EVENT_SYSTEM_MOVESIZESTART: facts.event = Event::MoveSizeStart; break;
        case EVENT_SYSTEM_MOVESIZEEND: facts.event = Event::MoveSizeEnd; break;
        case EVENT_SYSTEM_MINIMIZESTART: facts.event = Event::MinimizeStart; break;
        case EVENT_SYSTEM_MINIMIZEEND: facts.event = Event::MinimizeEnd; break;
        case EVENT_OBJECT_SHOW: facts.event = Event::Show; break;
        case EVENT_OBJECT_HIDE: facts.event = Event::Hide; break;
        case EVENT_OBJECT_REORDER: facts.event = Event::Reorder; break;
        case EVENT_OBJECT_LOCATIONCHANGE: facts.event = Event::LocationChange; break;
        case kEventObjectCloaked: facts.event = Event::Cloaked; break;
        case kEventObjectUncloaked: facts.event = Event::Uncloaked; break;
        default: return;
        }
        facts.occluder = tracker.IsOccluder(reinterpret_cast<uintptr_t>(hwnd));
        // Top-level windows only (a hidden occluder may already be gone: the set knows it).
        if (!facts.occluder && facts.event != Event::Reorder && GetAncestor(hwnd, GA_ROOT) != hwnd) return;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        facts.kiteProcess = process == kiteProcess;
        facts.kiteWindow = hwnd == kite;
        if ((facts.event == Event::Show || facts.event == Event::Hide || facts.event == Event::Cloaked ||
             facts.event == Event::Uncloaked) &&
            process && process == ShellProcess()) {
            facts.previewWindow = IsPreview(hwnd);
        }
        if (tracker.NeedsOverKite(facts.event)) facts.overKite = FrameRect(hwnd).Intersects(KiteRect());
        React(tracker.OnEvent(facts));
        // The foreground app's moves are hooked while Kite shows: it changed.
        if (facts.event == Event::Foreground) UpdateHooks();
    }

    static DWORD ShellProcess() {
        DWORD process = 0;
        if (const HWND shell = GetShellWindow()) GetWindowThreadProcessId(shell, &process);
        return process;
    }

    // Kite's rect as the screen shows it: a maximized window's frame hangs off its monitor,
    // and DWM clips it there.
    Rect KiteRect() const {
        Rect rect = FrameRect(kite);
        if (IsZoomed(kite)) {
            MONITORINFO info{};
            info.cbSize = sizeof info;
            if (GetMonitorInfoW(MonitorFromWindow(kite, MONITOR_DEFAULTTONEAREST), &info)) rect = rect.Intersection(ToRect(info.rcMonitor));
        }
        return rect;
    }

    struct Enumeration {
        Worker* worker;
        Rect target;
        DWORD shell;
        std::vector<Rect> occluders;
        occlusion::Tracker::Pass* pass;
    };

    // One window above Kite's, top to bottom; false at Kite's own.
    bool Visit(HWND hwnd, Enumeration& e) {
        if (hwnd == kite) return false;
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        if (process == kiteProcess) return true;  // Kite's own never cover it
        // A thumbnail or Alt+Tab up anywhere shows Kite's window as it is.
        if (process == e.shell && !e.pass->previewing && IsPreview(hwnd) && !Cloaked(hwnd)) e.pass->previewing = true;
        // The window's rect holds its frame: windows nowhere near Kite go without asking DWM.
        RECT outer{};
        if (!GetWindowRect(hwnd, &outer) || !ToRect(outer).Intersects(e.target)) return true;
        occlusion::WindowFacts w;
        w.visible = true;
        w.rect = ToRect(outer);
        const LONG style = GetWindowLongW(hwnd, GWL_STYLE);
        const LONG exStyle = GetWindowLongW(hwnd, GWL_EXSTYLE);
        w.clickThrough = (exStyle & WS_EX_TRANSPARENT) != 0;
        w.toolWindow = (exStyle & WS_EX_TOOLWINDOW) != 0;
        w.popup = (style & WS_POPUP) != 0;
        w.owned = GetWindow(hwnd, GW_OWNER) != nullptr;
        if (w.toolWindow || w.popup) w.taskbar = ClassIs(hwnd, "Shell_TrayWnd") || ClassIs(hwnd, "Shell_SecondaryTrayWnd");
        w.layered = (exStyle & WS_EX_LAYERED) != 0;
        if (w.layered) {
            BYTE alpha = 255;
            DWORD flags = 0;
            w.layeredKnown = GetLayeredWindowAttributes(hwnd, nullptr, &alpha, &flags) != 0;
            w.layeredAlpha = (flags & LWA_ALPHA) != 0;
            w.alpha = alpha;
            w.layeredColorKey = (flags & LWA_COLORKEY) != 0;
        }
        // The cheap checks first: most windows above Kite are out by now.
        if (!occlusion::CanOcclude(w)) return true;
        w.rect = FrameRect(hwnd);
        if (!w.rect.Intersects(e.target)) return true;
        w.cloaked = Cloaked(hwnd);
        w.shapedRegion = scratch && GetWindowRgn(hwnd, scratch) == COMPLEXREGION;
        BOOL hostBackdrop = FALSE;
        int backdrop = 0;
        w.acrylic = (SUCCEEDED(DwmGetWindowAttribute(hwnd, kDwmUseHostBackdropBrush, &hostBackdrop, sizeof hostBackdrop)) && hostBackdrop) ||
                    (SUCCEEDED(DwmGetWindowAttribute(hwnd, kDwmSystemBackdropType, &backdrop, sizeof backdrop)) && backdrop == kBackdropAcrylic);
        w.maximized = IsZoomed(hwnd) != 0;
        if (w.maximized) {
            MONITORINFO info{};
            info.cbSize = sizeof info;
            if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &info)) w.workArea = ToRect(info.rcWork);
        }
        if (!occlusion::CanOcclude(w)) return true;
        const Rect covers = occlusion::OccludingRect(w);
        if (!covers.Intersects(e.target)) return true;
        e.occluders.push_back(covers);
        e.pass->occluders.insert(reinterpret_cast<uintptr_t>(hwnd));
        e.pass->occluderProcesses.insert(process);
        return true;
    }

    // Recorders and sharing hosts have windows (OBS's, a sharing toolbar, ones hidden behind a
    // tray icon), so the processes that own a top-level window are the ones asked: far cheaper
    // than listing every process, which took ~15 ms here. Each is asked its name once.
    bool RecorderRunning() {
        std::set<DWORD> owners;
        EnumWindows([](HWND hwnd, LPARAM data) -> BOOL {
            DWORD process = 0;
            GetWindowThreadProcessId(hwnd, &process);
            reinterpret_cast<std::set<DWORD>*>(data)->insert(process);
            return TRUE;
        }, reinterpret_cast<LPARAM>(&owners));
        std::erase_if(recorders, [&](const auto& entry) { return !owners.contains(entry.first); });
        bool running = false;
        for (DWORD process : owners) {
            auto [it, added] = recorders.try_emplace(process, false);
            if (added) it->second = IsRecorderProcess(process);
            running = running || it->second;
        }
        return running;
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
        std::string name;
        for (const wchar_t* c = file; *c; ++c) name += *c < 0x80 ? static_cast<char>(*c) : '?';
        return occlusion::IsScreenRecorder(name);
    }

    void Pass() {
        const double start = Seconds();
        occlusion::Tracker::Pass pass;
        DWORD foreground = 0;
        if (const HWND front = GetForegroundWindow()) GetWindowThreadProcessId(front, &foreground);
        pass.kiteForeground = foreground == kiteProcess;
        React(tracker.SetCloaked(Cloaked(kite)));
        // Locked or the display off: the windows can't change the verdict (the end of it asks
        // for a pass).
        if (tracker.Suspended()) return;
        visiblePixels = -1;
        occluderCount = 0;
        previewing = false;
        covered = false;
        // Minimized is the browser window's own business (it hides the page already); in
        // front, Kite isn't covered. Neither needs the windows.
        if (IsWindowVisible(kite) && !IsIconic(kite) && !pass.kiteForeground) {
            Enumeration e{this, KiteRect(), ShellProcess(), {}, &pass};
            std::vector<Rect> monitors;
            EnumDisplayMonitors(nullptr, nullptr, &AddMonitor, reinterpret_cast<LPARAM>(&monitors));
            EnumWindows([](HWND hwnd, LPARAM data) -> BOOL {
                auto& e = *reinterpret_cast<Enumeration*>(data);
                return e.worker->Visit(hwnd, e) ? TRUE : FALSE;
            }, reinterpret_cast<LPARAM>(&e));
            visiblePixels = occlusion::VisiblePixels(e.target, monitors, e.occluders);
            occluderCount = e.occluders.size();
            pass.covered = occlusion::Covered(visiblePixels);
            previewing = pass.previewing;
            covered = pass.covered;
            if (pass.covered) pass.recording = RecorderRunning();
        }
        tracker.SetPass(std::move(pass));
        Publish();
        UpdateHooks();
        if (covered != loggedCovered || occluderCount != loggedOccluders) Log("pass");
        const double took = Seconds() - start;
        ++passes;
        passSeconds += took;
        if (took > passMaxSeconds) passMaxSeconds = took;
    }

    void UpdateHooks() {
        DWORD foreground = 0;
        if (const HWND front = GetForegroundWindow()) GetWindowThreadProcessId(front, &foreground);
        const occlusion::ProcessHooks wanted = tracker.Hooks(kiteProcess, foreground, ShellProcess());
        Sync(locationHooks, wanted.location, EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE);
        Sync(hideHooks, wanted.hideReorder, EVENT_OBJECT_HIDE, EVENT_OBJECT_REORDER);
    }

    void Sync(std::map<DWORD, HWINEVENTHOOK>& hooks, const std::set<uint32_t>& wanted, DWORD first, DWORD last) {
        for (auto it = hooks.begin(); it != hooks.end();) {
            if (wanted.contains(it->first)) {
                ++it;
                continue;
            }
            UnhookWinEvent(it->second);
            it = hooks.erase(it);
        }
        for (uint32_t process : wanted) {
            if (hooks.contains(process)) continue;
            if (HWINEVENTHOOK hook = Hook(first, last, process)) hooks.emplace(process, hook);
        }
    }

    void Publish() {
        const Hidden verdict = tracker.Verdict();
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
        char line[640];
        std::snprintf(line, sizeof line,
                      "{\"t\":%.4f,\"%s\":\"%s\",\"covered\":%s,\"visiblePixels\":%lld,\"occluders\":%zu,\"previewing\":%s,\"events\":%llu,"
                      "\"relevant\":%llu,\"passes\":%llu,\"passMaxMs\":%.3f,\"passTotalMs\":%.3f,\"processHooks\":%zu,\"thread\":%lu}\n",
                      Seconds() - started, what, std::string(occlusion::Name(published)).c_str(),
                      Json(covered).data(), static_cast<long long>(visiblePixels), occluderCount, Json(previewing).data(),
                      static_cast<unsigned long long>(events), static_cast<unsigned long long>(relevant),
                      static_cast<unsigned long long>(passes), passMaxSeconds * 1000, passSeconds * 1000,
                      locationHooks.size() + hideHooks.size(), GetCurrentThreadId());
        log << line;
        log.flush();
    }
};

thread_local Occlusion::Worker* Occlusion::Worker::current = nullptr;

std::unique_ptr<Occlusion> Occlusion::Start(HWND window, UINT message, const std::filesystem::path& log) {
    std::unique_ptr<Occlusion> occlusion(new Occlusion(window, message, log));
    if (!occlusion->threadID_) return nullptr;
    return occlusion;
}

Occlusion::Occlusion(HWND window, UINT message, const std::filesystem::path& log) : window_(window) {
    worker_ = std::make_unique<Worker>(*this, window, message);
    if (!log.empty()) worker_->log.open(log, std::ios::binary | std::ios::trunc);
    // Launched while locked (a scheduled test run): hidden from the start.
    SessionInfoEx* info = nullptr;
    DWORD bytes = 0;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, kWtsSessionInfoEx, reinterpret_cast<LPWSTR*>(&info),
                                    &bytes) &&
        info) {
        if (bytes >= sizeof(SessionInfoEx) && info->level == 1 && info->level1.sessionFlags == kWtsSessionStateLock) locked_ = 1;
        WTSFreeMemory(info);
    }
    sessionNotification_ = WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION) != 0;
    // Windows answers this at once with the display's state, then on each change.
    displayNotification_ = RegisterPowerSettingNotification(window, &kDisplayStatus, DEVICE_NOTIFY_WINDOW_HANDLE);
    // The thread's queue exists before Start returns, so a poke is never lost.
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!ready) return;
    thread_ = std::thread([this, ready] {
        MSG msg;
        PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // makes the queue
        threadID_ = GetCurrentThreadId();
        SetEvent(ready);
        worker_->Run();
    });
    WaitForSingleObject(ready, INFINITE);
    CloseHandle(ready);
    Poke();  // the initial lock state
}

Occlusion::~Occlusion() {
    if (displayNotification_) UnregisterPowerSettingNotification(displayNotification_);
    if (sessionNotification_) WTSUnRegisterSessionNotification(window_);
    if (thread_.joinable()) {
        PostThreadMessageW(threadID_, WM_QUIT, 0, 0);
        thread_.join();
    }
}

void Occlusion::Poke() {
    if (!threadID_ || poked_.exchange(true)) return;
    if (!PostThreadMessageW(threadID_, kPokeMessage, 0, 0)) poked_ = false;
}

void Occlusion::WindowChanged() {
    windowChanged_ = true;
    Poke();
}

bool Occlusion::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    if (message == WM_WTSSESSION_CHANGE) {
        if (wParam == WTS_SESSION_LOCK || wParam == WTS_SESSION_UNLOCK) {
            locked_ = wParam == WTS_SESSION_LOCK ? 1 : 0;
            Poke();
        }
        result = 0;
        return true;
    }
    if (message == WM_POWERBROADCAST && wParam == PBT_POWERSETTINGCHANGE && lParam) {
        const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lParam);
        if (IsEqualGUID(setting->PowerSetting, kDisplayStatus) && setting->DataLength >= sizeof(DWORD)) {
            DWORD state = 0;
            std::memcpy(&state, setting->Data, sizeof state);
            displayOff_ = state == 0 ? 1 : 0;  // dimmed still shows
            Poke();
        }
        result = TRUE;
        return true;
    }
    return false;
}

}  // namespace kite
