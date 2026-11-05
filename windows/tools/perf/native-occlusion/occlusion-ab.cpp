// occlusion-ab: Kite for Windows with and without Chromium's native window occlusion tracker
// (CalculateNativeWinOcclusion), for docs/windows-native-occlusion.md. Kite turns it off by
// default (core/ChromiumSwitches.h, P12b); the "on" arm turns it back on with
// --chromium-switches "--enable-features=CalculateNativeWinOcclusion", which needs a Kite from
// P12b on (an older one refuses it; its default was on).
// Measurement only: not built with Kite and never shipped. kiteperf measures whole processes;
// this adds what the question needs and kiteperf doesn't have: the browser process's threads by
// name, an app's window moving near and over Kite, and whether the page reads as hidden.
//
// Build (a Visual Studio developer prompt, or any shell with cl on the path):
//   cl /nologo /O2 /EHsc /std:c++20 /W4 /DUNICODE /D_UNICODE /DNOMINMAX occlusion-ab.cpp
//
//   occlusion-ab display    prints the session display's state: 0 off, 1 on, 2 dimmed
//   occlusion-ab --kite PATH\Kite.exe [--runs 3] [--idle 60] [--phase 20] [--page static|anim|docopen]
//                [--out runs.jsonl] [--any-display] [--p2-from-launch]
//
// Each run launches Kite.exe (kitecore.exe beside it makes the session) on a fresh %TEMP% test
// profile holding one local page, in a job object, with --perf-log and --perf-control so it's a
// quiet run (behind other windows, never a dialog), with --occlusion-log for Kite's own verdicts,
// and with --chromium-switches for the "on" arm (the "off" arm is Kite's default). Arms
// alternate, on then off, `--runs` times. Phases, after 15 s for the page to load:
//   idle       nothing happens (--idle seconds); Kite's own occlusion is off, so the page draws
//              wherever Kite is (a quiet run opens behind other windows, usually covered)
// Then Kite's occlusion is turned on (--perf-control's {"occlusion":"on"}, as kiteperf's covered
// phase does), so it starts from a page that has been shown, and stays on for the rest.
// --p2-from-launch runs Kite without --perf-control instead, as a user's Kite runs: its occlusion
// is on from its start, idle included, so a Kite that opened covered makes its page while it
// can't be seen. The phases after idle:
//   nearMover  our 300x200 window slides back and forth right of Kite, 60 moves a second
//   covered    our black window sits just above Kite, covering it (--phase seconds)
//   overMover  the cover goes; our window slides over Kite, 60 moves a second
//   lockNotice Kite's window alone is told the session locked (WM_WTSSESSION_CHANGE,
//              WTS_SESSION_LOCK, posted), and unlocked at the end: Kite's own occlusion's lock
//              path without locking anything. Chromium's tracker listens on a window of its own,
//              so it never hears of it: this phase measures Kite's occlusion only.
// Our windows are captioned, opaque, unowned app windows (WS_POPUP and tool windows are ones
// Chromium's tracker skips), made WS_EX_NOACTIVATE and moved with SWP_NOACTIVATE: nothing here
// activates a window, moves the pointer or sends input. A 40x40 one sits at the bottom of the
// z-order for the whole run, as any desktop has some other app's window.
//
// Chromium's tracker forces every page to occluded while the display is off, and the desktop's
// other windows are what it reacts to, so by default a run waits for the display to be on (it
// never wakes it), keeps it on while it runs, and a run whose display went off is left out of
// the medians. --any-display runs regardless (a run whose display was off throughout shows what
// display off does). Results: one JSON line per run (--out), and a markdown table of the medians
// on stdout. Only the job's processes are ever ended.
//
// The page logs into its title, which Kite saves in the session on closing: each change of
// document.visibilityState, and (the animating page) every 2 s how many requestAnimationFrame
// callbacks have run, each at its time. Per phase that gives the share of it the page was
// `hidden` and its rAF rate (from the samples inside the phase).

#include <windows.h>

#include <dwmapi.h>
#include <intrin.h>
#include <winternl.h>
#include <wtsapi32.h>

#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "wtsapi32.lib")

namespace {

namespace fs = std::filesystem;

// The thread ui/aura/native_window_occlusion_tracker_win.cc runs on: a COM STA task runner
// (MayBlock, USER_VISIBLE), which base names this way.
constexpr wchar_t kTrackerThread[] = L"ThreadPoolSingleThreadCOMSTASharedForegroundBlocking";
constexpr wchar_t kOnSwitch[] = L"--enable-features=CalculateNativeWinOcclusion";

std::string Narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}

std::string Quote(const std::string& s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        if (static_cast<unsigned char>(c) >= 0x20) out += c;
    }
    return out + "\"";
}

std::string Fixed(double v, int digits = 1) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.*f", digits, v);
    return buf;
}

