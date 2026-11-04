// kiteperf: measures Kite for Windows (docs/windows.md, Measuring performance). Never linked into
// Kite.exe, never shipped (docs/windows-architecture.md, windows/tools).
//
//   kiteperf --kite PATH [--scenario standard|idle|startup|smoke] [--runs 3] [--out result.json]
//            [--label NAME] [--chromium-switches "..."] [--keep-profile]
//   kiteperf --compare before.json after.json      a markdown table of the two
//
// Each run launches Kite.exe on a fresh %TEMP% profile holding sessions/perf-10tabs-2spaces.json,
// with pages from its own loopback server (PageServer.h), suspended into a job object, then
// drives it through --perf-control and reads --perf-log (shell/PerfLog.h) while sampling every
// process of Kite's once a second (Processes.h). Nothing here sends real input, moves the
// pointer or takes the focus: Kite opens behind other windows, its pointer moves are posted to
// it, and the cover is a window that never activates, just over Kite in the z-order.
//
// The result (schema kiteperf/1) holds the median of the runs, and every run in allRuns. Exit
// codes: 0 done, 1 usage, 2 setup failed, 3 Kite failed, 4 the idle phase drew (presents or
// commits above zero).

#include <windows.h>

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

#include "PageServer.h"
#include "Processes.h"
#include "core/Json.h"

