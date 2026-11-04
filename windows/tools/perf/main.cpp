// kiteperf: measures Kite for Windows (docs/windows.md, Measuring performance). Never linked into
// Kite.exe, never shipped (docs/windows-architecture.md, windows/tools).
//
//   kiteperf --kite PATH [--scenario standard|idle|startup|smoke] [--phases a,b,c] [--runs 3]
//            [--out result.json] [--label NAME] [--chromium-switches "..."] [--keep-profile]
//   kiteperf --compare before.json after.json      a markdown table of the two
//
// Each run launches Kite.exe on a fresh %TEMP% profile holding sessions/perf-10tabs-2spaces.json,
// with pages from its own loopback server (PageServer.h), suspended into a job object, then
// drives it through --perf-control and reads --perf-log (shell/PerfLog.h) while sampling every
// process of Kite's once a second and at every phase's start and end (Processes.h). Nothing
// here sends real input, moves the pointer or asks for the focus: Kite opens behind other
// windows, its pointer moves are posted to it, and the cover is a window that never activates,
// just over Kite in the z-order.
//
// The result (schema kiteperf/1) holds the median of the runs that completed, and every run in
// allRuns. Exit codes: 0 done, 1 usage, 2 setup failed, 3 a run failed (a request Kite refused,
// a page that didn't load, a phase that measured nothing), 4 the idle phase drew with the real
// pointer nowhere near Kite.

#include <windows.h>

#include <dwmapi.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "LogReader.h"
#include "PageServer.h"
#include "Processes.h"
#include "Report.h"
#include "core/Json.h"
#include "shell/PerfProtocol.h"
#include "shell/Text.h"

namespace {

using namespace kiteperf;
using kite::Narrow;
using kite::Widen;
using kite::perf::Now;

constexpr uint16_t kPort = 18765;
// p1–p10 on 127.0.0.1–10 (the session's ten tabs), title-tick on .11 and anim on .12: each its own site.
constexpr int kHosts = 12;
const char* const kTitleTickURL = "http://127.0.0.11:18765/title-tick.html";
const char* const kAnimURL = "http://127.0.0.12:18765/anim.html";
// The standard scenario's phases, in order (--phases picks some; open and settle always run).
const char* const kPhases[] = {"open",  "settle",    "idle",       "switchSpaces", "switchTabs", "reload",
                               "hover", "titleTick", "anim",       "hiddenAnim",   "covered",    "minimized"};

std::string FixtureTab(const char* name) { return std::string("5EED0000-0000-4000-8000-0000000000") + name; }

void Print(const std::string& text) {
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
}
void Say(const std::string& text) {
    DWORD written = 0;
    const std::string line = "kiteperf: " + text + "\n";
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

// MARK: Kite's window, as the window manager shows it

bool Cloaked(HWND hwnd) {
    DWORD cloaked = 0;
    return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof cloaked)) && cloaked;
}

// How much of Kite's window is on a screen and under no other visible window: its rect, less
// every visible, uncloaked, unminimized window above it in the z-order (click-through layered
// overlays aside). None when it can't be told; 0 when Kite is hidden, minimized or cloaked.
std::optional<double> VisiblePct(HWND kite) {
    if (!kite || !IsWindow(kite)) return std::nullopt;
    if (!IsWindowVisible(kite) || IsIconic(kite) || Cloaked(kite)) return 0.0;
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(kite, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r)) && !GetWindowRect(kite, &r)) return std::nullopt;
    const double total = static_cast<double>(r.right - r.left) * (r.bottom - r.top);
    if (total <= 0) return 0.0;
    HRGN shown = CreateRectRgnIndirect(&r);
    // Off every screen counts as covered.
    HRGN screens = CreateRectRgn(0, 0, 0, 0);
    EnumDisplayMonitors(
        nullptr, nullptr,
        [](HMONITOR, HDC, LPRECT monitor, LPARAM data) -> BOOL {
            HRGN one = CreateRectRgnIndirect(monitor);
            CombineRgn(reinterpret_cast<HRGN>(data), reinterpret_cast<HRGN>(data), one, RGN_OR);
            DeleteObject(one);
            return TRUE;
        },
        reinterpret_cast<LPARAM>(screens));
    CombineRgn(shown, shown, screens, RGN_AND);
    DeleteObject(screens);
    for (HWND above = GetWindow(kite, GW_HWNDPREV); above; above = GetWindow(above, GW_HWNDPREV)) {
        if (!IsWindowVisible(above) || IsIconic(above) || Cloaked(above)) continue;
        const LONG_PTR ex = GetWindowLongPtrW(above, GWL_EXSTYLE);
        if ((ex & WS_EX_LAYERED) && (ex & WS_EX_TRANSPARENT)) continue;
        RECT a{};
        if (FAILED(DwmGetWindowAttribute(above, DWMWA_EXTENDED_FRAME_BOUNDS, &a, sizeof a)) && !GetWindowRect(above, &a)) continue;
        HRGN cut = CreateRectRgnIndirect(&a);
        CombineRgn(shown, shown, cut, RGN_DIFF);
        DeleteObject(cut);
    }
    double area = 0;
    if (const DWORD bytes = GetRegionData(shown, 0, nullptr)) {
        std::vector<unsigned char> buffer(bytes);
        auto* data = reinterpret_cast<RGNDATA*>(buffer.data());
        if (GetRegionData(shown, bytes, data)) {
            const RECT* rects = reinterpret_cast<const RECT*>(data->Buffer);
            for (DWORD i = 0; i < data->rdh.nCount; ++i) area += static_cast<double>(rects[i].right - rects[i].left) * (rects[i].bottom - rects[i].top);
        }
    }
    DeleteObject(shown);
    return area / total * 100;
}

DWORD PidOf(HWND hwnd) {
    DWORD pid = 0;
    if (hwnd) GetWindowThreadProcessId(hwnd, &pid);
    return pid;
}

// MARK: The cover

// A black window over Kite's, never activated and never topmost: it goes just above Kite in the
// z-order, so it covers Kite and nothing of anyone else's.
HWND MakeCover(HWND kite) {
    static const ATOM atom = [] {
        WNDCLASSEXW wc{sizeof wc};
        wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        wc.lpszClassName = L"KiteperfCover";
        return RegisterClassExW(&wc);
    }();
    if (!atom) return nullptr;
    RECT r{};
    GetWindowRect(kite, &r);
    HWND cover = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"KiteperfCover", L"kiteperf cover", WS_POPUP, r.left, r.top,
                                 r.right - r.left, r.bottom - r.top, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!cover) return nullptr;
    HWND above = GetWindow(kite, GW_HWNDPREV);
    SetWindowPos(cover, above ? above : HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
    return cover;
}

// MARK: A run

struct Options {
    std::filesystem::path kite;
    std::string scenario = "standard";
    std::set<std::string> phases;  // empty: all of the scenario's
    int runs = 3;
    std::filesystem::path out;
    std::string label;
    std::wstring switches;
    bool keepProfile = false;
    std::filesystem::path assets;
};