// NtQuerySystemInformation(SystemProcessInformation)'s records.
struct SysThread {
    LARGE_INTEGER KernelTime, UserTime, CreateTime;
    ULONG WaitTime;
    PVOID StartAddress;
    CLIENT_ID ClientId;
    LONG Priority, BasePriority;
    ULONG ContextSwitches, ThreadState, WaitReason;
};
struct SysProcess {
    ULONG NextEntryOffset, NumberOfThreads;
    LARGE_INTEGER WorkingSetPrivateSize;
    ULONG HardFaultCount, NumberOfThreadsHighWatermark;
    ULONGLONG CycleTime;
    LARGE_INTEGER CreateTime, UserTime, KernelTime;
    UNICODE_STRING ImageName;
    LONG BasePriority;
    HANDLE UniqueProcessId, InheritedFromUniqueProcessId;
    ULONG HandleCount, SessionId;
    ULONG_PTR UniqueProcessKey;
    SIZE_T PeakVirtualSize, VirtualSize;
    ULONG PageFaultCount;
    SIZE_T PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage,
        QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivatePageCount;
    LARGE_INTEGER ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    SysThread Threads[1];
};

struct ThreadSample {
    DWORD pid = 0;
    ULONGLONG cycles = 0;  // QueryThreadCycleTime: exact, where the 100 ns times move only at the clock tick
    ULONG cswitches = 0;
};
struct Snapshot {
    std::map<DWORD, ThreadSample> threads;
    std::map<DWORD, ULONGLONG> processCycles;  // ended threads included
    LARGE_INTEGER qpc{};
};

Snapshot Take(const std::vector<DWORD>& pids) {
    static std::vector<BYTE> buffer(1 << 22);
    Snapshot s;
    for (;;) {
        ULONG needed = 0;
        const NTSTATUS st = NtQuerySystemInformation(static_cast<SYSTEM_INFORMATION_CLASS>(5), buffer.data(), static_cast<ULONG>(buffer.size()), &needed);
        if (st == static_cast<NTSTATUS>(0xC0000004L)) {
            buffer.resize(needed + (1 << 20));
            continue;
        }
        if (st < 0) return s;
        break;
    }
    QueryPerformanceCounter(&s.qpc);
    for (BYTE* at = buffer.data();;) {
        const auto* p = reinterpret_cast<const SysProcess*>(at);
        const DWORD pid = static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(p->UniqueProcessId));
        if (std::find(pids.begin(), pids.end(), pid) != pids.end()) {
            s.processCycles[pid] = p->CycleTime;
            for (ULONG i = 0; i < p->NumberOfThreads; ++i) {
                const DWORD tid = static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(p->Threads[i].ClientId.UniqueThread));
                ThreadSample& t = s.threads[tid];
                t.pid = pid;
                t.cswitches = p->Threads[i].ContextSwitches;
                if (HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid)) {
                    QueryThreadCycleTime(h, &t.cycles);
                    CloseHandle(h);
                }
            }
        }
        if (!p->NextEntryOffset) break;
        at += p->NextEntryOffset;
    }
    return s;
}

std::vector<DWORD> JobPids(HANDLE job) {
    std::vector<BYTE> buf(sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST) + 512 * sizeof(ULONG_PTR));
    auto* list = reinterpret_cast<JOBOBJECT_BASIC_PROCESS_ID_LIST*>(buf.data());
    std::vector<DWORD> out;
    if (QueryInformationJobObject(job, JobObjectBasicProcessIdList, list, static_cast<DWORD>(buf.size()), nullptr)) {
        for (DWORD i = 0; i < list->NumberOfProcessIdsInList; ++i) out.push_back(static_cast<DWORD>(list->ProcessIdList[i]));
    }
    return out;
}

// A process's --type ("browser" for Kite.exe itself), from its command line.
std::string TypeOf(DWORD pid, DWORD browser) {
    if (pid == browser) return "browser";
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return "unknown";
    std::vector<BYTE> buf(1 << 16);
    ULONG len = 0;
    std::string type = "unknown";
    if (NtQueryInformationProcess(h, static_cast<PROCESSINFOCLASS>(60), buf.data(), static_cast<ULONG>(buf.size()), &len) >= 0) {
        const auto* us = reinterpret_cast<const UNICODE_STRING*>(buf.data());
        const std::wstring cmd(us->Buffer, us->Length / sizeof(wchar_t));
        const size_t at = cmd.find(L"--type=");
        if (at != std::wstring::npos) {
            const size_t end = cmd.find_first_of(L" \"", at + 7);
            type = Narrow(cmd.substr(at + 7, end == std::wstring::npos ? std::wstring::npos : end - at - 7));
        }
    }
    CloseHandle(h);
    return type;
}