namespace {

using kite::json::Array;
using kite::json::Object;
using kite::json::Value;
using namespace kiteperf;

constexpr uint16_t kPort = 18765;
// p1–p10 on 127.0.0.1–10 (the session's ten tabs), title-tick on .11 and anim on .12: each its own site.
constexpr int kHosts = 12;
constexpr ULONG_PTR kPerfControlTag = 0x4B505246;  // 'KPRF', BrowserWindowController::kPerfControlTag
const char* const kTitleTickURL = "http://127.0.0.11:18765/title-tick.html";
const char* const kAnimURL = "http://127.0.0.12:18765/anim.html";

std::string FixtureTab(const char* name) { return std::string("5EED0000-0000-4000-8000-0000000000") + name; }

std::string Narrow(const std::wstring& text) {
    if (text.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring Widen(const std::string& text) {
    if (text.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n);
    return out;
}

void Print(const std::string& text) {
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
}
void Say(const std::string& text) {
    DWORD written = 0;
    const std::string line = "kiteperf: " + text + "\n";
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

double Round(double value, int digits = 2) {
    const double scale = std::pow(10.0, digits);
    return std::round(value * scale) / scale;
}
Value RoundOrNull(std::optional<double> value, int digits = 2) { return value ? Value(Round(*value, digits)) : Value(); }

double Ms(int64_t from, int64_t to) { return static_cast<double>(to - from) * 1000.0 / QpcFrequency(); }

std::optional<double> Percentile(std::vector<double> values, double p) {
    if (values.empty()) return std::nullopt;
    std::sort(values.begin(), values.end());
    const double rank = p / 100.0 * static_cast<double>(values.size() - 1);
    const size_t low = static_cast<size_t>(std::floor(rank)), high = static_cast<size_t>(std::ceil(rank));
    return values[low] + (values[high] - values[low]) * (rank - static_cast<double>(low));
}

const Value* Path(const Value& v, std::initializer_list<const char*> keys) {
    const Value* at = &v;
    for (const char* key : keys) {
        if (!at || !(at = at->Find(key))) return nullptr;
    }
    return at;
}
std::optional<double> NumberAt(const Value& v, std::initializer_list<const char*> keys) {
    const Value* at = Path(v, keys);
    return at ? at->AsNumber() : std::nullopt;
}

// MARK: JSON out

void Pretty(const Value& v, std::string& out, int indent) {
    const std::string pad(static_cast<size_t>(indent + 2), ' '), close(static_cast<size_t>(indent), ' ');
    if (const Object* o = v.AsObject(); o && !o->empty()) {
        out += "{\n";
        size_t i = 0;
        for (const auto& [key, member] : *o) {
            out += pad + kite::json::Write(Value(key)) + ": ";
            Pretty(member, out, indent + 2);
            out += ++i < o->size() ? ",\n" : "\n";
        }
        out += close + "}";
    } else if (const Array* a = v.AsArray(); a && !a->empty()) {
        // Arrays of numbers stay on one line.
        if (std::all_of(a->begin(), a->end(), [](const Value& e) { return e.IsNumber() || e.IsNull(); })) {
            out += kite::json::Write(v);
            return;
        }
        out += "[\n";
        for (size_t i = 0; i < a->size(); ++i) {
            out += pad;
            Pretty((*a)[i], out, indent + 2);
            out += i + 1 < a->size() ? ",\n" : "\n";
        }
        out += close + "]";
    } else {
        out += kite::json::Write(v);
    }
}

// MARK: Kite's perf log

struct Mark {
    std::string name, detail;
    int64_t qpc = 0;
    double presents = 0, commits = 0;
    std::map<std::string, double> draws;
};
struct InputRecord {
    std::string kind;
    int64_t inputQpc = 0, commitQpc = 0, presentQpc = 0, targetQpc = 0;
};
struct FrameRecord {
    int64_t qpc = 0, presentQpc = 0, targetQpc = 0;
    double rate = 0;
};
struct DispatchRecord {
    int64_t qpc = 0;
    double ms = 0;
    unsigned message = 0;
};

class LogReader {
public:
    explicit LogReader(std::filesystem::path path) : path_(std::move(path)) {}
    ~LogReader() {
        if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
    }
    // Reads what Kite has written since the last call.
    void Pump() {
        if (file_ == INVALID_HANDLE_VALUE) {
            file_ = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file_ == INVALID_HANDLE_VALUE) return;
        }
        char buffer[65536];
        DWORD got = 0;
        while (ReadFile(file_, buffer, sizeof buffer, &got, nullptr) && got > 0) partial_.append(buffer, got);
        for (size_t end; (end = partial_.find('\n')) != std::string::npos;) {
            Parse(partial_.substr(0, end));
            partial_.erase(0, end + 1);
        }
    }
    const Mark* Find(const std::string& name, int64_t after = 0, const std::string* detail = nullptr) const {
        for (const Mark& m : marks) {
            if (m.name == name && m.qpc >= after && (!detail || m.detail == *detail)) return &m;
        }
        return nullptr;
    }
    std::vector<Mark> marks;
    std::vector<InputRecord> inputs;
    std::vector<FrameRecord> frames;
    std::vector<DispatchRecord> dispatches;
    bool frameStatistics = false;

private:
    void Parse(const std::string& line) {
        auto parsed = kite::json::Parse(line);
        const Value* v = std::get_if<Value>(&parsed);
        if (!v) return;
        const auto text = [&](const char* key) {
            const Value* at = v->Find(key);
            const std::string* s = at ? at->AsString() : nullptr;
            return s ? *s : std::string();
        };
        const auto integer = [&](const char* key) -> int64_t {
            const Value* at = v->Find(key);
            return at && at->AsNumber() ? static_cast<int64_t>(*at->AsNumber()) : 0;
        };
        const auto number = [&](const char* key) {
            const Value* at = v->Find(key);
            return at && at->AsNumber() ? *at->AsNumber() : 0.0;
        };
        const std::string type = text("type");
        if (type == "header") {
            const Value* at = v->Find("frameStatistics");
            frameStatistics = at && at->AsBool().value_or(false);
        } else if (type == "mark") {
            Mark m{text("name"), text("detail"), integer("qpc"), number("presents"), number("commits"), {}};
            if (const Value* draws = v->Find("surfaceDraws"); draws && draws->AsObject()) {
                for (const auto& [key, count] : *draws->AsObject()) m.draws[key] = count.AsNumber().value_or(0);
            }
            marks.push_back(std::move(m));
        } else if (type == "input") {
            inputs.push_back({text("kind"), integer("inputQpc"), integer("commitQpc"), integer("presentQpc"), integer("targetQpc")});
        } else if (type == "frame") {
            frames.push_back({integer("qpc"), integer("presentQpc"), integer("targetQpc"), number("rate")});
        } else if (type == "dispatch") {
            dispatches.push_back({integer("qpc"), number("ms"), static_cast<unsigned>(integer("msg"))});
        }
    }
    std::filesystem::path path_;
    HANDLE file_ = INVALID_HANDLE_VALUE;
    std::string partial_;
};

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
    std::wstring kite;
    std::string scenario = "standard";
    int runs = 3;
    std::wstring out;
    std::string label;
    std::wstring switches;
    bool keepProfile = false;
    std::filesystem::path assets;
};

struct Phase {
    std::string name;
    int64_t begin = 0, end = 0;
    Mark beginMark, endMark;
    Object extra;
};

class Run {
public:
    Run(const Options& options, PageServer& server, int index) : options_(options), server_(server), index_(index) {}

    // Empty on success; `kiteFailed` says whether it was Kite (exit 3) rather than setup (2).
    std::wstring Go(Value& result, bool& kiteFailed);

private:
    std::wstring Launch();
    bool Send(const std::string& json) {
        COPYDATASTRUCT data{kPerfControlTag, static_cast<DWORD>(json.size()), const_cast<char*>(json.data())};
        DWORD_PTR answer = 0;
        if (!SendMessageTimeoutW(kite_, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_NORMAL, 5000, &answer)) return false;
        return answer == 1;
    }
    bool Command(const std::string& id) {
        ++commands_;
        return Send("{\"command\":\"" + id + "\",\"qpc\":" + std::to_string(Qpc()) + "}");
    }
    // Waits, pumping the cover's messages and reading the log, until `done` or `seconds`.
    bool WaitFor(double seconds, const std::function<bool()>& done = nullptr) {
        const int64_t until = Qpc() + static_cast<int64_t>(seconds * QpcFrequency());
        for (;;) {
            log_->Pump();
            if (done && done()) return true;
            const int64_t now = Qpc();
            if (now >= until) return false;
            const DWORD wait = static_cast<DWORD>(std::min<double>(Ms(now, until), done ? 20.0 : 50.0));
            MsgWaitForMultipleObjects(0, nullptr, FALSE, std::max<DWORD>(wait, 1), QS_ALLINPUT);
            MSG message;
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
        }
    }
    // A tab's page loaded after `after` (3 s at most); a tab already loaded this run isn't waited for.
    void WaitLoad(const std::string& tab, int64_t after, std::vector<double>* loadMs) {
        if (loaded_.contains(tab)) {
            WaitFor(0.3);
            return;
        }
        const Mark* end = nullptr;
        WaitFor(3.0, [&] { return (end = log_->Find("load-end", after, &tab)) != nullptr; });
        if (end && loadMs) loadMs->push_back(Ms(after, end->qpc));
        loaded_.insert(tab);
    }
    // Any page's load after `after` (a tab Kite just made).
    void WaitAnyLoad(int64_t after) {
        WaitFor(3.0, [&] { return log_->Find("load-end", after) != nullptr; });
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
    int commands_ = 0;
    // Sampling, once a second on its own thread.
    std::thread sampler_;
    std::mutex snapshotsMutex_;
    std::vector<Snapshot> snapshots_;
    bool stopSampling_ = false;
    std::condition_variable_any sampleWake_;
    uint64_t faviconsBefore_ = 0, requestsBefore_ = 0;
    bool kiteTookFocus_ = false;  // Kite's window or the cover was the foreground window
    std::string failure_;
};

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

    std::wstring command = L"\"" + options_.kite + L"\" --perf-log \"" + (profile_ / L"perf.jsonl").wstring() + L"\" --perf-control";
    if (!options_.switches.empty()) command += L" --chromium-switches \"" + options_.switches + L"\"";
    // Kite's stderr (why it failed, if it does) into the profile.
    SECURITY_ATTRIBUTES inherit{sizeof inherit, nullptr, TRUE};
    HANDLE output = CreateFileW((profile_ / L"kite-output.txt").c_str(), GENERIC_WRITE, FILE_SHARE_READ, &inherit, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    STARTUPINFOW startup{sizeof startup};
    startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    startup.wShowWindow = SW_SHOWNOACTIVATE;
    startup.hStdOutput = startup.hStdError = output;
    startup.hStdInput = nullptr;
    const std::wstring directory = std::filesystem::path(options_.kite).parent_path().wstring();
    launchQpc_ = Qpc();
    const BOOL started = CreateProcessW(options_.kite.c_str(), command.data(), nullptr, nullptr, TRUE,
                                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, environment.data(), directory.c_str(), &startup,
                                        &kiteProcess_);
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    if (!started) return L"couldn't start " + options_.kite + L" (" + std::to_wstring(GetLastError()) + L")";
    if (!AssignProcessToJobObject(processes_->Job(), kiteProcess_.hProcess)) {
        TerminateProcess(kiteProcess_.hProcess, 1);
        return L"couldn't put Kite in the job (" + std::to_wstring(GetLastError()) + L")";
    }
    processes_->SetRoot(kiteProcess_.dwProcessId, std::filesystem::path(options_.kite).filename().wstring());
    ResumeThread(kiteProcess_.hThread);
    faviconsBefore_ = server_.FaviconHits();
    requestsBefore_ = server_.Requests();
    sampler_ = std::thread([this] {
        std::unique_lock lock(snapshotsMutex_);
        while (!stopSampling_) {
            lock.unlock();
            Snapshot s = processes_->Take();
            lock.lock();
            snapshots_.push_back(std::move(s));
            sampleWake_.wait_for(lock, std::chrono::milliseconds(1000), [this] { return stopSampling_; });
        }
    });
    return {};
}

void Run::RunPhase(const std::string& name, const std::function<void(Phase&)>& body) {
    if (!failure_.empty()) return;
    Say("run " + std::to_string(index_ + 1) + ": " + name);
    Phase phase;
    phase.name = name;
    const auto markNow = [&](const std::string& mark, Mark& into, int64_t& at) {
        const int64_t sent = Qpc();
        if (!Send("{\"mark\":\"" + mark + "\"}")) {
            failure_ = "Kite didn't take the mark " + mark;
            return false;
        }
        const Mark* m = nullptr;
        WaitFor(5, [&] { return (m = log_->Find(mark, sent)) != nullptr; });
        if (!m) {
            failure_ = "the mark " + mark + " never reached the log";
            return false;
        }
        into = *m;
        at = m->qpc;
        return true;
    };
    if (!markNow("phase-begin:" + name, phase.beginMark, phase.begin)) return;
    body(phase);
    if (!markNow("phase-end:" + name, phase.endMark, phase.end)) return;
    // A run must never take the focus from whoever is using the machine.
    DWORD foreground = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &foreground);
    if (foreground == kiteProcess_.dwProcessId) kiteTookFocus_ = true;
    phases_.push_back(std::move(phase));
}

void Run::Scenario() {
    const std::string& scenario = options_.scenario;
    const bool smoke = scenario == "smoke";
    if (scenario == "startup") return;
    RunPhase("open", [&](Phase& phase) {
        std::vector<double> loads;
        for (int n = 1; n <= (smoke ? 2 : 8); ++n) {
            const int64_t at = Qpc();
            Command("tab" + std::to_string(n));
            WaitLoad(FixtureTab(("A" + std::to_string(n)).c_str()), at, &loads);
        }
        if (!smoke) {
            int64_t at = Qpc();
            Command("nextSpace");
            WaitLoad(FixtureTab("B1"), at, &loads);
            at = Qpc();
            Command("tab1");
            WaitLoad(FixtureTab("B1"), at, &loads);
            at = Qpc();
            Command("tab2");
            WaitLoad(FixtureTab("B2"), at, &loads);
            Command("previousSpace");
            WaitFor(1);
        }
        phase.extra["loads"] = static_cast<double>(loads.size());
        phase.extra["loadP50Ms"] = RoundOrNull(Percentile(loads, 50), 1);
        phase.extra["loadMaxMs"] = RoundOrNull(loads.empty() ? std::nullopt : std::optional<double>(*std::max_element(loads.begin(), loads.end())), 1);
    });
    RunPhase("settle", [&](Phase&) { WaitFor(smoke ? 3 : 30); });
    RunPhase("idle", [&](Phase&) { WaitFor(smoke ? 5 : 60); });
    if (scenario == "idle") return;
    // Next and Previous Space every 0.5 s: the pages' slide and the theme's crossfade.
    RunPhase("switchSpaces", [&](Phase&) {
        const int switches = smoke ? 4 : 40;
        for (int i = 0; i < switches; ++i) {
            Command(i % 2 ? "previousSpace" : "nextSpace");
            WaitFor(0.5);
        }
    });
    if (!smoke) {
        RunPhase("switchTabs", [&](Phase&) {
            for (int i = 0; i < 20; ++i) {
                Command(i % 2 ? "tab1" : "tab2");
                WaitFor(0.5);
            }
        });
        RunPhase("reload", [&](Phase&) {
            for (int i = 0; i < 20; ++i) {
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
        const int64_t start = Qpc();
        int moves = 0;
        for (int i = 0;; ++i) {
            const double t = i / 120.0;
            if (t >= seconds) break;
            // The rows from the first tab (105pt) to the eighth: down and back every 2 s.
            const double phaseOf = std::fmod(t, 2.0) / 2.0;
            const double y = 110 + 320 * (phaseOf < 0.5 ? phaseOf * 2 : 2 - phaseOf * 2);
            Send("{\"input\":\"move\",\"x\":" + std::to_string(static_cast<int>(120 * scale)) +
                 ",\"y\":" + std::to_string(static_cast<int>(y * scale)) + ",\"qpc\":" + std::to_string(Qpc()) + "}");
            ++moves;
            const int64_t next = start + static_cast<int64_t>((i + 1) / 120.0 * QpcFrequency());
            const double waitMs = Ms(Qpc(), next);
            if (waitMs > 0) {
                LARGE_INTEGER due{};
                due.QuadPart = -static_cast<LONGLONG>(waitMs * 1e4);
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 100);
                else Sleep(static_cast<DWORD>(waitMs));
            }
            log_->Pump();
        }
        if (timer) CloseHandle(timer);
        Send("{\"input\":\"leave\"}");
        WaitFor(0.5);
        phase.extra["moves"] = static_cast<double>(moves);
    });
    if (smoke) return;
    // A page whose title changes every second: the sidebar's row, nothing else.
    RunPhase("titleTick", [&](Phase&) {
        const int64_t at = Qpc();
        Send(std::string("{\"open\":\"") + kTitleTickURL + "\"}");
        WaitAnyLoad(at);
        WaitFor(20);
    });
    Command("archiveTab");
    WaitFor(1);
    const int64_t animAt = Qpc();
    Send(std::string("{\"open\":\"") + kAnimURL + "\"}");  // tab 1 now
    WaitAnyLoad(animAt);
    RunPhase("anim", [&](Phase&) { WaitFor(10); });
    Command("tab2");
    RunPhase("hiddenAnim", [&](Phase&) { WaitFor(20); });
    Command("tab1");
    WaitFor(1);
    RunPhase("covered", [&](Phase& phase) {
        HWND cover = MakeCover(kite_);
        phase.extra["coverMade"] = cover != nullptr;
        WaitFor(20);
        if (GetForegroundWindow() == cover && cover) kiteTookFocus_ = true;
        if (cover) DestroyWindow(cover);
    });
    WaitFor(1);
    RunPhase("minimized", [&](Phase&) {
        ShowWindow(kite_, SW_SHOWMINNOACTIVE);
        WaitFor(20);
    });
}

std::wstring Run::Go(Value& result, bool& kiteFailed) {
    kiteFailed = false;
    if (std::wstring error = Launch(); !error.empty()) return error;
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
                DWORD pid = 0;
                GetWindowThreadProcessId(hwnd, &pid);
                wchar_t name[64];
                if (pid == s->pid && GetClassNameW(hwnd, name, 64) && std::wcscmp(name, L"KiteBrowserWindow") == 0) {
                    s->found = hwnd;
                    return FALSE;
                }
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&search));
        kite_ = search.found;
    }
    if (!kite_) {
        stop();
        kiteFailed = true;
        std::ifstream in(profile_ / L"kite-output.txt");
        const std::string said{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
        return L"Kite's window never showed" + (said.empty() ? std::wstring() : L": " + Widen(said));
    }
    // The first page (the session's selected tab).
    const std::string first = FixtureTab("A1");
    WaitFor(30, [&] { return log_->Find("load-end", 0, &first) != nullptr; });
    loaded_.insert(first);
    WaitFor(2);

    Scenario();

    // Shutdown: one WM_CLOSE, then every process gone (30 s at most, then the job is ended).
    closeQpc_ = Qpc();
    PostMessageW(kite_, WM_CLOSE, 0, 0);
    WaitFor(30, [&] { return processes_->EmptyAt() != 0; });
    const bool closed = processes_->EmptyAt() != 0;
    if (!closed) TerminateJobObject(processes_->Job(), 1);
    WaitFor(0.5);
    stop();
    result = Result();
    Object& out = *result.AsObject();
    Object shutdown;
    const Mark* loopEnd = log_->Find("loop-end", closeQpc_);
    const Mark* exited = log_->Find("exit", closeQpc_);
    shutdown["closed"] = closed;
    shutdown["windowClosedMs"] = loopEnd ? Value(Round(Ms(closeQpc_, loopEnd->qpc), 1)) : Value();
    shutdown["browserExitMs"] = exited ? Value(Round(Ms(closeQpc_, exited->qpc), 1)) : Value();
    shutdown["allExitedMs"] = closed ? Value(Round(Ms(closeQpc_, processes_->EmptyAt()), 1)) : Value();
    DWORD code = 0;
    GetExitCodeProcess(kiteProcess_.hProcess, &code);
    shutdown["exitCode"] = static_cast<double>(code);
    out["shutdown"] = std::move(shutdown);
    out["faviconHits"] = static_cast<double>(server_.FaviconHits() - faviconsBefore_);
    out["requests"] = static_cast<double>(server_.Requests() - requestsBefore_);
    out["tookFocus"] = kiteTookFocus_;
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
        out["profile"] = Narrow(profile_.wstring());
    }
    if (!failure_.empty()) {
        kiteFailed = true;
        return Widen(failure_);
    }
    return {};
}

