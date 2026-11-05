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

// Posted to the worker thread: Kite's UI thread has news (Occlusion's atomics). A thread
// message, but numbered from the shared WM_APP allocation all the same (P2 has +12 and +13).
constexpr UINT kPokeMessage = WM_APP + 13;
// How long a pass waits after the event that asked for it, so a burst of events (a window
// animating over Kite) costs one pass per interval rather than one per event. It's also how
// long a covered Kite takes to show again when uncovered by anything but a drag, a thumbnail
// or Kite coming forward (those show it at once); Windows' own close and minimize animations
// take longer than this.
constexpr double kDebounceSeconds = 0.03;
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

static_assert(EVENT_SYSTEM_FOREGROUND == occlusion::win_event::kForeground && EVENT_OBJECT_STATECHANGE == occlusion::win_event::kStateChange &&
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
    double deadline = 0;  // when the pending pass runs; 0 for none
    // The hooks on now: the system-wide ones (core's GlobalHooks), and per process.
    struct Global {
        HWINEVENTHOOK foreground = nullptr, moveSize = nullptr, minimize = nullptr, show = nullptr, cloak = nullptr;
    } global;
    HWINEVENTHOOK kiteCloak = nullptr;
    std::map<DWORD, HWINEVENTHOOK> stateHooks, destroyHooks, hideHooks, showHooks;
    HANDLE sessionsReady = nullptr;  // Global\TermSrvReadyEvent, while WTS registration waits for it
    HRGN scratch = CreateRectRgn(0, 0, 0, 0);
    // Reused by every pass.
    std::vector<Rect> monitors, occluderRects;
    std::vector<DWORD> owners;
    // Whether each process with a window is a screen recorder, asked once per process.
    std::map<DWORD, bool> recorders;
    // What the last pass saw, for the log.
    int64_t visiblePixels = -1;
    size_t occluderCount = 0;
    bool previewing = false, covered = false;
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

    static thread_local Worker* current;

    static void CALLBACK OnEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG object, LONG child, DWORD, DWORD) {
        if (current) current->Handle(event, hwnd, object, child);
    }

    static HWINEVENTHOOK Hook(DWORD first, DWORD last, DWORD process) {
        return SetWinEventHook(first, last, nullptr, &OnEvent, process, 0, WINEVENT_OUTOFCONTEXT);
    }

    // On the worker thread: a hook goes from the thread that set it.
    void Unhook() {
        for (HWINEVENTHOOK* hook : {&global.foreground, &global.moveSize, &global.minimize, &global.show, &global.cloak, &kiteCloak}) {
            if (*hook) UnhookWinEvent(*hook);
            *hook = nullptr;
        }
        for (auto* hooks : {&stateHooks, &destroyHooks, &hideHooks, &showHooks}) {
            for (auto& [pid, hook] : *hooks) UnhookWinEvent(hook);
            hooks->clear();
        }
    }

    void Run() {
        current = this;
        // The thread's queue, then whatever Kite's UI thread asked before it existed.
        MSG first;
        PeekMessageW(&first, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
        Log("started");
        Poked();
        Schedule();  // the first pass, which sets the first hooks
        for (;;) {
            DWORD timeout = INFINITE;
            if (deadline > 0) {
                const double wait = deadline - Seconds();
                timeout = wait <= 0 ? 0 : static_cast<DWORD>(wait * 1000) + 1;
            }
            const DWORD woke = MsgWaitForMultipleObjectsEx(sessionsReady ? 1 : 0, sessionsReady ? &sessionsReady : nullptr, timeout, QS_ALLINPUT,
                                                           MWMO_INPUTAVAILABLE);
            if (sessionsReady && woke == WAIT_OBJECT_0) SessionsReady();
            MSG msg;
            // Dispatching delivers the hooks' events (OnEvent).
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) {
                    Log("stopped");
                    Unhook();
                    if (sessionsReady) CloseHandle(sessionsReady);
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

    // What a reaction asks for: the verdict published at once, the hooks brought in line
    // (once, whether a signal or the foreground changed), and a pass after the debounce.
    void Apply(occlusion::Tracker::Reaction reaction, bool hooksMayChange = false) {
        if (reaction.recompute || reaction.reevaluate) ++relevant;
        if (reaction.reevaluate) Publish();
        if (reaction.reevaluate || hooksMayChange) UpdateHooks();
        if (reaction.recompute) Schedule();
    }

    void Poked() {
        owner.poked_ = false;
        if (owner.waitForSessions_.exchange(false) && !sessionsReady) {
            // Early in a login the session service isn't up yet: register once it is.
            sessionsReady = OpenEventW(SYNCHRONIZE, FALSE, L"Global\\TermSrvReadyEvent");
        }
        // The lock state at start, and again on any news while locked, in case an unlock was
        // missed (the registration failed, or came after it).
        if (owner.queryLock_.exchange(false) || tracker.Suspended()) {
            if (const auto locked = SessionLocked()) owner.locked_ = *locked ? 1 : 0;
        }
        if (const int locked = owner.locked_.exchange(-1); locked >= 0) Apply(tracker.SetLocked(locked == 1));
        if (const int off = owner.displayOff_.exchange(-1); off >= 0) Apply(tracker.SetDisplayOff(off == 1));
        if (owner.activated_.exchange(false)) Apply(tracker.KiteActivated());
        if (owner.windowChanged_.exchange(false)) {
            Apply(tracker.KiteChanged());
            if (log.is_open()) Log("kiteChanged");
        }
    }

    void SessionsReady() {
        CloseHandle(sessionsReady);
        sessionsReady = nullptr;
        owner.sessionRegistered_ = WTSRegisterSessionNotification(kite, NOTIFY_FOR_THIS_SESSION) != 0;
        if (const auto locked = SessionLocked()) Apply(tracker.SetLocked(*locked));
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
        facts.occluder = occluder;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        facts.kiteProcess = process == kiteProcess;
        facts.kiteWindow = hwnd == kite;
        const bool showOrHide = *event == Event::Show || *event == Event::Hide || *event == Event::Destroy || *event == Event::Cloaked ||
                                *event == Event::Uncloaked;
        if (showOrHide && process && process == ShellProcess()) facts.previewWindow = IsPreview(hwnd);
        if (tracker.NeedsOverKite(*event)) {
            facts.overKite = FrameRect(hwnd).Intersects(*event == Event::MoveSizeStart ? KiteRect().Inflated(kNearKitePixels) : KiteRect());
        }
        // The foreground app's hooks follow it.
        Apply(tracker.OnEvent(facts), *event == Event::Foreground);
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
        if (IsZoomed(kite)) rect = rect.Intersection(MonitorRect(MonitorFromWindow(kite, MONITOR_DEFAULTTONEAREST), false));
        return rect;
    }

    struct Enumeration {
        Worker* worker;
        Rect target;
        DWORD shell;
        occlusion::Tracker::Pass* pass;
    };

    // One window above Kite's, top to bottom; false at Kite's own.
    bool Visit(HWND hwnd, Enumeration& e) {
        if (hwnd == kite) return false;
        if (!IsWindowVisible(hwnd)) return true;
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        // A thumbnail or Alt+Tab up anywhere shows Kite's window as it is.
        if (process == e.shell && !e.pass->previewing && IsPreview(hwnd) && !CloakedWindow(hwnd)) e.pass->previewing = true;
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
        w.cloaked = CloakedWindow(hwnd);
        int backdrop = 0;
        if (SUCCEEDED(DwmGetWindowAttribute(hwnd, kDwmSystemBackdropType, &backdrop, sizeof backdrop))) w.backdrop = backdrop;
        w.rect = FrameRect(hwnd);
        if (w.maximized) w.workArea = MonitorRect(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), true);
        if (!occlusion::CanOcclude(w)) return true;
        const Rect covers = occlusion::OccludingRect(w);
        if (!covers.Intersects(e.target)) return true;
        occluderRects.push_back(covers);
        e.pass->occluders.push_back(reinterpret_cast<uintptr_t>(hwnd));
        e.pass->occluderProcesses.push_back(process);
        return true;
    }

    // Recorders and sharing hosts have windows (OBS's, a sharing toolbar, ones hidden behind a
    // tray icon), so the processes that own a top-level window are the ones asked: far cheaper
    // than listing every process (~15 ms here). Each is asked its name once.
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
        pass.kiteShown = IsWindowVisible(kite) && !IsIconic(kite);
        // The cloak as of now; published with the rest below, once.
        tracker.SetCloaked(CloakedWindow(kite));
        visiblePixels = -1;
        occluderCount = 0;
        previewing = covered = false;
        // Locked, display off, on another desktop, minimized (the browser window's own
        // business: it hides the page already) or in front: the windows can't matter.
        if (!tracker.Suspended() && !tracker.Cloaked() && pass.kiteShown && !pass.kiteForeground) {
            Enumeration e{this, KiteRect(), ShellProcess(), &pass};
            monitors.clear();
            occluderRects.clear();
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
        tracker.SetPass(std::move(pass));
        Publish();
        UpdateHooks();
        const double took = Seconds() - start;
        ++passes;
        passSeconds += took;
        passMaxSeconds = std::max(passMaxSeconds, took);
        if (covered != loggedCovered || occluderCount != loggedOccluders) Log("pass");
    }

    void UpdateHooks() {
        DWORD foreground = 0;
        bool foregroundNearKite = false;
        if (const HWND front = GetForegroundWindow()) {
            GetWindowThreadProcessId(front, &foreground);
            const HMONITOR kiteMonitor = MonitorFromWindow(kite, MONITOR_DEFAULTTONEAREST);
            foregroundNearKite = MonitorFromWindow(front, MONITOR_DEFAULTTONEAREST) == kiteMonitor ||
                                 FrameRect(front).Intersects(MonitorRect(kiteMonitor, false));
        }
        using namespace occlusion::win_event;
        const occlusion::GlobalHooks globals = tracker.Globals();
        Set(global.foreground, globals.foreground, kForeground, kForeground, 0);
        Set(global.moveSize, globals.moveSize, kMoveSizeStart, kMoveSizeEnd, 0);
        Set(global.minimize, globals.minimize, kMinimizeStart, kMinimizeEnd, 0);
        Set(global.show, globals.show, kShow, kShow, 0);
        Set(global.cloak, globals.cloak, kCloaked, kUncloaked, 0);
        const occlusion::ProcessHooks wanted = tracker.Hooks(kiteProcess, foreground, foregroundNearKite, ShellProcess());
        Set(kiteCloak, wanted.kiteCloak, kCloaked, kUncloaked, kiteProcess);
        Sync(stateHooks, wanted.stateChange, kStateChange, kStateChange);
        Sync(destroyHooks, wanted.hide, kDestroy, kDestroy);
        Sync(hideHooks, wanted.hide, kHide, kHide);
        Sync(showHooks, wanted.show, kShow, kShow);
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

    static void Sync(std::map<DWORD, HWINEVENTHOOK>& hooks, const std::vector<uint32_t>& wanted, DWORD first, DWORD last) {
        for (auto it = hooks.begin(); it != hooks.end();) {
            if (std::binary_search(wanted.begin(), wanted.end(), it->first)) {
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

    size_t HookCount() const {
        size_t count = stateHooks.size() + destroyHooks.size() + hideHooks.size() + showHooks.size();
        for (HWINEVENTHOOK hook : {global.foreground, global.moveSize, global.minimize, global.show, global.cloak, kiteCloak}) count += hook != nullptr;
        return count;
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
        char line[768];
        std::snprintf(line, sizeof line,
                      "{\"t\":%.4f,\"%s\":\"%s\",\"covered\":%s,\"visiblePixels\":%lld,\"occluders\":%zu,\"previewing\":%s,\"dragging\":%s,"
                      "\"events\":%llu,\"relevant\":%llu,\"passes\":%llu,\"passMaxMs\":%.3f,\"passTotalMs\":%.3f,\"hooks\":%zu,"
                      "\"thread\":%lu}\n",
                      Seconds() - started, what, std::string(occlusion::Name(published)).c_str(), Json(covered),
                      static_cast<long long>(visiblePixels), occluderCount, Json(previewing), Json(tracker.Dragging()),
                      static_cast<unsigned long long>(events), static_cast<unsigned long long>(relevant),
                      static_cast<unsigned long long>(passes), passMaxSeconds * 1000, passSeconds * 1000, HookCount(), GetCurrentThreadId());
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
    auto* occlusion = static_cast<Occlusion*>(self);
    occlusion->worker_->Run();
    return 0;
}

Occlusion::Occlusion(HWND window, const std::filesystem::path& log, UINT message) : window_(window) {
    worker_ = std::make_unique<Worker>(*this, window, message);
    if (!log.empty()) worker_->log.open(log, std::ios::binary | std::ios::trunc);
    // CreateThread rather than std::thread, which throws; Run makes the thread's queue in its
    // first PeekMessage, and a poke before that is posted again (Poke).
    thread_ = CreateThread(nullptr, 0, &ThreadMain, this, 0, &threadID_);
}

Occlusion::~Occlusion() {
    if (thread_) {
        // Until the thread has its queue a post can fail: try until it takes.
        while (!PostThreadMessageW(threadID_, WM_QUIT, 0, 0) && WaitForSingleObject(thread_, 10) == WAIT_TIMEOUT) {
        }
        WaitForSingleObject(thread_, INFINITE);
        CloseHandle(thread_);
    }
    if (displayNotification_) UnregisterPowerSettingNotification(displayNotification_);
    if (sessionRegistered_) WTSUnRegisterSessionNotification(window_);
}

void Occlusion::RegisterNotifications() {
    // Registered first, then the state asked (on the worker, off this thread), so a lock in
    // between isn't missed. Early in a login the service may not be up: the worker waits for it.
    sessionRegistered_ = WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) != 0;
    if (!sessionRegistered_) waitForSessions_ = true;
    queryLock_ = true;
    // Windows answers this at once with the display's state (a message to the window, which
    // the caller hands to HandleMessage), then on each change.
    displayNotification_ = RegisterPowerSettingNotification(window_, &kDisplayStatus, DEVICE_NOTIFY_WINDOW_HANDLE);
    Poke();
}

void Occlusion::Poke() {
    if (!threadID_ || poked_.exchange(true)) return;
    // The thread may not have its queue yet: it reads every flag when it does run (Run's
    // first pass and its first poke), so a failed post just leaves the flag for then.
    if (!PostThreadMessageW(threadID_, kPokeMessage, 0, 0)) poked_ = false;
}

void Occlusion::WindowChanged() {
    windowChanged_ = true;
    Poke();
}

void Occlusion::Activated() {
    activated_ = true;
    Poke();
}

bool Occlusion::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    if (message == WM_WTSSESSION_CHANGE && (wParam == WTS_SESSION_LOCK || wParam == WTS_SESSION_UNLOCK)) {
        locked_ = wParam == WTS_SESSION_LOCK ? 1 : 0;
        Poke();
        result = 0;
        return true;
    }
    if (message == WM_POWERBROADCAST && wParam == PBT_POWERSETTINGCHANGE && lParam) {
        const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lParam);
        if (!IsEqualGUID(setting->PowerSetting, kDisplayStatus) || setting->DataLength < sizeof(DWORD)) return false;
        DWORD state = 0;
        std::memcpy(&state, setting->Data, sizeof state);
        displayOff_ = state == 0 ? 1 : 0;  // dimmed still shows
        Poke();
        result = TRUE;
        return true;
    }
    return false;
}

}  // namespace kite