struct Phase {
    std::string name;
    Mark beginMark, endMark;
    int commands = 0;
    Object extra;
};

class Run {
public:
    Run(const Options& options, PageServer& server, int index) : options_(options), server_(server), index_(index) {}
    // The run's result; empty `error` when it completed (`kiteFailed`: Kite's fault, exit 3,
    // rather than setup's, exit 2).
    Value Go(std::wstring& error, bool& kiteFailed);

private:
    std::wstring Launch();
    void Sample();
    bool Send(const std::string& json) {
        COPYDATASTRUCT data{kite::perf::kControlTag, static_cast<DWORD>(json.size()), const_cast<char*>(json.data())};
        DWORD_PTR answer = 0;
        return SendMessageTimeoutW(kite_, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_NORMAL, 5000, &answer) && answer == 1;
    }
    void Fail(const std::string& why) {
        if (failure_.empty()) failure_ = why;
    }
    // A shortcut command; a refused one fails the run.
    void Command(const std::string& id) {
        if (current_) ++current_->commands;
        if (!Send("{\"command\":\"" + id + "\",\"qpc\":" + std::to_string(Now()) + "}")) Fail("Kite refused the command " + id);
    }
    void Request(const std::string& json) {
        if (!Send(json)) Fail("Kite refused " + json);
    }
    // Waits, pumping the cover's messages and reading the log, until `done` or `seconds`.
    bool WaitFor(double seconds, const std::function<bool()>& done = nullptr) {
        const int64_t until = Now() + static_cast<int64_t>(seconds * QpcFrequency());
        for (;;) {
            log_->Pump();
            if (done && done()) return true;
            const int64_t now = Now();
            if (now >= until) return false;
            const DWORD wait = static_cast<DWORD>(std::min<double>(Ms(now, until), done ? 20.0 : 50.0));
            MsgWaitForMultipleObjects(0, nullptr, FALSE, std::max<DWORD>(wait, 1), QS_ALLINPUT);
            MSG message;
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
        }
    }
    // A tab's page loads after `after` (3 s at most, else the run fails); a tab already loaded
    // this run isn't waited for.
    void WaitLoad(const std::string& tab, int64_t after, std::vector<double>* loadMs) {
        if (loaded_.contains(tab)) {
            WaitFor(0.3);
            return;
        }
        const Mark* end = nullptr;
        if (!WaitFor(3.0, [&] { return (end = log_->Find("load-end", after, &tab)) != nullptr; })) {
            return Fail("tab " + tab + " didn't load within 3 s");
        }
        if (loadMs) loadMs->push_back(Ms(after, end->qpc));
        loaded_.insert(tab);
    }
    // Any page's load after `after` (a tab Kite just made).
    void WaitAnyLoad(int64_t after, const char* what) {
        if (!WaitFor(3.0, [&] { return log_->Find("load-end", after) != nullptr; })) Fail(std::string(what) + " didn't load within 3 s");
    }
    bool Want(const std::string& name) const {
        return name == "open" || name == "settle" || options_.phases.empty() || options_.phases.contains(name);
    }
    void RunPhase(const std::string& name, const std::function<void(Phase&)>& body);
    void Scenario();
    Value Result();
    Object PhaseResult(const Phase& phase) const;

    const Options& options_;
    PageServer& server_;
    const int index_;
    std::filesystem::path profile_;
    std::unique_ptr<Processes> processes_;
    std::unique_ptr<LogReader> log_;
    PROCESS_INFORMATION kiteProcess_{};
    HWND kite_ = nullptr;
    int64_t launchQpc_ = 0, closeQpc_ = 0;
    std::set<std::string> loaded_;
    std::vector<Phase> phases_;
    Phase* current_ = nullptr;
    // Sampling, once a second on its own thread and at every phase mark on this one.
    std::thread sampler_;
    std::mutex takeMutex_, snapshotsMutex_;
    std::vector<Snapshot> snapshots_;
    bool stopSampling_ = false;
    std::condition_variable_any sampleWake_;
    uint64_t faviconsBefore_ = 0, requestsBefore_ = 0;
    std::string failure_;
};

void Run::Sample() {
    std::lock_guard take(takeMutex_);
    Snapshot s = processes_->Take();
    const HWND kite = kite_;
    if (kite) {
        s.kiteVisiblePct = VisiblePct(kite);
        POINT at{};
        s.pointerOverKite = GetCursorPos(&at) && PidOf(WindowFromPoint(at)) == kiteProcess_.dwProcessId;
        s.kiteInFront = PidOf(GetForegroundWindow()) == kiteProcess_.dwProcessId;
    }
    std::lock_guard lock(snapshotsMutex_);
    snapshots_.push_back(std::move(s));
}