std::wstring ThreadName(DWORD tid) {
    std::wstring name;
    if (HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid)) {
        PWSTR d = nullptr;
        if (SUCCEEDED(GetThreadDescription(h, &d)) && d) {
            name = d;
            LocalFree(d);
        }
        CloseHandle(h);
    }
    return name.empty() ? L"(unnamed)" : name;
}

void Pump(DWORD ms) {
    const ULONGLONG end = GetTickCount64() + ms;
    for (;;) {
        MSG m;
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&m);
        const ULONGLONG now = GetTickCount64();
        if (now >= end) return;
        MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(std::min<ULONGLONG>(end - now, 50)), QS_ALLINPUT);
    }
}

int gDisplay = -1;
LRESULT CALLBACK DisplayProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_POWERBROADCAST && w == PBT_POWERSETTINGCHANGE) {
        const auto* s = reinterpret_cast<const POWERBROADCAST_SETTING*>(l);
        if (s->DataLength >= 4) gDisplay = *reinterpret_cast<const DWORD*>(s->Data);
        return TRUE;
    }
    return DefWindowProcW(h, m, w, l);
}

// GUID_SESSION_DISPLAY_STATUS, the notification Chromium's tracker listens to; registering for it
// delivers the current state at once.
int DisplayState() {
    static const GUID kStatus = {0x2b84c20e, 0xad23, 0x4ddf, {0x93, 0xdb, 0x05, 0xff, 0xbd, 0x7e, 0xfc, 0xa5}};
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = DisplayProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"OcclusionAbDisplay";
        RegisterClassW(&wc);
        registered = true;
    }
    gDisplay = -1;
    HWND h = CreateWindowW(L"OcclusionAbDisplay", L"", 0, 0, 0, 0, 0, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    HPOWERNOTIFY n = RegisterPowerSettingNotification(h, &kStatus, DEVICE_NOTIFY_WINDOW_HANDLE);
    const ULONGLONG end = GetTickCount64() + 2000;
    while (gDisplay < 0 && GetTickCount64() < end) Pump(20);
    UnregisterPowerSettingNotification(n);
    DestroyWindow(h);
    return gDisplay;
}

HWND FindKite(DWORD pid) {
    struct Search {
        DWORD pid;
        HWND found;
    } search{pid, nullptr};
    EnumWindows(
        [](HWND h, LPARAM data) -> BOOL {
            auto* s = reinterpret_cast<Search*>(data);
            DWORD owner = 0;
            GetWindowThreadProcessId(h, &owner);
            wchar_t cls[64] = {};
            GetClassNameW(h, cls, 64);
            if (owner == s->pid && std::wstring(cls) == L"KiteBrowserWindow" && IsWindowVisible(h)) {
                s->found = h;
                return FALSE;
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&search));
    return search.found;
}

LRESULT CALLBACK BlackProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        FillRect(dc, &ps.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
        EndPaint(h, &ps);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// An app's window as Chromium's tracker sees one: captioned, opaque, unowned, not topmost, not
// layered, not a tool window or a popup (whose location changes it skips). Never activates.
HWND MakeWindow(const wchar_t* title) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = BlackProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"OcclusionAbWindow";
        wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        RegisterClassW(&wc);
        registered = true;
    }
    return CreateWindowExW(WS_EX_NOACTIVATE, L"OcclusionAbWindow", title, WS_OVERLAPPED | WS_CAPTION, 0, 0, 10, 10, nullptr, nullptr,
                           GetModuleHandleW(nullptr), nullptr);
}

RECT Frame(HWND h) {
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r))) GetWindowRect(h, &r);
    return r;
}

// Just above Kite in the z-order (in front only if Kite is), shown, not activated.
void PlaceAbove(HWND w, HWND kite, RECT r) {
    HWND above = GetWindow(kite, GW_HWNDPREV);
    while (above == w) above = GetWindow(above, GW_HWNDPREV);
    SetWindowPos(w, above ? above : HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

// 60 moves a second for `ms`, back and forth along 480 px from x0.
void Slide(HWND w, int x0, int y, DWORD ms) {
    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    const ULONGLONG end = GetTickCount64() + ms;
    for (int step = 0; GetTickCount64() < end; ++step) {
        const int along = step % 240;
        SetWindowPos(w, nullptr, x0 + (along < 120 ? along : 240 - along) * 4, y, 300, 200, SWP_NOACTIVATE | SWP_NOZORDER);
        MSG m;
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&m);
        LARGE_INTEGER due{};
        due.QuadPart = -166667;
        if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 100);
        else Sleep(16);
    }
    if (timer) CloseHandle(timer);
}

// A --perf-control request (WM_COPYDATA, 'KPRF', UTF-8 JSON): whether Kite took it.
bool Control(HWND kite, const char* json) {
    COPYDATASTRUCT data{0x4B505246, static_cast<DWORD>(std::strlen(json)), const_cast<char*>(json)};
    DWORD_PTR answer = 0;
    return SendMessageTimeoutW(kite, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 5000, &answer) && answer == 1;
}