// What the processes used over [phase.begin, phase.end]: rates between consecutive samples,
// sizes as the median of the samples.
Object Run::PhaseResult(const Phase& phase) const {
    Object out;
    out["name"] = phase.name;
    out["seconds"] = Round(Ms(phase.begin, phase.end) / 1000, 1);
    // Rates run from the last sample before the phase to the first after it (so a phase shorter
    // than the 1 s sampling still has one); sizes are the samples inside it (or that first after).
    std::vector<const Snapshot*> window, inside;
    const Snapshot *baseline = nullptr, *after = nullptr;
    for (const Snapshot& s : snapshots_) {
        if (s.qpc < phase.begin) baseline = &s;
        else if (s.qpc <= phase.end) inside.push_back(&s);
        else if (!after) after = &s;
    }
    if (baseline) window.push_back(baseline);
    window.insert(window.end(), inside.begin(), inside.end());
    if (after) window.push_back(after);
    if (inside.empty() && after) inside.push_back(after);
    const bool gpu = processes_->HasGpuCounters();
    out["samples"] = static_cast<double>(inside.size());

    // Kite's own counters, from the phase's two marks.
    Object kite;
    kite["presents"] = phase.endMark.presents - phase.beginMark.presents;
    kite["commits"] = phase.endMark.commits - phase.beginMark.commits;
    Object draws;
    for (const auto& [view, count] : phase.endMark.draws) {
        draws[view] = count - (phase.beginMark.draws.contains(view) ? phase.beginMark.draws.at(view) : 0);
    }
    kite["surfaceDraws"] = std::move(draws);
    double longest = 0;
    int longOnes = 0;
    for (const DispatchRecord& d : log_->dispatches) {
        if (d.qpc < phase.begin || d.qpc > phase.end) continue;
        ++longOnes;
        longest = std::max(longest, d.ms);
    }
    kite["longDispatches"] = static_cast<double>(longOnes);
    kite["maxDispatchMs"] = Round(longest, 1);
    out["kite"] = std::move(kite);

    using Filter = std::function<bool(const ProcessSample&)>;
    const auto metrics = [&](const Filter& include) {
        Object m;
        double dt = 0, cpu = 0, io = 0, ops = 0, switches = 0, gpuMs = 0;
        for (size_t k = 1; k < window.size(); ++k) {
            const Snapshot& a = *window[k - 1];
            const Snapshot& b = *window[k];
            dt += Ms(a.qpc, b.qpc) / 1000;
            for (const ProcessSample& p : b.processes) {
                if (!include(p)) continue;
                auto before = std::find_if(a.processes.begin(), a.processes.end(), [&](const ProcessSample& q) { return q.pid == p.pid; });
                if (before == a.processes.end()) continue;
                cpu += std::max(0.0, p.cpuMs - before->cpuMs);
                io += std::max(0.0, p.ioWriteBytes - before->ioWriteBytes);
                ops += std::max(0.0, p.ioWriteOps - before->ioWriteOps);
                switches += std::max(0.0, p.contextSwitches - before->contextSwitches);
                if (p.gpuRunningMs && before->gpuRunningMs) gpuMs += std::max(0.0, *p.gpuRunningMs - *before->gpuRunningMs);
            }
        }
        std::vector<double> privateWs, commit, dedicated, shared, handles, threads, count;
        for (const Snapshot* sample : inside) {
            double w = 0, c = 0, d = 0, s = 0, h = 0, t = 0, n = 0;
            for (const ProcessSample& p : sample->processes) {
                if (!include(p)) continue;
                w += p.privateWsBytes;
                c += p.commitBytes;
                d += p.gpuDedicatedBytes.value_or(0);
                s += p.gpuSharedBytes.value_or(0);
                h += p.handles;
                t += p.threads;
                ++n;
            }
            privateWs.push_back(w / 1048576);
            commit.push_back(c / 1048576);
            dedicated.push_back(d / 1048576);
            shared.push_back(s / 1048576);
            handles.push_back(h);
            threads.push_back(t);
            count.push_back(n);
        }
        const auto rate = [&](double total) { return dt > 0 ? Value(Round(total / dt)) : Value(); };
        m["cpuMsPerS"] = rate(cpu);
        m["ioWriteKBPerS"] = dt > 0 ? Value(Round(io / 1024 / dt)) : Value();
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
    Object byType;
    std::set<std::string> types;
    for (const Snapshot* s : window) {
        for (const ProcessSample& p : s->processes) types.insert(p.type);
    }
    for (const std::string& type : types) byType[type] = metrics([&](const ProcessSample& p) { return p.type == type; });
    out["byType"] = std::move(byType);
    Array processes;
    if (!inside.empty()) {
        for (const ProcessSample& p : inside.back()->processes) {
            Object one = metrics([&](const ProcessSample& q) { return q.pid == p.pid; });
            one.erase("processCount");
            one["pid"] = static_cast<double>(p.pid);
            one["type"] = p.type;
            if (!p.subtype.empty()) one["subtype"] = p.subtype;
            processes.push_back(std::move(one));
        }
    }
    out["processes"] = std::move(processes);

    // The machine around Kite: dwm.exe, and how busy everything else kept the CPUs.
    Object context;
    if (window.size() > 1) {
        const Snapshot& a = *window.front();
        const Snapshot& b = *window.back();
        const double dt = Ms(a.qpc, b.qpc) / 1000;
        const double total = b.systemTotalMs - a.systemTotalMs, busy = total - (b.systemIdleMs - a.systemIdleMs);
        const double kiteMs = NumberAt(Value(out["totals"]), {"cpuMsPerS"}).value_or(0) * dt;
        const double busyPct = total > 0 ? busy / total * 100 : 0;
        const double otherPct = total > 0 ? std::max(0.0, busy - kiteMs) / total * 100 : 0;
        context["dwmCpuMsPerS"] = Round((b.dwmCpuMs - a.dwmCpuMs) / dt);
        context["dwmGpuMsPerS"] = a.dwmGpuMs && b.dwmGpuMs ? Value(Round((*b.dwmGpuMs - *a.dwmGpuMs) / dt)) : Value();
        context["systemBusyPct"] = Round(busyPct, 1);
        context["otherCpuPct"] = Round(otherPct, 1);
        out["noisy"] = otherPct > 25;
    } else {
        out["noisy"] = false;
    }
    out["context"] = std::move(context);

    int started = 0, ended = 0;
    for (const JobEvent& e : processes_->Events()) {
        if (e.qpc < phase.begin || e.qpc > phase.end) continue;
        (e.started ? started : ended)++;
    }
    out["spawns"] = static_cast<double>(started);
    out["exits"] = static_cast<double>(ended);

    // The crossfade's frames: intervals between presents (or the times they were drawn for)
    // within each crossfade, and frames later than one and a half periods.
    std::vector<const FrameRecord*> frames;
    for (const FrameRecord& f : log_->frames) {
        if (f.qpc >= phase.begin && f.qpc <= phase.end) frames.push_back(&f);
    }
    if (!frames.empty()) {
        std::vector<double> intervals, rates;
        int missed = 0, fades = 1, presented = 0;
        for (size_t i = 0; i < frames.size(); ++i) {
            if (frames[i]->rate > 0) rates.push_back(frames[i]->rate);
            if (frames[i]->presentQpc) ++presented;
            if (!i) continue;
            if (Ms(frames[i - 1]->qpc, frames[i]->qpc) > 100) {
                ++fades;
                continue;
            }
            const auto when = [](const FrameRecord* f) { return f->presentQpc ? f->presentQpc : f->targetQpc ? f->targetQpc : f->qpc; };
            const double interval = Ms(when(frames[i - 1]), when(frames[i]));
            intervals.push_back(interval);
            if (frames[i]->rate > 0 && interval > 1.5 * 1000 / frames[i]->rate) ++missed;
        }
        Object f;
        f["count"] = static_cast<double>(frames.size());
        f["presented"] = static_cast<double>(presented);
        f["crossfades"] = static_cast<double>(fades);
        f["intervalP50Ms"] = RoundOrNull(Percentile(intervals, 50));
        f["intervalP99Ms"] = RoundOrNull(Percentile(intervals, 99));
        f["missed"] = static_cast<double>(missed);
        f["rateHz"] = RoundOrNull(Percentile(rates, 50), 1);
        out["frames"] = std::move(f);
    }
    // Input to present: posted moves (hover) and commands (switches), each to the frame its
    // first commit showed in.
    std::map<std::string, std::vector<const InputRecord*>> inputs;
    for (const InputRecord& r : log_->inputs) {
        if (r.inputQpc >= phase.begin && r.inputQpc <= phase.end) inputs[r.kind].push_back(&r);
    }
    if (!inputs.empty()) {
        Object latency;
        for (const auto& [kind, records] : inputs) {
            std::vector<double> present, commit;
            for (const InputRecord* r : records) {
                commit.push_back(Ms(r->inputQpc, r->commitQpc));
                // Presented, or else the vblank the compositor made that frame for.
                if (const int64_t shown = r->presentQpc ? r->presentQpc : r->targetQpc) present.push_back(Ms(r->inputQpc, shown));
            }
            Object k;
            k["count"] = static_cast<double>(records.size());
            k["toCommitP50Ms"] = RoundOrNull(Percentile(commit, 50));
            k["toPresentP50Ms"] = RoundOrNull(Percentile(present, 50));
            k["toPresentP99Ms"] = RoundOrNull(Percentile(present, 99));
            k["toPresentMaxMs"] = RoundOrNull(Percentile(present, 100));
            latency[kind] = std::move(k);
        }
        out["latency"] = std::move(latency);
    }
    if (phase.name == "idle") {
        Object check;
        const double presents = phase.endMark.presents - phase.beginMark.presents;
        const double commits = phase.endMark.commits - phase.beginMark.commits;
        check["presents"] = presents;
        check["commits"] = commits;
        check["pass"] = presents == 0 && commits == 0;
        out["assert"] = std::move(check);
    }
    for (const auto& [key, value] : phase.extra) out[key] = value;
    return out;
}

Value Run::Result() {
    Object out;
    Object startup;
    const auto since = [&](const char* name) -> Value {
        const Mark* m = log_->Find(name);
        return m ? Value(Round(Ms(launchQpc_, m->qpc), 1)) : Value();
    };
    startup["startedMs"] = since("started");
    startup["windowCreatedMs"] = since("window-created");
    startup["firstCommitMs"] = since("first-commit");
    startup["cefInitBeginMs"] = since("cef-init-begin");
    startup["cefInitEndMs"] = since("cef-init-end");
    startup["shownMs"] = since("shown");
    startup["firstBrowserCreatedMs"] = since("browser-created");
    startup["firstLoadEndMs"] = since("load-end");
    out["startup"] = std::move(startup);
    Array phases;
    for (const Phase& p : phases_) phases.push_back(PhaseResult(p));
    out["phases"] = std::move(phases);
    out["frameStatistics"] = log_->frameStatistics;
    out["gpuCounters"] = processes_->HasGpuCounters();
    return out;
}

// MARK: Medians

// The median of each number across runs, path by path; arrays of named objects (the phases)
// are matched by name; per-process lists stay in allRuns only. Booleans are the majority's,
// except an assertion's pass, which needs every run.
Value MedianOf(const std::vector<const Value*>& values, const std::string& key = {}) {
    std::vector<const Value*> present;
    for (const Value* v : values) {
        if (v && !v->IsNull()) present.push_back(v);
    }
    if (present.empty()) return {};
    const Value& first = *present.front();
    if (first.IsNumber()) {
        std::vector<double> numbers;
        for (const Value* v : present) {
            if (auto n = v->AsNumber()) numbers.push_back(*n);
        }
        return Round(*Percentile(numbers, 50), 2);
    }
    if (first.IsBool()) {
        size_t yes = 0;
        for (const Value* v : present) yes += v->AsBool().value_or(false) ? 1 : 0;
        if (key == "pass") return yes == values.size();
        return yes * 2 > present.size();
    }
    if (first.IsObject()) {
        Object out;
        for (const auto& [name, member] : *first.AsObject()) {
            if (name == "processes") continue;
            std::vector<const Value*> members;
            for (const Value* v : present) members.push_back(v->Find(name));
            out[name] = MedianOf(members, name);
        }
        return out;
    }
    if (const Array* a = first.AsArray()) {
        Array out;
        for (const Value& element : *a) {
            const Value* name = element.Find("name");
            if (!name || !name->AsString()) return first;
            std::vector<const Value*> matches;
            for (const Value* v : present) {
                for (const Value& e : *v->AsArray()) {
                    const Value* n = e.Find("name");
                    if (n && *n == *name) matches.push_back(&e);
                }
            }
            out.push_back(MedianOf(matches));
        }
        return out;
    }
    return first;
}

// MARK: Tables

std::string Cell(std::optional<double> v, int digits = 1) {
    if (!v) return "–";
    char text[32];
    std::snprintf(text, sizeof text, "%.*f", digits, *v);
    return text;
}

std::string CompareCell(std::optional<double> before, std::optional<double> after, int digits = 1) {
    if (!before && !after) return "–";
    std::string cell = Cell(before, digits) + " → " + Cell(after, digits);
    if (before && after && *before != 0) {
        char delta[32];
        std::snprintf(delta, sizeof delta, " (%+.0f%%)", (*after - *before) / *before * 100);
        cell += delta;
    }
    return cell;
}

const Value* PhaseNamed(const Value& result, const std::string& name) {
    const Value* phases = result.Find("phases");
    if (!phases || !phases->AsArray()) return nullptr;
    for (const Value& p : *phases->AsArray()) {
        const Value* n = p.Find("name");
        if (n && n->AsString() && *n->AsString() == name) return &p;
    }
    return nullptr;
}

std::optional<double> GpuMB(const Value& phase, const char* group = "totals", const char* type = nullptr) {
    const auto d = type ? NumberAt(phase, {group, type, "gpuDedicatedMB"}) : NumberAt(phase, {group, "gpuDedicatedMB"});
    const auto s = type ? NumberAt(phase, {group, type, "gpuSharedMB"}) : NumberAt(phase, {group, "gpuSharedMB"});
    if (!d && !s) return std::nullopt;
    return d.value_or(0) + s.value_or(0);
}

// One result's tables, or two side by side (before → after).
std::string Tables(const Value& after, const Value* before) {
    std::string md;
    const auto cell = [&](const std::function<std::optional<double>(const Value&)>& get, int digits = 1) {
        return before ? CompareCell(get(*before), get(after), digits) : Cell(get(after), digits);
    };
    const auto phaseCell = [&](const std::string& name, const std::function<std::optional<double>(const Value&)>& get, int digits = 1) {
        return cell([&](const Value& r) -> std::optional<double> {
            const Value* p = PhaseNamed(r, name);
            return p ? get(*p) : std::nullopt;
        }, digits);
    };
    md += "| phase | Kite CPU ms/s | private MB | commit MB | GPU MB | GPU ms/s | processes | presents | commits |\n";
    md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|\n";
    const Value* phases = after.Find("phases");
    for (const Value& p : phases && phases->AsArray() ? *phases->AsArray() : Array{}) {
        const std::string name = *p.Find("name")->AsString();
        const bool noisy = p.Find("noisy") && p.Find("noisy")->AsBool().value_or(false);
        md += "| " + name + (noisy ? " (noisy)" : "") + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"totals", "cpuMsPerS"}); }) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"totals", "privateWsMB"}); }) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"totals", "commitMB"}); }) + " | ";
        md += phaseCell(name, [](const Value& v) { return GpuMB(v); }) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"totals", "gpuMsPerS"}); }) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"totals", "processCount"}); }, 0) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"kite", "presents"}); }, 0) + " | ";
        md += phaseCell(name, [](const Value& v) { return NumberAt(v, {"kite", "commits"}); }, 0) + " |\n";
    }
    if (PhaseNamed(after, "idle")) {
        md += "\nAt idle, by process type:\n\n| type | count | CPU ms/s | private MB | commit MB | GPU MB | GPU ms/s |\n|---|---:|---:|---:|---:|---:|---:|\n";
        const Value* types = Path(*PhaseNamed(after, "idle"), {"byType"});
        for (const auto& [type, ignored] : types && types->AsObject() ? *types->AsObject() : Object{}) {
            const auto get = [&, t = type](const char* key) {
                return [t, key](const Value& v) { return NumberAt(v, {"byType", t.c_str(), key}); };
            };
            md += "| " + type + " | " + phaseCell("idle", get("processCount"), 0) + " | " + phaseCell("idle", get("cpuMsPerS")) + " | " +
                  phaseCell("idle", get("privateWsMB")) + " | " + phaseCell("idle", get("commitMB")) + " | " +
                  phaseCell("idle", [t = type](const Value& v) { return GpuMB(v, "byType", t.c_str()); }) + " | " +
                  phaseCell("idle", get("gpuMsPerS")) + " |\n";
        }
    }
    md += "\n| measure | value |\n|---|---:|\n";
    const auto row = [&](const std::string& label, const std::function<std::optional<double>(const Value&)>& get, int digits = 1) {
        md += "| " + label + " | " + cell(get, digits) + " |\n";
    };
    row("startup: launch to shown, ms", [](const Value& v) { return NumberAt(v, {"startup", "shownMs"}); });
    row("startup: launch to first page loaded, ms", [](const Value& v) { return NumberAt(v, {"startup", "firstLoadEndMs"}); });
    row("startup: CefInitialize, ms", [](const Value& v) -> std::optional<double> {
        auto a = NumberAt(v, {"startup", "cefInitBeginMs"}), b = NumberAt(v, {"startup", "cefInitEndMs"});
        return a && b ? std::optional<double>(*b - *a) : std::nullopt;
    });
    const auto phaseRow = [&](const std::string& label, const std::string& phase, std::initializer_list<const char*> keys, int digits = 1) {
        if (!PhaseNamed(after, phase)) return;
        const std::vector<const char*> path(keys);
        row(label, [&](const Value& v) -> std::optional<double> {
            const Value* p = PhaseNamed(v, phase);
            if (!p) return std::nullopt;
            const Value* at = p;
            for (const char* k : path) {
                if (!(at = at->Find(k))) return std::nullopt;
            }
            return at->AsNumber();
        }, digits);
    };
    phaseRow("open: tab load p50, ms", "open", {"loadP50Ms"});
    phaseRow("open: processes started", "open", {"spawns"}, 0);
    phaseRow("open: processes ended", "open", {"exits"}, 0);
    phaseRow("crossfade frame interval p50, ms", "switchSpaces", {"frames", "intervalP50Ms"}, 2);
    phaseRow("crossfade frame interval p99, ms", "switchSpaces", {"frames", "intervalP99Ms"}, 2);
    phaseRow("crossfade frames missed", "switchSpaces", {"frames", "missed"}, 0);
    phaseRow("space switch to present p50, ms", "switchSpaces", {"latency", "command", "toPresentP50Ms"});
    phaseRow("tab switch to present p50, ms", "switchTabs", {"latency", "command", "toPresentP50Ms"});
    phaseRow("hover move to present p50, ms", "hover", {"latency", "move", "toPresentP50Ms"});
    phaseRow("hover move to present p99, ms", "hover", {"latency", "move", "toPresentP99Ms"});
    phaseRow("hover: sidebar surface draws", "hover", {"kite", "surfaceDraws", "sidebar"}, 0);
    phaseRow("idle: dwm CPU ms/s", "idle", {"context", "dwmCpuMsPerS"});
    row("shutdown: WM_CLOSE to every process gone, ms", [](const Value& v) { return NumberAt(v, {"shutdown", "allExitedMs"}); });
    row("favicon requests to the page server", [](const Value& v) { return NumberAt(v, {"faviconHits"}); }, 0);
    if (const Value* check = Path(after, {"idleAssert"})) md += "\nIdle check (presents = 0, commits = 0 over the idle phase, every run): **" + std::string(check->AsBool().value_or(false) ? "pass" : "FAIL") + "**\n";
    return md;
}