std::wstring Run::Launch() {
    wchar_t temp[MAX_PATH];
    GetTempPathW(MAX_PATH, temp);
    profile_ = std::filesystem::path(temp) / (L"kiteperf-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(index_) +
                                              L"-" + std::to_wstring(GetTickCount64() % 100000));
    std::error_code ec;
    std::filesystem::create_directories(profile_, ec);
    if (ec) return L"couldn't make the profile " + profile_.wstring();
    std::filesystem::copy_file(options_.assets / L"sessions" / L"perf-10tabs-2spaces.json", profile_ / L"session.json", ec);
    if (ec) return L"couldn't copy the session fixture: " + Widen(ec.message());
    // The mark of a test profile, without which Kite refuses its measurement hooks.
    {
        std::ofstream marker(profile_ / kite::perf::kTestProfileMarker, std::ios::binary);
        marker << "kiteperf\n";
        if (!marker) return L"couldn't write the profile's test marker";
    }

    std::wstring error;
    processes_ = Processes::Create(error);
    if (!processes_) return error;
    log_ = std::make_unique<LogReader>(profile_ / L"perf.jsonl");

    // Kite's environment: ours, with KITE_SUPPORT_PATH the fresh profile.
    std::wstring environment;
    if (wchar_t* block = GetEnvironmentStringsW()) {
        for (const wchar_t* at = block; *at; at += std::wcslen(at) + 1) {
            if (_wcsnicmp(at, L"KITE_SUPPORT_PATH=", 18) != 0) environment.append(at).push_back(L'\0');
        }
        FreeEnvironmentStringsW(block);
    }
    environment.append(L"KITE_SUPPORT_PATH=" + profile_.wstring()).push_back(L'\0');
    environment.push_back(L'\0');

    std::wstring command = L"\"" + options_.kite.wstring() + L"\" --perf-log \"" + (profile_ / L"perf.jsonl").wstring() + L"\" --perf-control";
    if (!options_.switches.empty()) command += L" --chromium-switches \"" + options_.switches + L"\"";
    // Kite's stderr (why it failed, if it does) into the profile, and that one handle is all it
    // inherits: never the page server's sockets.
    SECURITY_ATTRIBUTES inherit{sizeof inherit, nullptr, TRUE};
    HANDLE output = CreateFileW((profile_ / L"kite-output.txt").c_str(), GENERIC_WRITE, FILE_SHARE_READ, &inherit, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) return L"couldn't make kite-output.txt";
    SIZE_T attributeBytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
    std::vector<unsigned char> attributes(attributeBytes);
    auto* list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof startup;
    startup.StartupInfo.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    startup.StartupInfo.wShowWindow = SW_SHOWNOACTIVATE;
    startup.StartupInfo.hStdOutput = startup.StartupInfo.hStdError = output;
    HANDLE inherited[] = {output};
    if (!InitializeProcThreadAttributeList(list, 1, 0, &attributeBytes) ||
        !UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof inherited, nullptr, nullptr)) {
        CloseHandle(output);
        return L"couldn't limit the handles Kite inherits (" + std::to_wstring(GetLastError()) + L")";
    }
    startup.lpAttributeList = list;
    const std::wstring directory = options_.kite.parent_path().wstring();
    launchQpc_ = Now();
    const BOOL started = CreateProcessW(options_.kite.c_str(), command.data(), nullptr, nullptr, TRUE,
                                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT, environment.data(),
                                        directory.c_str(), &startup.StartupInfo, &kiteProcess_);
    DeleteProcThreadAttributeList(list);
    CloseHandle(output);
    if (!started) return L"couldn't start " + options_.kite.wstring() + L" (" + std::to_wstring(GetLastError()) + L")";
    if (!AssignProcessToJobObject(processes_->Job(), kiteProcess_.hProcess)) {
        TerminateProcess(kiteProcess_.hProcess, 1);
        return L"couldn't put Kite in the job (" + std::to_wstring(GetLastError()) + L")";
    }
    processes_->SetRoot(kiteProcess_.dwProcessId, options_.kite.filename().wstring());
    ResumeThread(kiteProcess_.hThread);
    faviconsBefore_ = server_.FaviconHits();
    requestsBefore_ = server_.Requests();
    sampler_ = std::thread([this] {
        std::unique_lock lock(snapshotsMutex_);
        while (!stopSampling_) {
            lock.unlock();
            Sample();
            lock.lock();
            sampleWake_.wait_for(lock, std::chrono::milliseconds(1000), [this] { return stopSampling_; });
        }
    });
    return {};
}

void Run::RunPhase(const std::string& name, const std::function<void(Phase&)>& body) {
    if (!failure_.empty() || !Want(name)) return;
    Say("run " + std::to_string(index_ + 1) + ": " + name);
    Phase phase;
    phase.name = name;
    current_ = &phase;
    const auto markNow = [&](const std::string& mark, Mark& into) {
        const int64_t sent = Now();
        if (!Send("{\"mark\":\"" + mark + "\"}")) {
            Fail("Kite didn't take the mark " + mark);
            return false;
        }
        const Mark* m = nullptr;
        if (!WaitFor(5, [&] { return (m = log_->Find(mark, sent)) != nullptr; })) {
            Fail("the mark " + mark + " never reached the log");
            return false;
        }
        into = *m;
        return true;
    };
    // A sample just inside each end, so the phase's rates are its own.
    if (markNow("phase-begin:" + name, phase.beginMark)) {
        Sample();
        body(phase);
        Sample();
        if (markNow("phase-end:" + name, phase.endMark)) {
            // A command Kite accepted but then couldn't run (its state had moved on).
            for (const Mark& m : log_->marks) {
                if (m.name == "control-refused" && m.qpc >= phase.beginMark.qpc && m.qpc <= phase.endMark.qpc) {
                    Fail("Kite refused the command " + m.detail + " when it came to run it, in " + name);
                    break;
                }
            }
            phases_.push_back(std::move(phase));
        }
    }
    current_ = nullptr;
}

void Run::Scenario() {
    const std::string& scenario = options_.scenario;
    const bool smoke = scenario == "smoke";
    if (scenario == "startup") return;
    RunPhase("open", [&](Phase& phase) {
        std::vector<double> loads;
        for (int n = 1; n <= (smoke ? 2 : 8) && failure_.empty(); ++n) {
            const int64_t at = Now();
            Command("tab" + std::to_string(n));
            WaitLoad(FixtureTab(("A" + std::to_string(n)).c_str()), at, &loads);
        }
        if (!smoke && failure_.empty()) {
            int64_t at = Now();
            Command("nextSpace");
            WaitLoad(FixtureTab("B1"), at, &loads);
            at = Now();
            Command("tab1");
            WaitLoad(FixtureTab("B1"), at, &loads);
            at = Now();
            Command("tab2");
            WaitLoad(FixtureTab("B2"), at, &loads);
            Command("previousSpace");
            WaitFor(1);
        }
        phase.extra["loads"] = static_cast<double>(loads.size());
        phase.extra["loadP50Ms"] = RoundOrNull(Percentile(loads, 50), 1);
        phase.extra["loadMaxMs"] = RoundOrNull(Percentile(loads, 100), 1);
    });
    RunPhase("settle", [&](Phase&) { WaitFor(smoke ? 3 : 30); });
    RunPhase("idle", [&](Phase&) { WaitFor(smoke ? 5 : 60); });
    if (scenario == "idle") return;
    // Next and Previous Space every 0.5 s: the pages' slide and the theme's crossfade.
    RunPhase("switchSpaces", [&](Phase&) {
        const int switches = smoke ? 4 : 40;
        for (int i = 0; i < switches && failure_.empty(); ++i) {
            Command(i % 2 ? "previousSpace" : "nextSpace");
            WaitFor(0.5);
        }
    });
    if (!smoke) {
        RunPhase("switchTabs", [&](Phase&) {
            for (int i = 0; i < 20 && failure_.empty(); ++i) {
                Command(i % 2 ? "tab1" : "tab2");
                WaitFor(0.5);
            }
        });
        RunPhase("reload", [&](Phase&) {
            for (int i = 0; i < 20 && failure_.empty(); ++i) {
                Command("reloadPage");
                WaitFor(0.5);
            }
        });
    }
    // The pointer over the sidebar's rows, posted to Kite at 120 Hz (never the real pointer).
    RunPhase("hover", [&](Phase& phase) {
        UINT dpi = GetDpiForWindow(kite_);
        if (!dpi) dpi = USER_DEFAULT_SCREEN_DPI;
        const double scale = dpi / 96.0;
        HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
        const double seconds = smoke ? 1 : 10;
        const int64_t start = Now();
        int moves = 0;
        for (int i = 0; failure_.empty(); ++i) {
            const double t = i / 120.0;
            if (t >= seconds) break;
            // The rows from the first tab (105pt) to the eighth: down and back every 2 s.
            const double along = std::fmod(t, 2.0) / 2.0;
            const double y = 110 + 320 * (along < 0.5 ? along * 2 : 2 - along * 2);
            Request("{\"input\":\"move\",\"x\":" + std::to_string(static_cast<int>(120 * scale)) +
                    ",\"y\":" + std::to_string(static_cast<int>(y * scale)) + ",\"qpc\":" + std::to_string(Now()) + "}");
            ++moves;
            const int64_t next = start + static_cast<int64_t>((i + 1) / 120.0 * QpcFrequency());
            const double waitMs = Ms(Now(), next);
            if (waitMs > 0) {
                LARGE_INTEGER due{};
                due.QuadPart = -static_cast<LONGLONG>(waitMs * 1e4);
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 100);
                else Sleep(static_cast<DWORD>(waitMs));
            }
            log_->Pump();
        }
        if (timer) CloseHandle(timer);
        Request("{\"input\":\"leave\"}");
        WaitFor(0.5);
        phase.extra["moves"] = static_cast<double>(moves);
    });
    if (smoke) return;
    // A page whose title changes every second: the sidebar's row, nothing else.
    if (Want("titleTick")) {
        RunPhase("titleTick", [&](Phase&) {
            const int64_t at = Now();
            Request(std::string("{\"open\":\"") + kTitleTickURL + "\"}");
            WaitAnyLoad(at, "title-tick.html");
            WaitFor(20);
        });
        Command("archiveTab");
        WaitFor(1);
    }
    if (!Want("anim") && !Want("hiddenAnim") && !Want("covered") && !Want("minimized")) return;
    const int64_t animAt = Now();
    Request(std::string("{\"open\":\"") + kAnimURL + "\"}");  // tab 1 now
    WaitAnyLoad(animAt, "anim.html");
    RunPhase("anim", [&](Phase&) { WaitFor(10); });
    if (Want("hiddenAnim")) {
        Command("tab2");
        RunPhase("hiddenAnim", [&](Phase&) { WaitFor(20); });
        Command("tab1");
        WaitFor(1);
    }
    RunPhase("covered", [&](Phase& phase) {
        HWND cover = MakeCover(kite_);
        phase.extra["coverMade"] = cover != nullptr;
        WaitFor(20);
        if (cover) DestroyWindow(cover);
    });
    WaitFor(1);
    RunPhase("minimized", [&](Phase&) {
        ShowWindow(kite_, SW_SHOWMINNOACTIVE);
        WaitFor(20);
    });
}