// The TSC's rate: QueryThreadCycleTime counts its ticks.
double TscPerMs() {
    LARGE_INTEGER f, q0, q1;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&q0);
    const unsigned long long t0 = __rdtsc();
    Sleep(200);
    const unsigned long long t1 = __rdtsc();
    QueryPerformanceCounter(&q1);
    return static_cast<double>(t1 - t0) / (static_cast<double>(q1.QuadPart - q0.QuadPart) * 1000.0 / f.QuadPart);
}

// Both pages' titles: "vis:" then words, each a kind and a time in ms since the Unix epoch:
// V or H (visibilityState became visible or hidden) and, on the animating page, F (then ":" and
// the requestAnimationFrame callbacks run so far).
const char kStaticPage[] = R"(<!doctype html>
<meta charset="utf-8"><title>vis:</title>
<p>occlusion-ab: document.visibilityState changes go in the title (V or H, then epoch ms).</p>
<script>
let log = '', last = '';
function rec() {
  const s = document.visibilityState === 'visible' ? 'V' : 'H';
  if (s !== last) { last = s; log += s + Date.now() + ' '; document.title = 'vis:' + log; }
}
document.addEventListener('visibilitychange', rec); rec(); setInterval(rec, 1000);
</script>
)";

const char kAnimPage[] = R"(<!doctype html>
<meta charset="utf-8"><title>vis:</title>
<style>#s{width:120px;height:120px;background:#e35;animation:r 1s linear infinite}@keyframes r{to{transform:rotate(360deg)}}</style>
<div id="s"></div><canvas id="c" width="400" height="200"></canvas>
<script>
// A CSS spin and a requestAnimationFrame canvas; the title has visibilityState's changes and,
// every 2 s, the frames rAF has run.
let log = '', last = '', frames = 0;
function vis() {
  const s = document.visibilityState === 'visible' ? 'V' : 'H';
  if (s !== last) { last = s; log += s + Date.now() + ' '; document.title = 'vis:' + log; }
}
function sample() { vis(); log += 'F' + Date.now() + ':' + frames + ' '; document.title = 'vis:' + log; }
const g = document.getElementById('c').getContext('2d');
function draw(t) { frames++; g.fillStyle = `hsl(${(t / 10) % 360} 80% 50%)`; g.fillRect(0, 0, 400, 200); requestAnimationFrame(draw); }
requestAnimationFrame(draw);
document.addEventListener('visibilitychange', vis); vis(); setInterval(sample, 2000);
</script>
)";