// MARK: Machine

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

Object Build(const std::wstring& kite) {
    Object b;
    b["exe"] = Narrow(kite);
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (GetFileAttributesExW(kite.c_str(), GetFileExInfoStandard, &data)) {
        b["bytes"] = static_cast<double>((static_cast<ULONGLONG>(data.nFileSizeHigh) << 32) | data.nFileSizeLow);
        SYSTEMTIME t{};
        FileTimeToSystemTime(&data.ftLastWriteTime, &t);
        char text[40];
        std::snprintf(text, sizeof text, "%04u-%02u-%02uT%02u:%02u:%02uZ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
        b["modified"] = std::string(text);
    }
    return b;
}

std::optional<Value> ReadResult(const std::wstring& path, std::string& error) {
    std::ifstream in{std::filesystem::path(path), std::ios::binary};
    if (!in) {
        error = "can't read " + Narrow(path);
        return std::nullopt;
    }
    const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    auto parsed = kite::json::Parse(text);
    const Value* v = std::get_if<Value>(&parsed);
    const Value* schema = v ? v->Find("schema") : nullptr;
    if (!schema || !schema->AsString() || *schema->AsString() != "kiteperf/1") {
        error = Narrow(path) + " isn't a kiteperf/1 result";
        return std::nullopt;
    }
    return *v;
}

int Usage(const std::string& problem) {
    Say(problem);
    Say("usage: kiteperf --kite PATH [--scenario standard|idle|startup|smoke] [--runs N] [--out FILE] [--label NAME] "
        "[--chromium-switches \"...\"] [--keep-profile]");
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
        Print("kiteperf: " + label(*before) + " → " + label(*after) + " (medians of " + Cell(NumberAt(*after, {"runs"}), 0) + " runs)\n\n" +
              Tables(*after, &*before));
        return 0;
    }
    Options options;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::wstring& a = args[i];
        const auto value = [&]() -> std::optional<std::wstring> { return i + 1 < args.size() ? std::optional<std::wstring>(args[++i]) : std::nullopt; };
        if (a == L"--kite") {
            auto v = value();
            if (!v) return Usage("--kite takes Kite.exe's path");
            options.kite = std::filesystem::absolute(*v).wstring();
        } else if (a == L"--scenario") {
            auto v = value();
            options.scenario = v ? Narrow(*v) : "";
            if (options.scenario != "standard" && options.scenario != "idle" && options.scenario != "startup" && options.scenario != "smoke") {
                return Usage("--scenario takes standard, idle, startup or smoke");
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
        } else if (a == L"--foreground") {
            // TODO: a foreground run (Kite activated, real input) measures what a person sees, but
            // takes the focus and the pointer; it needs a machine nobody is using.
            return Usage("--foreground isn't supported: it would take the focus and send real input");
        } else {
            return Usage("unknown option " + Narrow(a));
        }
    }
    if (options.kite.empty()) return Usage("--kite is required");
    if (GetFileAttributesW(options.kite.c_str()) == INVALID_FILE_ATTRIBUTES) return Usage("no Kite.exe at " + Narrow(options.kite));
    if (options.label.empty()) options.label = options.scenario;
    if (options.out.empty()) options.out = Widen("kiteperf-" + options.label + ".json");
    options.assets = KITEPERF_ASSETS;  // this directory in the source tree: sessions/ and pages/

    std::wstring error;
    auto server = PageServer::Start(options.assets / L"pages", kHosts, kPort, error);
    if (!server) {
        Say(Narrow(error));
        return 2;
    }
    Array runs;
    int exitCode = 0;
    for (int i = 0; i < options.runs; ++i) {
        Run run(options, *server, i);
        Value result;
        bool kiteFailed = false;
        const std::wstring problem = run.Go(result, kiteFailed);
        if (!problem.empty()) {
            Say("run " + std::to_string(i + 1) + " failed: " + Narrow(problem));
            if (!kiteFailed) return 2;
            exitCode = 3;
            if (!result.IsObject()) continue;
        }
        runs.push_back(std::move(result));
    }
    if (runs.empty()) return 3;
    std::vector<const Value*> all;
    for (const Value& r : runs) all.push_back(&r);
    Value median = MedianOf(all);
    Object out = median.AsObject() ? *median.AsObject() : Object{};
    out["schema"] = "kiteperf/1";
    out["label"] = options.label;
    out["scenario"] = options.scenario;
    out["runs"] = static_cast<double>(runs.size());
    out["build"] = Build(options.kite);
    out["machine"] = Machine();
    if (!options.switches.empty()) out["chromiumSwitches"] = Narrow(options.switches);
    bool anyNoisy = false, idlePass = true, idleSeen = false;
    for (const Value& r : runs) {
        const Value* phases = r.Find("phases");
        for (const Value& p : phases && phases->AsArray() ? *phases->AsArray() : Array{}) {
            if (const Value* n = p.Find("noisy"); n && n->AsBool().value_or(false)) anyNoisy = true;
            if (const Value* pass = Path(p, {"assert", "pass"})) {
                idleSeen = true;
                idlePass = idlePass && pass->AsBool().value_or(false);
            }
        }
    }
    out["noisy"] = anyNoisy;
    if (idleSeen) out["idleAssert"] = idlePass;
    out["allRuns"] = std::move(runs);
    std::string text;
    Pretty(Value(out), text, 0);
    std::ofstream file{std::filesystem::path(options.out), std::ios::binary | std::ios::trunc};
    file << text << "\n";
    if (!file) {
        Say("couldn't write " + Narrow(options.out));
        return 2;
    }
    Print("kiteperf: " + options.label + ", " + options.scenario + ", medians of " + Cell(out["runs"].AsNumber(), 0) + " runs → " + Narrow(options.out) + "\n\n" + Tables(Value(out), nullptr));
    if (idleSeen && !idlePass && exitCode == 0) exitCode = 4;
    return exitCode;
}