Value Run::Go(std::wstring& error, bool& kiteFailed) {
    kiteFailed = false;
    if (error = Launch(); !error.empty()) return {};
    const auto stop = [&] {
        {
            std::lock_guard lock(snapshotsMutex_);
            stopSampling_ = true;
        }
        sampleWake_.notify_all();
        if (sampler_.joinable()) sampler_.join();
    };
    // Kite's window: once the log says it's shown, the window of its class in its process.
    const Mark* shown = nullptr;
    WaitFor(60, [&] {
        if (WaitForSingleObject(kiteProcess_.hProcess, 0) == WAIT_OBJECT_0) return true;
        return (shown = log_->Find("shown")) != nullptr;
    });
    if (shown) {
        struct Search {
            DWORD pid;
            HWND found;
        } search{kiteProcess_.dwProcessId, nullptr};
        EnumWindows(
            [](HWND hwnd, LPARAM data) -> BOOL {
                auto* s = reinterpret_cast<Search*>(data);
                wchar_t name[64];
                if (PidOf(hwnd) == s->pid && GetClassNameW(hwnd, name, 64) && std::wcscmp(name, kite::perf::kWindowClass) == 0) {
                    s->found = hwnd;
                    return FALSE;
                }
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&search));
        std::lock_guard take(takeMutex_);
        kite_ = search.found;
    }
    if (!kite_) {
        stop();
        kiteFailed = true;
        std::ifstream in(profile_ / L"kite-output.txt");
        const std::string said{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
        error = L"Kite's window never showed" + (said.empty() ? std::wstring() : L": " + Widen(said));
        return {};
    }
    // The first page (the session's selected tab).
    const std::string first = FixtureTab("A1");
    if (!WaitFor(30, [&] { return log_->Find("load-end", 0, &first) != nullptr; })) Fail("the first page didn't load within 30 s");
    loaded_.insert(first);
    WaitFor(2);
    if (PidOf(GetForegroundWindow()) == kiteProcess_.dwProcessId) Say("Kite is the foreground window after launch");

    if (failure_.empty()) Scenario();
    // The smoke scenario must have measured something in each phase.
    if (failure_.empty() && options_.scenario == "smoke") {
        const auto phase = [&](const char* name) -> const Phase* {
            for (const Phase& p : phases_) {
                if (p.name == name) return &p;
            }
            return nullptr;
        };
        const Phase* switches = phase("switchSpaces");
        const Phase* hover = phase("hover");
        const auto inside = [](const Phase* p, int64_t qpc) { return p && qpc >= p->beginMark.qpc && qpc <= p->endMark.qpc; };
        if (!std::any_of(log_->frames.begin(), log_->frames.end(), [&](const FrameRecord& f) { return inside(switches, f.qpc); })) {
            Fail("switchSpaces logged no crossfade frames");
        }
        if (!std::any_of(log_->inputs.begin(), log_->inputs.end(), [&](const InputRecord& r) { return r.kind == "move" && inside(hover, r.inputQpc); })) {
            Fail("hover logged no pointer moves");
        }
    }

    // Shutdown: one WM_CLOSE, then every process gone (30 s at most, then the job is ended).
    closeQpc_ = Now();
    PostMessageW(kite_, WM_CLOSE, 0, 0);
    WaitFor(30, [&] { return processes_->EmptyAt() != 0; });
    const bool closed = processes_->EmptyAt() != 0;
    if (!closed) TerminateJobObject(processes_->Job(), 1);
    WaitFor(0.5);
    stop();
    Value result = Result();
    Object& out = *result.AsObject();
    Object shutdown;
    const Mark* loopEnd = log_->Find("loop-end", closeQpc_);
    const Mark* exited = log_->Find("exit", closeQpc_);
    shutdown["closed"] = closed;
    shutdown["windowClosedMs"] = loopEnd ? Value(Round(Ms(closeQpc_, loopEnd->qpc), 1)) : Value();
    shutdown["browserExitMs"] = exited ? Value(Round(Ms(closeQpc_, exited->qpc), 1)) : Value();
    shutdown["allExitedMs"] = closed ? Value(Round(Ms(closeQpc_, processes_->EmptyAt()), 1)) : Value();
    DWORD code = 0;
    shutdown["exitCode"] = GetExitCodeProcess(kiteProcess_.hProcess, &code) ? Value(static_cast<double>(code)) : Value();
    out["shutdown"] = std::move(shutdown);
    out["faviconHits"] = static_cast<double>(server_.FaviconHits() - faviconsBefore_);
    out["requests"] = static_cast<double>(server_.Requests() - requestsBefore_);
    bool inFront = false;
    for (const Snapshot& s : snapshots_) inFront = inFront || s.kiteInFront;
    out["tookFocus"] = inFront;
    if (!failure_.empty()) out["failure"] = failure_;
    CloseHandle(kiteProcess_.hThread);
    CloseHandle(kiteProcess_.hProcess);
    processes_.reset();  // kills anything left
    log_.reset();
    if (!options_.keepProfile) {
        for (int attempt = 0; attempt < 10; ++attempt) {
            std::error_code ec;
            std::filesystem::remove_all(profile_, ec);
            if (!ec) break;
            Sleep(500);
        }
    } else {
        out["profile"] = Utf8(profile_);
    }
    if (!failure_.empty()) {
        kiteFailed = true;
        error = Widen(failure_);
    }
    return result;
}

// What the processes used over a phase: rates between consecutive samples inside it (one is
// taken just after its first mark and one just before its last), sizes as the median of them.
Object Run::PhaseResult(const Phase& phase) const {
    Object out;
    const int64_t begin = phase.beginMark.qpc, end = phase.endMark.qpc;
    out["name"] = phase.name;
    out["seconds"] = Round(Ms(begin, end) / 1000, 1);
    std::vector<const Snapshot*> window;
    for (const Snapshot& s : snapshots_) {
        if (s.qpc >= begin && s.qpc <= end) window.push_back(&s);
    }
    const bool gpu = processes_->HasGpuCounters();
    out["samples"] = static_cast<double>(window.size());

    // Kite's own counters, from the phase's two marks.
    Object kite;
    kite["presents"] = phase.endMark.presents - phase.beginMark.presents;
    kite["realPointerMoves"] = phase.endMark.pointerMoves - phase.beginMark.pointerMoves;
    kite["commits"] = phase.endMark.commits - phase.beginMark.commits;
    Object draws;
    for (const auto& [view, count] : phase.endMark.draws) {
        draws[view] = count - (phase.beginMark.draws.contains(view) ? phase.beginMark.draws.at(view) : 0);
    }
    kite["surfaceDraws"] = draws;
    double longest = 0;
    int longOnes = 0;
    for (const DispatchRecord& d : log_->dispatches) {
        if (d.qpc < begin || d.qpc > end) continue;
        ++longOnes;
        longest = std::max(longest, d.ms);
    }
    kite["longDispatches"] = static_cast<double>(longOnes);
    kite["maxDispatchMs"] = Round(longest, 1);
    out["kite"] = std::move(kite);
    out["commands"] = static_cast<double>(phase.commands);

    using Filter = std::function<bool(const ProcessSample&)>;
    // A running total's increase from one sample to the next: from 0 for a process that started
    // between them, none when either side couldn't be read.
    const auto delta = [](const Snapshot& a, const ProcessSample& p, const std::optional<double> ProcessSample::*field) -> std::optional<double> {
        const auto& now = p.*field;
        if (!now) return std::nullopt;
        auto before = std::find_if(a.processes.begin(), a.processes.end(), [&](const ProcessSample& q) { return q.pid == p.pid; });
        if (before == a.processes.end()) return p.created > a.fileTime ? std::optional<double>(*now) : std::nullopt;
        const auto& then = (*before).*field;
        return then ? std::optional<double>(std::max(0.0, *now - *then)) : std::nullopt;
    };
    const auto metrics = [&](const Filter& include) {
        Object m;
        double dt = 0;
        std::optional<double> cpu, io, ops, switches, gpuMs;
        const auto add = [](std::optional<double>& sum, std::optional<double> d) {
            if (d) sum = sum.value_or(0) + *d;
        };
        for (size_t k = 1; k < window.size(); ++k) {
            const Snapshot& a = *window[k - 1];
            const Snapshot& b = *window[k];
            dt += Ms(a.qpc, b.qpc) / 1000;
            for (const ProcessSample& p : b.processes) {
                if (!include(p)) continue;
                add(cpu, delta(a, p, &ProcessSample::cpuMs));
                add(io, delta(a, p, &ProcessSample::ioWriteBytes));
                add(ops, delta(a, p, &ProcessSample::ioWriteOps));
                add(switches, delta(a, p, &ProcessSample::contextSwitches));
                add(gpuMs, delta(a, p, &ProcessSample::gpuRunningMs));
            }
        }
        // Sizes: every sample of a live process (an ended one's last sample has none).
        std::vector<double> privateWs, commit, dedicated, shared, handles, threads, count;
        for (const Snapshot* sample : window) {
            std::optional<double> w, c, d, s, h, t;
            double n = 0;
            for (const ProcessSample& p : sample->processes) {
                if (!include(p) || p.exited) continue;
                add(w, p.privateWsBytes);
                add(c, p.commitBytes);
                add(d, p.gpuDedicatedBytes);
                add(s, p.gpuSharedBytes);
                add(h, p.handles);
                add(t, p.threads);
                ++n;
            }
            if (w) privateWs.push_back(*w / 1048576);
            if (c) commit.push_back(*c / 1048576);
            if (d) dedicated.push_back(*d / 1048576);
            if (s) shared.push_back(*s / 1048576);
            if (h) handles.push_back(*h);
            if (t) threads.push_back(*t);
            count.push_back(n);
        }
        const auto rate = [&](std::optional<double> total, double unit = 1) {
            return dt > 0 && total ? Value(Round(*total / unit / dt)) : Value();
        };
        m["cpuMsPerS"] = rate(cpu);
        m["ioWriteKBPerS"] = rate(io, 1024);
        m["ioWriteOpsPerS"] = rate(ops);
        m["cswitchPerS"] = rate(switches);
        m["gpuMsPerS"] = gpu ? rate(gpuMs) : Value();
        m["privateWsMB"] = RoundOrNull(Percentile(privateWs, 50), 1);
        m["commitMB"] = RoundOrNull(Percentile(commit, 50), 1);
        m["gpuDedicatedMB"] = gpu ? RoundOrNull(Percentile(dedicated, 50), 1) : Value();
        m["gpuSharedMB"] = gpu ? RoundOrNull(Percentile(shared, 50), 1) : Value();
        m["handles"] = RoundOrNull(Percentile(handles, 50), 0);
        m["threads"] = RoundOrNull(Percentile(threads, 50), 0);
        m["processCount"] = RoundOrNull(Percentile(count, 50), 0);
        return m;
    };
    out["totals"] = metrics([](const ProcessSample&) { return true; });
    // The job's own CPU over the same samples: within a little of the sum above, unless a
    // process ran outside the job or was missed.
    if (window.size() > 1 && window.front()->jobCpuMs && window.back()->jobCpuMs) {
        const double dt = Ms(window.front()->qpc, window.back()->qpc) / 1000;
        if (dt > 0) out["totals"].AsObject()->insert_or_assign("jobCpuMsPerS", Round((*window.back()->jobCpuMs - *window.front()->jobCpuMs) / dt));
    }
    Object byType;
    std::set<std::string> types;
    for (const Snapshot* s : window) {
        for (const ProcessSample& p : s->processes) types.insert(p.type);
    }
    for (const std::string& type : types) byType[type] = metrics([&](const ProcessSample& p) { return p.type == type; });
    out["byType"] = std::move(byType);
    Array processes;
    std::set<DWORD> pids;
    for (const Snapshot* s : window) {
        for (const ProcessSample& p : s->processes) {
            if (!pids.insert(p.pid).second) continue;
            Object one = metrics([&](const ProcessSample& q) { return q.pid == p.pid; });
            one.erase("processCount");
            one["pid"] = static_cast<double>(p.pid);
            one["type"] = p.type;
            if (!p.subtype.empty()) one["subtype"] = p.subtype;
            processes.push_back(std::move(one));
        }
    }
    out["processes"] = std::move(processes);

    // Kite's window over the phase, and the machine around it.
    Object windowState;
    std::vector<double> visible;
    int pointerOver = 0, inFront = 0;
    for (const Snapshot* s : window) {
        if (s->kiteVisiblePct) visible.push_back(*s->kiteVisiblePct);
        pointerOver += s->pointerOverKite ? 1 : 0;
        inFront += s->kiteInFront ? 1 : 0;
    }
    windowState["kiteVisiblePct"] = RoundOrNull(Percentile(visible, 50), 0);
    windowState["pointerOverKiteSamples"] = static_cast<double>(pointerOver);
    windowState["kiteInFrontSamples"] = static_cast<double>(inFront);
    out["window"] = windowState;
    out["kiteInFront"] = inFront > 0;
    Object context;
    out["noisy"] = false;
    if (window.size() > 1) {
        const Snapshot& a = *window.front();
        const Snapshot& b = *window.back();
        const double dt = Ms(a.qpc, b.qpc) / 1000;
        context["dwmCpuMsPerS"] = a.dwmCpuMs && b.dwmCpuMs ? Value(Round((*b.dwmCpuMs - *a.dwmCpuMs) / dt)) : Value();
        context["dwmGpuMsPerS"] = a.dwmGpuMs && b.dwmGpuMs ? Value(Round((*b.dwmGpuMs - *a.dwmGpuMs) / dt)) : Value();
        if (a.systemTotalMs && b.systemTotalMs && a.systemIdleMs && b.systemIdleMs) {
            const double total = *b.systemTotalMs - *a.systemTotalMs, busy = total - (*b.systemIdleMs - *a.systemIdleMs);
            const double kiteMs = NumberAt(Value(out["totals"]), {"cpuMsPerS"}).value_or(0) * dt;
            const double otherPct = total > 0 ? std::max(0.0, busy - kiteMs) / total * 100 : 0;
            context["systemBusyPct"] = Round(total > 0 ? busy / total * 100 : 0, 1);
            context["otherCpuPct"] = Round(otherPct, 1);
            out["noisy"] = otherPct > 25;
        }
    }
    out["context"] = std::move(context);

    int started = 0, ended = 0;
    for (const JobEvent& e : processes_->Events()) {
        if (e.qpc < begin || e.qpc > end) continue;
        (e.started ? started : ended)++;
    }
    out["spawns"] = static_cast<double>(started);
    out["exits"] = static_cast<double>(ended);

    // The crossfade's frames: intervals between them within each crossfade, all from one clock
    // (presents if every frame has one, else the vblanks they were made for, else when Kite drew
    // them), and how many came later than one and a half periods.
    std::vector<const FrameRecord*> frames;
    for (const FrameRecord& f : log_->frames) {
        if (f.qpc >= begin && f.qpc <= end) frames.push_back(&f);
    }
    if (!frames.empty()) {
        const bool presents = std::all_of(frames.begin(), frames.end(), [](const FrameRecord* f) { return f->presentQpc != 0; });
        const bool targets = std::all_of(frames.begin(), frames.end(), [](const FrameRecord* f) { return f->targetQpc != 0; });
        const auto when = [&](const FrameRecord* f) { return presents ? f->presentQpc : targets ? f->targetQpc : f->qpc; };
        std::vector<double> intervals, rates;
        int missed = 0, fades = 1;
        for (size_t i = 0; i < frames.size(); ++i) {
            if (frames[i]->rate > 0) rates.push_back(frames[i]->rate);
            if (!i) continue;
            if (Ms(frames[i - 1]->qpc, frames[i]->qpc) > 100) {
                ++fades;
                continue;
            }
            const double interval = Ms(when(frames[i - 1]), when(frames[i]));
            intervals.push_back(interval);
            if (frames[i]->rate > 0 && interval > 1.5 * 1000 / frames[i]->rate) ++missed;
        }
        Object f;
        f["count"] = static_cast<double>(frames.size());
        f["crossfades"] = static_cast<double>(fades);
        f["intervalSource"] = presents ? "present" : targets ? "target" : "drawn";
        f["intervalP50Ms"] = RoundOrNull(Percentile(intervals, 50));
        f["intervalP99Ms"] = RoundOrNull(Percentile(intervals, 99));
        f["missed"] = static_cast<double>(missed);
        f["rateHz"] = RoundOrNull(Percentile(rates, 50), 1);
        out["frames"] = std::move(f);
    }
    // Input to present: posted moves (hover) and commands (switches), each to the frame its
    // first commit showed in; an input with no commit within 250 ms changed nothing.
    std::map<std::string, std::vector<const InputRecord*>> inputs;
    for (const InputRecord& r : log_->inputs) {
        if (r.inputQpc >= begin && r.inputQpc <= end) inputs[r.kind].push_back(&r);
    }
    if (!inputs.empty()) {
        Object latency;
        for (const auto& [kind, records] : inputs) {
            std::vector<double> present, commit;
            int committed = 0, presented = 0;
            for (const InputRecord* r : records) {
                if (!r->commitQpc) continue;
                ++committed;
                commit.push_back(Ms(r->inputQpc, r->commitQpc));
                // Presented, or else the vblank the compositor made that frame for.
                if (const int64_t shown = r->presentQpc ? r->presentQpc : r->targetQpc) {
                    present.push_back(Ms(r->inputQpc, shown));
                    presented += r->presentQpc ? 1 : 0;
                }
            }
            Object k;
            k["logged"] = static_cast<double>(records.size());
            k["committed"] = static_cast<double>(committed);
            k["uncommitted"] = static_cast<double>(records.size() - static_cast<size_t>(committed));
            k["timed"] = static_cast<double>(present.size());
            k["presentKnown"] = static_cast<double>(presented);
            k["toCommitP50Ms"] = RoundOrNull(Percentile(commit, 50));
            k["toPresentP50Ms"] = RoundOrNull(Percentile(present, 50));
            k["toPresentP99Ms"] = RoundOrNull(Percentile(present, 99));
            k["toPresentMaxMs"] = RoundOrNull(Percentile(present, 100));
            latency[kind] = std::move(k);
        }
        out["latency"] = std::move(latency);
    }
    if (phase.name == "idle") {
        // Drew at all, and whether the real pointer was ever over Kite (a hover the user made),
        // or Kite was in front, while it did.
        Object check;
        const double presents = phase.endMark.presents - phase.beginMark.presents;
        const double commits = phase.endMark.commits - phase.beginMark.commits;
        const bool pass = presents == 0 && commits == 0;
        check["presents"] = presents;
        check["commits"] = commits;
        check["surfaceDraws"] = draws;
        // The real pointer's moves over Kite's window, as Kite counted them; the 1 Hz samples
        // are context.
        const double moves = phase.endMark.pointerMoves - phase.beginMark.pointerMoves;
        check["realPointerMoves"] = moves;
        check["pointerOverKiteSamples"] = static_cast<double>(pointerOver);
        check["kiteInFrontSamples"] = static_cast<double>(inFront);
        check["pass"] = pass;
        check["drewByItself"] = !pass && moves == 0;
        out["assert"] = std::move(check);
    }
    for (const auto& [key, value] : phase.extra) out[key] = value;
    return out;
}

Value Run::Result() {
    Object out;
    Object startup;
    const auto at = [&](const char* name) -> std::optional<double> {
        const Mark* m = log_->Find(name);
        return m ? std::optional<double>(Ms(launchQpc_, m->qpc)) : std::nullopt;
    };
    startup["startedMs"] = RoundOrNull(at("started"), 1);
    startup["windowCreatedMs"] = RoundOrNull(at("window-created"), 1);
    startup["firstCommitMs"] = RoundOrNull(at("first-commit"), 1);
    startup["cefInitBeginMs"] = RoundOrNull(at("cef-init-begin"), 1);
    startup["cefInitEndMs"] = RoundOrNull(at("cef-init-end"), 1);
    const auto begin = at("cef-init-begin"), end = at("cef-init-end");
    startup["cefInitMs"] = begin && end ? Value(Round(*end - *begin, 1)) : Value();
    startup["shownMs"] = RoundOrNull(at("shown"), 1);
    startup["firstBrowserCreatedMs"] = RoundOrNull(at("browser-created"), 1);
    startup["firstLoadEndMs"] = RoundOrNull(at("load-end"), 1);
    out["startup"] = std::move(startup);
    Array phases;
    for (const Phase& p : phases_) phases.push_back(PhaseResult(p));
    out["phases"] = std::move(phases);
    out["frameStatistics"] = std::any_of(log_->inputs.begin(), log_->inputs.end(), [](const InputRecord& r) { return r.targetQpc != 0; }) ||
                             std::any_of(log_->frames.begin(), log_->frames.end(), [](const FrameRecord& f) { return f.targetQpc != 0; });
    out["gpuCounters"] = processes_->HasGpuCounters();
    Array switches;
    for (const std::string& s : log_->chromiumSwitches) switches.push_back(s);
    out["chromiumSwitches"] = std::move(switches);
    return out;
}

// MARK: The result's context

Object Machine() {
    Object m;
    wchar_t cpu[256] = L"";
    DWORD bytes = sizeof cpu;
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", L"ProcessorNameString", RRF_RT_REG_SZ,
                     nullptr, cpu, &bytes) == ERROR_SUCCESS) {
        std::wstring name = cpu;
        while (!name.empty() && name.back() == L' ') name.pop_back();
        m["cpu"] = Narrow(name);
    }
    m["logicalCpus"] = static_cast<double>(GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
    MEMORYSTATUSEX memory{sizeof memory};
    if (GlobalMemoryStatusEx(&memory)) m["memoryGB"] = Round(static_cast<double>(memory.ullTotalPhys) / (1ull << 30), 1);
    using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
    if (auto get = reinterpret_cast<RtlGetVersionFn>(reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion")))) {
        OSVERSIONINFOW v{sizeof v};
        if (get(&v) == 0) m["windowsBuild"] = static_cast<double>(v.dwBuildNumber);
    }
    Array displays;
    for (DWORD i = 0;; ++i) {
        DISPLAY_DEVICEW device{sizeof device};
        if (!EnumDisplayDevicesW(nullptr, i, &device, 0)) break;
        if (!(device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
        DEVMODEW mode{};
        mode.dmSize = sizeof mode;
        Object d;
        d["adapter"] = Narrow(device.DeviceString);
        d["primary"] = (device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
        if (EnumDisplaySettingsW(device.DeviceName, ENUM_CURRENT_SETTINGS, &mode)) {
            d["width"] = static_cast<double>(mode.dmPelsWidth);
            d["height"] = static_cast<double>(mode.dmPelsHeight);
            d["hz"] = static_cast<double>(mode.dmDisplayFrequency);
        }
        displays.push_back(std::move(d));
    }
    m["displays"] = std::move(displays);
    return m;
}

// The Kite.exe measured, and which fixture and pages it was measured with (a hash of their
// bytes, so two results say whether they ran the same assets).
Object Build(const std::filesystem::path& kite, const std::filesystem::path& assets) {
    Object b;
    b["exe"] = Utf8(kite);
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (GetFileAttributesExW(kite.c_str(), GetFileExInfoStandard, &data)) {
        b["bytes"] = static_cast<double>((static_cast<ULONGLONG>(data.nFileSizeHigh) << 32) | data.nFileSizeLow);
        SYSTEMTIME t{};
        FileTimeToSystemTime(&data.ftLastWriteTime, &t);
        char text[40];
        std::snprintf(text, sizeof text, "%04u-%02u-%02uT%02u:%02u:%02uZ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
        b["modified"] = std::string(text);
    }
    std::vector<std::filesystem::path> files;
    std::error_code ec;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(assets, ec)) {
        const auto ext = entry.path().extension();
        if (entry.is_regular_file() && (ext == L".html" || ext == L".json")) files.push_back(entry.path());
    }
    std::sort(files.begin(), files.end());
    uint64_t hash = 1469598103934665603ull;  // FNV-1a over each file's relative path and bytes
    for (const auto& file : files) {
        std::ifstream in(file, std::ios::binary);
        const std::string bytes = Utf8(file.lexically_relative(assets)) + std::string{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
        for (unsigned char c : bytes) hash = (hash ^ c) * 1099511628211ull;
    }
    char text[32];
    std::snprintf(text, sizeof text, "fnv1a64:%016llx", static_cast<unsigned long long>(hash));
    b["assets"] = std::string(text);
    return b;
}

int Usage(const std::string& problem) {
    Say(problem);
    Say("usage: kiteperf --kite PATH [--scenario standard|idle|startup|smoke] [--phases a,b,c] [--runs N] [--out FILE] "
        "[--label NAME] [--chromium-switches \"...\"] [--keep-profile]");
    Say("       kiteperf --compare before.json after.json");
    return 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    std::vector<std::wstring> args(argv + 1, argv + argc);
    if (!args.empty() && args[0] == L"--compare") {
        if (args.size() != 3) return Usage("--compare takes two result files");
        std::string error;
        auto before = ReadResult(args[1], error);
        auto after = before ? ReadResult(args[2], error) : std::nullopt;
        if (!after) return Usage(error);
        const auto label = [](const Value& v) {
            const Value* l = v.Find("label");
            return l && l->AsString() ? *l->AsString() : std::string("?");
        };
        Print("kiteperf: " + label(*before) + " → " + label(*after) + "\n\n" + Compare(*before, *after));
        return 0;
    }
    Options options;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::wstring& a = args[i];
        const auto value = [&]() -> std::optional<std::wstring> { return i + 1 < args.size() ? std::optional<std::wstring>(args[++i]) : std::nullopt; };
        if (a == L"--kite") {
            auto v = value();
            if (!v) return Usage("--kite takes Kite.exe's path");
            options.kite = std::filesystem::absolute(*v);
        } else if (a == L"--scenario") {
            auto v = value();
            options.scenario = v ? Narrow(*v) : "";
            if (options.scenario != "standard" && options.scenario != "idle" && options.scenario != "startup" && options.scenario != "smoke") {
                return Usage("--scenario takes standard, idle, startup or smoke");
            }
        } else if (a == L"--phases") {
            auto v = value();
            if (!v || v->empty()) return Usage("--phases takes a comma-separated list of phases");
            const std::string list = Narrow(*v);
            for (size_t start = 0; start <= list.size();) {
                const size_t comma = std::min(list.find(',', start), list.size());
                const std::string name = list.substr(start, comma - start);
                if (std::find_if(std::begin(kPhases), std::end(kPhases), [&](const char* p) { return name == p; }) == std::end(kPhases)) {
                    std::string known;
                    for (const char* p : kPhases) known += (known.empty() ? "" : ", ") + std::string(p);
                    return Usage("no phase " + name + " (the phases: " + known + ")");
                }
                options.phases.insert(name);
                start = comma + 1;
            }
        } else if (a == L"--runs") {
            auto v = value();
            options.runs = v ? _wtoi(v->c_str()) : 0;
            if (options.runs < 1 || options.runs > 20) return Usage("--runs takes 1 to 20");
        } else if (a == L"--out") {
            auto v = value();
            if (!v) return Usage("--out takes a file");
            options.out = *v;
        } else if (a == L"--label") {
            auto v = value();
            if (!v) return Usage("--label takes a name");
            options.label = Narrow(*v);
        } else if (a == L"--chromium-switches") {
            auto v = value();
            if (!v) return Usage("--chromium-switches takes Chromium's switches");
            options.switches = *v;
        } else if (a == L"--keep-profile") {
            options.keepProfile = true;
        } else {
            return Usage("unknown option " + Narrow(a));
        }
    }
    if (options.kite.empty()) return Usage("--kite is required");
    if (!std::filesystem::exists(options.kite)) return Usage("no Kite.exe at " + Utf8(options.kite));
    if (!options.phases.empty() && options.scenario != "standard") return Usage("--phases picks from the standard scenario's phases");
    // The same allow-list Kite.exe applies, before anything starts, with the reason.
    for (size_t start = 0; start < options.switches.size();) {
        if (options.switches[start] == L' ') {
            ++start;
            continue;
        }
        const size_t end = std::min(options.switches.find(L' ', start), options.switches.size());
        const std::string token = Narrow(options.switches.substr(start, end - start));
        start = end;
        if (!token.starts_with("--") || token.size() < 3) return Usage("--chromium-switches takes --name or --name=value, not " + token);
        const std::string entry = token.substr(2);
        const size_t equals = entry.find('=');
        const std::string name = entry.substr(0, equals), value = equals == std::string::npos ? "" : entry.substr(equals + 1);
        if (!kite::perf::AllowedChromiumSwitch(name, value)) {
            return Usage("--chromium-switches: " + token +
                         " isn't on Kite's allow-list (shell/PerfProtocol.h): only switches that measure Chromium without weakening "
                         "the sandbox, site isolation or web security, and only the listed features for --disable-features");
        }
    }
    if (options.label.empty()) options.label = options.scenario;
    if (options.out.empty()) options.out = Widen("kiteperf-" + options.label + ".json");
    options.assets = std::filesystem::path(std::u8string(reinterpret_cast<const char8_t*>(KITEPERF_ASSETS)));  // sessions/ and pages/

    std::wstring error;
    auto server = PageServer::Start(options.assets / L"pages", kHosts, kPort, error);
    if (!server) {
        Say(Narrow(error));
        return 2;
    }
    Array completed, all;
    int exitCode = 0;
    for (int i = 0; i < options.runs; ++i) {
        Run run(options, *server, i);
        std::wstring problem;
        bool kiteFailed = false;
        Value result = run.Go(problem, kiteFailed);
        if (!problem.empty()) {
            Say("run " + std::to_string(i + 1) + " failed: " + Narrow(problem));
            if (!kiteFailed) return 2;
            exitCode = 3;
        } else {
            completed.push_back(result);
        }
        if (result.IsObject()) all.push_back(std::move(result));
    }
    std::vector<const Value*> runs;
    for (const Value& r : completed) runs.push_back(&r);
    Value median = MedianOf(runs);
    Object out = median.AsObject() ? *median.AsObject() : Object{};
    out["schema"] = "kiteperf/1";
    out["label"] = options.label;
    out["scenario"] = options.scenario;
    Array requested;
    for (const char* p : kPhases) {
        if (options.phases.contains(p)) requested.push_back(p);
    }
    out["phasesRequested"] = std::move(requested);
    out["runs"] = static_cast<double>(completed.size());
    out["runsFailed"] = static_cast<double>(all.size() - completed.size());
    out["build"] = Build(options.kite, options.assets);
    out["machine"] = Machine();
    bool anyNoisy = false, idlePass = true, idleSeen = false, drewByItself = false;
    for (const Value& r : completed) {
        const Value* phases = r.Find("phases");
        for (const Value& p : Items(phases)) {
            if (const Value* n = p.Find("noisy"); n && n->AsBool().value_or(false)) anyNoisy = true;
            if (const Value* pass = Path(p, {"assert", "pass"})) {
                idleSeen = true;
                idlePass = idlePass && pass->AsBool().value_or(false);
            }
            if (const Value* self = Path(p, {"assert", "drewByItself"})) drewByItself = drewByItself || self->AsBool().value_or(false);
        }
    }
    out["noisy"] = anyNoisy;
    if (idleSeen) out["idleAssert"] = Object{{"pass", idlePass}, {"drewByItself", drewByItself}};
    out["allRuns"] = std::move(all);
    std::ofstream file(options.out, std::ios::binary | std::ios::trunc);
    file << Pretty(Value(out));
    if (!file) {
        Say("couldn't write " + Utf8(options.out));
        return 2;
    }
    if (completed.empty()) return 3;
    Print("kiteperf: " + options.label + ", " + options.scenario + ", medians of " + std::to_string(completed.size()) + " runs → " +
          Utf8(options.out) + "\n\n" + Tables(Value(out)));
    if (exitCode == 0 && drewByItself) exitCode = 4;
    return exitCode;
}