// Now, in ms since the Unix epoch (the page's Date.now()).
double EpochMs() {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    const ULONGLONG t = (static_cast<ULONGLONG>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return static_cast<double>(t - 116444736000000000ULL) / 10000.0;
}

// The page's title log (see the pages): visibility changes and rAF samples, in order.
struct PageLog {
    std::vector<std::pair<double, bool>> visibility;  // time, hidden
    std::vector<std::pair<double, double>> frames;    // time, rAF callbacks so far

    // Over [start, end]: the share of it the page was hidden (-1 with no visibility known) and
    // its rAF rate between the first and last samples inside it (-1 with fewer than two, or
    // over less than 4 s).
    void Phase(double start, double end, double& hiddenPct, double& rafFps) const {
        hiddenPct = rafFps = -1;
        if (end > start && !visibility.empty() && visibility.front().first <= start) {
            double hidden = 0;
            for (size_t i = 0; i < visibility.size(); ++i) {
                const double from = std::max(visibility[i].first, start);
                const double to = std::min(i + 1 < visibility.size() ? visibility[i + 1].first : end, end);
                if (visibility[i].second && to > from) hidden += to - from;
            }
            hiddenPct = 100.0 * hidden / (end - start);
        }
        const std::pair<double, double>* first = nullptr;
        const std::pair<double, double>* last = nullptr;
        for (const auto& f : frames) {
            if (f.first < start || f.first > end) continue;
            if (!first) first = &f;
            last = &f;
        }
        if (first && last && last->first - first->first >= 4000) rafFps = (last->second - first->second) * 1000.0 / (last->first - first->first);
    }
};

PageLog ParsePageLog(const std::string& text) {
    PageLog log;
    std::istringstream words(text);
    for (std::string w; words >> w;) {
        if (w.size() < 2) continue;
        if (w[0] == 'V' || w[0] == 'H') {
            log.visibility.push_back({std::atof(w.c_str() + 1), w[0] == 'H'});
        } else if (w[0] == 'F') {
            const size_t colon = w.find(':');
            if (colon != std::string::npos) log.frames.push_back({std::atof(w.substr(1, colon - 1).c_str()), std::atof(w.c_str() + colon + 1)});
        }
    }
    return log;
}

// --page docopen: a stub that, once loaded, rewrites itself as `page` with document.open/write/
// close, as an old document.write page does. That drops every listener on the document and the
// window, Kite's visibility report's too (#410).
std::string DocOpenPage(std::string_view page) {
    static constexpr char kDigits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string encoded;
    for (size_t i = 0; i < page.size(); i += 3) {
        const uint32_t n = (static_cast<uint8_t>(page[i]) << 16) | (i + 1 < page.size() ? static_cast<uint8_t>(page[i + 1]) << 8 : 0) |
                           (i + 2 < page.size() ? static_cast<uint8_t>(page[i + 2]) : 0);
        encoded += kDigits[(n >> 18) & 63];
        encoded += kDigits[(n >> 12) & 63];
        encoded += i + 1 < page.size() ? kDigits[(n >> 6) & 63] : '=';
        encoded += i + 2 < page.size() ? kDigits[n & 63] : '=';
    }
    return "<!doctype html><meta charset=\"utf-8\"><title>vis:</title><script>addEventListener('load', () => setTimeout(() => {"
           "document.open(); document.write(new TextDecoder().decode(Uint8Array.from(atob('" +
           encoded + "'), c => c.charCodeAt(0)))); document.close(); }, 0));</script>";
}

struct Options {
    fs::path kite;
    int runs = 3;
    DWORD idleMs = 60000, phaseMs = 20000;
    std::string page = "static";
    fs::path out;
    bool anyDisplay = false;
    bool p2FromLaunch = false;  // no --perf-control: Kite's occlusion on from its start
};

// One phase's numbers, per second.
struct PhaseResult {
    std::string name;
    double seconds = 0;
    bool displayOn = true;
    double kiteMs = 0, kiteCsw = 0;          // every Kite process alive at both ends
    double browserMs = 0, browserCsw = 0;    // Kite.exe
    double trackerMs = 0, trackerCsw = 0;    // its threads named kTrackerThread
    double startMs = 0, endMs = 0;           // Unix epoch ms, as the page logs them
    double hiddenPct = -1, rafFps = -1;      // from the page's title; -1 unknown
    std::map<std::string, std::pair<double, double>> byType;  // ms, cs
    std::vector<std::pair<std::string, std::pair<double, double>>> topThreads;
};

struct RunResult {
    bool ok = false;
    std::string arm, json;
    std::vector<PhaseResult> phases;
};

RunResult RunOnce(const Options& o, const std::string& arm, int index, double tscPerMs) {
    RunResult result;
    result.arm = arm;
    const std::string label = arm + "-" + std::to_string(index);
    wchar_t temp[MAX_PATH];
    GetTempPathW(MAX_PATH, temp);
    const fs::path profile = fs::path(temp) / (L"occlusion-ab-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::wstring(label.begin(), label.end()));
    std::error_code ec;
    fs::remove_all(profile, ec);
    fs::create_directories(profile, ec);
    std::ofstream(profile / L"kite-test-profile").put('\n');
    std::ofstream(profile / L"page.html", std::ios::binary)
        << (o.page == "anim" ? std::string(kAnimPage) : o.page == "docopen" ? DocOpenPage(kAnimPage) : std::string(kStaticPage));

    // The session: one tab with the page (kitecore, beside Kite.exe).
    {
        std::wstring url = L"file:///" + (profile / L"page.html").generic_wstring();
        std::wstring cmd = L"\"" + (o.kite.parent_path() / L"kitecore.exe").wstring() + L"\" --profile \"" + profile.wstring() + L"\" open \"" + url + L"\"";
        STARTUPINFOW si{sizeof si};
        PROCESS_INFORMATION pi{};
        if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
            std::fprintf(stderr, "%s: kitecore didn't start (%lu)\n", label.c_str(), GetLastError());
            return result;
        }
        WaitForSingleObject(pi.hProcess, 30000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    HWND anchor = MakeWindow(L"occlusion-ab anchor");
    SetWindowPos(anchor, HWND_BOTTOM, GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), 40, 40, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits);
    SetEnvironmentVariableW(L"KITE_SUPPORT_PATH", profile.c_str());
    std::wstring cmd = L"\"" + o.kite.wstring() + L"\" --perf-log \"" + (profile / L"perf-log.jsonl").wstring() + L"\"" + (o.p2FromLaunch ? L"" : L" --perf-control") + L" --occlusion-log \"" +
                       (profile / L"occlusion.jsonl").wstring() + L"\"";
    if (arm == "on") cmd += L" --chromium-switches \"" + std::wstring(kOnSwitch) + L"\"";
    STARTUPINFOW si{sizeof si};
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_SHOWNOACTIVATE;
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_SUSPENDED, nullptr, nullptr, &si, &pi)) {
        std::fprintf(stderr, "%s: Kite.exe didn't start (%lu)\n", label.c_str(), GetLastError());
        DestroyWindow(anchor);
        CloseHandle(job);
        return result;
    }
    AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    const DWORD browser = pi.dwProcessId;
    HWND kite = nullptr;
    for (int i = 0; i < 300 && !kite; ++i) {
        if (WaitForSingleObject(pi.hProcess, 100) == WAIT_OBJECT_0) break;
        kite = FindKite(browser);
    }
    HWND cover = MakeWindow(L"occlusion-ab cover"), mover = MakeWindow(L"occlusion-ab mover");
    struct Raw {
        PhaseResult r;
        Snapshot a, b;
    };
    std::vector<Raw> raws;
    RECT k{};
    bool foreground = false, occlusionOn = false;
    if (kite) {
        Pump(15000);
        foreground = GetAncestor(GetForegroundWindow(), GA_ROOT) == kite;
        k = Frame(kite);
        const auto phase = [&](const char* name, auto&& body) {
            Pump(1500);
            Raw raw;
            raw.r.name = name;
            const int before = DisplayState();
            const auto pids = JobPids(job);
            raw.a = Take(pids);
            raw.r.startMs = EpochMs();
            body();
            raw.r.endMs = EpochMs();
            raw.b = Take(pids);
            raw.r.displayOn = before == 1 && DisplayState() == 1;
            LARGE_INTEGER f;
            QueryPerformanceFrequency(&f);
            raw.r.seconds = static_cast<double>(raw.b.qpc.QuadPart - raw.a.qpc.QuadPart) / f.QuadPart;
            raws.push_back(std::move(raw));
            std::fprintf(stderr, "%s %s\n", label.c_str(), name);
        };
        phase("idle", [&] { Pump(o.idleMs); });
        occlusionOn = o.p2FromLaunch || Control(kite, R"({"occlusion":"on"})");
        phase("nearMover", [&] {
            // Right of Kite, or left of it when the screen ends first; never over it.
            const int screenRight = GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN);
            const int x0 = k.right + 800 <= screenRight ? k.right + 20 : std::max<int>(GetSystemMetrics(SM_XVIRTUALSCREEN), k.left - 800);
            PlaceAbove(mover, kite, RECT{x0, k.top + 100, x0 + 300, k.top + 300});
            Slide(mover, x0, k.top + 100, o.phaseMs);
            ShowWindow(mover, SW_HIDE);
        });
        phase("covered", [&] {
            RECT r = k;
            InflateRect(&r, 10, 10);
            PlaceAbove(cover, kite, r);
            Pump(o.phaseMs);
            ShowWindow(cover, SW_HIDE);
        });
        phase("overMover", [&] {
            PlaceAbove(mover, kite, RECT{k.left + 260, k.top + 150, k.left + 560, k.top + 350});
            Slide(mover, k.left + 260, k.top + 150, o.phaseMs);
            ShowWindow(mover, SW_HIDE);
        });
        phase("lockNotice", [&] {
            DWORD session = 0;
            ProcessIdToSessionId(browser, &session);
            PostMessageW(kite, WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, session);
            Pump(o.phaseMs);
            PostMessageW(kite, WM_WTSSESSION_CHANGE, WTS_SESSION_UNLOCK, session);
        });
    } else {
        std::fprintf(stderr, "%s: no Kite window\n", label.c_str());
    }

    // Types and names while everything is still running.
    std::map<DWORD, std::string> types;
    std::map<DWORD, std::wstring> names;
    for (DWORD pid : JobPids(job)) types[pid] = TypeOf(pid, browser);
    for (const Raw& raw : raws)
        for (const auto& [tid, t] : raw.b.threads)
            if (t.pid == browser && !names.contains(tid)) names[tid] = ThreadName(tid);

    if (kite) PostMessageW(kite, WM_CLOSE, 0, 0);
    const bool closed = WaitForSingleObject(pi.hProcess, 30000) == WAIT_OBJECT_0;
    DWORD exitCode = 0;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    for (int i = 0; i < 100 && !JobPids(job).empty(); ++i) Sleep(100);
    TerminateJobObject(job, 0);  // this run's processes only
    DestroyWindow(cover);
    DestroyWindow(mover);
    DestroyWindow(anchor);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(job);

    // What the page saw, from the session Kite saved on closing.
    std::string visibility;
    {
        std::ifstream in(profile / L"session.json", std::ios::binary);
        std::stringstream ss;
        ss << in.rdbuf();
        const std::string session = ss.str();
        const size_t at = session.find("\"title\":\"vis:");
        if (at != std::string::npos) visibility = session.substr(at + 13, session.find('"', at + 13) - at - 13);
    }
    // Kite's own occlusion verdicts (--occlusion-log), "verdict@seconds" from its start.
    std::string verdicts;
    {
        std::ifstream in(profile / L"occlusion.jsonl", std::ios::binary);
        for (std::string line; std::getline(in, line);) {
            const size_t at = line.find("\"verdict\":\"");
            const size_t t = line.find("\"t\":");
            if (at == std::string::npos || t == std::string::npos) continue;
            verdicts += (verdicts.empty() ? "" : " ") + line.substr(at + 11, line.find('"', at + 11) - at - 11) + "@" +
                        line.substr(t + 4, line.find(',', t) - t - 4);
        }
    }
    fs::remove_all(profile, ec);
    const PageLog pageLog = ParsePageLog(visibility);

    for (Raw& raw : raws) {
        PhaseResult& r = raw.r;
        const double s = r.seconds;
        pageLog.Phase(r.startMs, r.endMs, r.hiddenPct, r.rafFps);
        for (const auto& [pid, cycles] : raw.b.processCycles) {
            const auto a = raw.a.processCycles.find(pid);
            if (a == raw.a.processCycles.end()) continue;
            const double ms = (cycles - a->second) / tscPerMs / s;
            r.kiteMs += ms;
            r.byType[types.contains(pid) ? types[pid] : "ended"].first += ms;
            if (pid == browser) r.browserMs = ms;
        }
        std::map<std::wstring, std::pair<double, double>> byName;
        for (const auto& [tid, b] : raw.b.threads) {
            const auto a = raw.a.threads.find(tid);
            if (a == raw.a.threads.end()) continue;
            const double cs = static_cast<double>(b.cswitches - a->second.cswitches) / s;
            r.kiteCsw += cs;
            r.byType[types.contains(b.pid) ? types[b.pid] : "ended"].second += cs;
            if (b.pid != browser) continue;
            r.browserCsw += cs;
            auto& slot = byName[names.contains(tid) ? names[tid] : L"(ended)"];
            slot.first += (b.cycles - a->second.cycles) / tscPerMs / s;
            slot.second += cs;
        }
        r.trackerMs = byName[kTrackerThread].first;
        r.trackerCsw = byName[kTrackerThread].second;
        for (const auto& [name, v] : byName) r.topThreads.push_back({Narrow(name), v});
        std::sort(r.topThreads.begin(), r.topThreads.end(), [](const auto& x, const auto& y) { return x.second.second > y.second.second; });
        if (r.topThreads.size() > 6) r.topThreads.resize(6);
    }

    result.ok = kite && closed && raws.size() == 5 && occlusionOn;
    if (kite && !occlusionOn) std::fprintf(stderr, "%s: Kite refused {\"occlusion\":\"on\"} (a build from before P2?)\n", label.c_str());
    std::string json = "{\"label\":" + Quote(label) + ",\"arm\":" + Quote(arm) + ",\"page\":" + Quote(o.page) + ",\"ok\":" + (result.ok ? "true" : "false") +
                       ",\"exit\":" + std::to_string(exitCode) + ",\"kiteForeground\":" + (foreground ? "true" : "false") + ",\"pageVisibility\":" +
                       Quote(visibility) + ",\"occlusionVerdicts\":" + Quote(verdicts) + ",\"phases\":[";
    for (size_t i = 0; i < raws.size(); ++i) {
        const PhaseResult& r = raws[i].r;
        json += std::string(i ? "," : "") + "{\"phase\":" + Quote(r.name) + ",\"s\":" + Fixed(r.seconds) + ",\"displayOn\":" + (r.displayOn ? "true" : "false") +
                ",\"kiteMsPerS\":" + Fixed(r.kiteMs, 2) + ",\"kiteCswPerS\":" + Fixed(r.kiteCsw) + ",\"browserMsPerS\":" + Fixed(r.browserMs, 2) +
                ",\"browserCswPerS\":" + Fixed(r.browserCsw) + ",\"trackerMsPerS\":" + Fixed(r.trackerMs, 3) + ",\"trackerCswPerS\":" + Fixed(r.trackerCsw) +
                ",\"pageHiddenPct\":" + (r.hiddenPct < 0 ? std::string("null") : Fixed(r.hiddenPct)) +
                ",\"rafFps\":" + (r.rafFps < 0 ? std::string("null") : Fixed(r.rafFps)) +
                ",\"byType\":{";
        bool first = true;
        for (const auto& [type, v] : r.byType) {
            json += std::string(first ? "" : ",") + Quote(type) + ":[" + Fixed(v.first, 2) + "," + Fixed(v.second) + "]";
            first = false;
        }
        json += "},\"browserThreads\":[";
        for (size_t j = 0; j < r.topThreads.size(); ++j)
            json += std::string(j ? "," : "") + "[" + Quote(r.topThreads[j].first) + "," + Fixed(r.topThreads[j].second.first, 3) + "," +
                    Fixed(r.topThreads[j].second.second) + "]";
        json += "]}";
    }
    result.json = json + "]}";
    for (Raw& raw : raws) result.phases.push_back(std::move(raw.r));
    return result;
}

double Median(std::vector<double> v) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

int Usage() {
    std::fprintf(stderr,
                 "usage: occlusion-ab display\n"
                 "       occlusion-ab --kite PATH\\Kite.exe [--runs 3] [--idle 60] [--phase 20] [--page static|anim|docopen] [--out FILE] [--any-display] [--p2-from-launch]\n");
    return 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc == 2 && std::wstring(argv[1]) == L"display") {
        std::printf("%d\n", DisplayState());
        return 0;
    }
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::wstring a = argv[i];
        const wchar_t* v = i + 1 < argc ? argv[i + 1] : nullptr;
        if (a == L"--any-display") o.anyDisplay = true;
        else if (a == L"--p2-from-launch") o.p2FromLaunch = true;
        else if (!v) return Usage();
        else if (a == L"--kite") o.kite = v, ++i;
        else if (a == L"--runs") o.runs = _wtoi(v), ++i;
        else if (a == L"--idle") o.idleMs = _wtoi(v) * 1000, ++i;
        else if (a == L"--phase") o.phaseMs = _wtoi(v) * 1000, ++i;
        else if (a == L"--page") o.page = Narrow(v), ++i;
        else if (a == L"--out") o.out = v, ++i;
        else return Usage();
    }
    if (o.kite.empty() || o.runs < 1 || (o.page != "static" && o.page != "anim" && o.page != "docopen")) return Usage();
    o.kite = fs::absolute(o.kite);
    const double tscPerMs = TscPerMs();
    std::ofstream out;
    if (!o.out.empty()) out.open(o.out, std::ios::app | std::ios::binary);

    std::map<std::string, std::vector<RunResult>> kept;  // by arm
    int dropped = 0;
    for (int i = 1; i <= o.runs; ++i) {
        for (const char* arm : {"on", "off"}) {
            if (!o.anyDisplay && DisplayState() != 1) {
                std::fprintf(stderr, "waiting for the display to come on (never woken from here)\n");
                while (DisplayState() != 1) Sleep(20000);
            }
            // Keeps a display that's on from idling off mid-run; never turns one on.
            if (DisplayState() == 1) SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED);
            RunResult r = RunOnce(o, arm, i, tscPerMs);
            SetThreadExecutionState(ES_CONTINUOUS);
            if (out.is_open()) out << r.json << "\n" << std::flush;
            const bool displayOk = o.anyDisplay || std::all_of(r.phases.begin(), r.phases.end(), [](const PhaseResult& p) { return p.displayOn; });
            if (r.ok && displayOk) kept[arm].push_back(std::move(r));
            else ++dropped;
        }
    }

    // The medians, as markdown.
    std::printf("Kite for Windows, Chromium's native occlusion tracker on and off (%s page; medians of %zu and %zu runs, %d left out; ms/s from CPU cycles)\n\n",
                o.page.c_str(), kept["on"].size(), kept["off"].size(), dropped);
    std::printf("| phase | metric | on | off | off - on |\n|---|---|---:|---:|---:|\n");
    const char* const phaseNames[] = {"idle", "nearMover", "covered", "overMover", "lockNotice"};
    struct Metric {
        const char* name;
        double PhaseResult::*field;
    };
    const Metric metrics[] = {{"Kite CPU ms/s", &PhaseResult::kiteMs},          {"Kite cs/s", &PhaseResult::kiteCsw},
                              {"browser CPU ms/s", &PhaseResult::browserMs},    {"browser cs/s", &PhaseResult::browserCsw},
                              {"tracker thread CPU ms/s", &PhaseResult::trackerMs}, {"tracker thread cs/s", &PhaseResult::trackerCsw},
                              {"page hidden %", &PhaseResult::hiddenPct},       {"page rAF fps", &PhaseResult::rafFps}};
    for (size_t p = 0; p < std::size(phaseNames); ++p) {
        for (const Metric& m : metrics) {
            double med[2] = {};
            int column = 0;
            for (const char* arm : {"on", "off"}) {
                std::vector<double> v;
                for (const RunResult& r : kept[arm])
                    if (p < r.phases.size() && r.phases[p].*m.field >= 0) v.push_back(r.phases[p].*m.field);
                med[column++] = v.empty() ? -1 : Median(v);
            }
            if (med[0] < 0 && med[1] < 0) continue;  // the static page has no rAF samples
            std::printf("| %s | %s | %s | %s | %s |\n", phaseNames[p], m.name, Fixed(med[0], 2).c_str(), Fixed(med[1], 2).c_str(), Fixed(med[1] - med[0], 2).c_str());
        }
    }
    return dropped && kept["on"].empty() ? 3 : 0;
}
