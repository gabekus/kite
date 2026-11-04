// See PerfLog.h.

#include "shell/PerfLog.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cwchar>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#if defined(_MSC_VER)
#include <dcomp.h>  // the real COMPOSITION_* types, to check the mirrors against
#endif

namespace kite::perf {

namespace {

// DirectComposition's frame statistics (Windows 11's dcomptypes.h), mirrored: older Windows and
// MinGW's headers don't have them, so the functions are looked up at run time.
struct FrameStats {
    UINT64 startTime, targetTime, framePeriod;
};
struct TargetId {
    LUID displayAdapterLuid, renderAdapterLuid;
    UINT vidPnSourceId, vidPnTargetId, uniqueId;
};
struct Stats {
    UINT presentCount, refreshCount, virtualRefreshCount;
    UINT64 time;
};
struct TargetStats {
    UINT outstandingPresents;
    UINT64 presentTime, vblankDuration;
    Stats presentedStats, completedStats;
};
static_assert(sizeof(FrameStats) == 24 && sizeof(TargetId) == 28 && sizeof(Stats) == 24 && sizeof(TargetStats) == 72);
#if defined(_MSC_VER)
static_assert(sizeof(FrameStats) == sizeof(COMPOSITION_FRAME_STATS) && sizeof(TargetId) == sizeof(COMPOSITION_TARGET_ID) &&
              sizeof(Stats) == sizeof(COMPOSITION_STATS) && sizeof(TargetStats) == sizeof(COMPOSITION_TARGET_STATS));
#endif
constexpr int kFrameCreated = 0, kFrameCompleted = 2;  // COMPOSITION_FRAME_ID_TYPE
using GetFrameIdFn = HRESULT(WINAPI*)(int type, UINT64* id);
using GetStatisticsFn = HRESULT(WINAPI*)(UINT64 id, FrameStats* stats, UINT count, TargetId* targets, UINT* actual);
using GetTargetStatisticsFn = HRESULT(WINAPI*)(UINT64 id, const TargetId* target, TargetStats* stats);

// Looked up on first use, from the dcomp.dll the compositor has loaded by then (Kite.exe
// delay-loads it).
struct Dcomp {
    GetFrameIdFn getFrameId = nullptr;
    GetStatisticsFn getStatistics = nullptr;
    GetTargetStatisticsFn getTargetStatistics = nullptr;
};
const Dcomp& Functions() {
    static const Dcomp functions = [] {
        Dcomp d;
        if (HMODULE dcomp = GetModuleHandleW(L"dcomp.dll")) {
            const auto find = [&](const char* name) { return reinterpret_cast<void*>(GetProcAddress(dcomp, name)); };
            d.getFrameId = reinterpret_cast<GetFrameIdFn>(find("DCompositionGetFrameId"));
            d.getStatistics = reinterpret_cast<GetStatisticsFn>(find("DCompositionGetStatistics"));
            d.getTargetStatistics = reinterpret_cast<GetTargetStatisticsFn>(find("DCompositionGetTargetStatistics"));
        }
        return d;
    }();
    return functions;
}

// The file and its writer: lines go into `buffer` under `mutex` (any thread), and the writer
// thread writes them out within 50 ms of the first, never holding the lock across the write.
std::mutex mutex;
std::condition_variable wake;
std::string buffer;
bool quit = false;
std::thread writer;
HANDLE file = INVALID_HANDLE_VALUE;
int64_t frequency = 1;

void WriteOut() {
    std::unique_lock lock(mutex);
    for (;;) {
        wake.wait(lock, [] { return quit || !buffer.empty(); });
        if (!quit) wake.wait_for(lock, std::chrono::milliseconds(50), [] { return quit; });
        std::string out;
        out.swap(buffer);
        const bool last = quit;
        lock.unlock();
        DWORD written = 0;
        if (!out.empty()) WriteFile(file, out.data(), static_cast<DWORD>(out.size()), &written, nullptr);
        lock.lock();
        if (last && buffer.empty()) return;
    }
}

void Write(const std::string& line) {
    {
        std::lock_guard lock(mutex);
        if (file == INVALID_HANDLE_VALUE || quit) return;
        buffer += line;
    }
    wake.notify_one();
}

constexpr const char* kViewNames[] = {"sidebar", "spaceBar", "spaceTip", "captionButtons", "commandBar"};
static_assert(std::size(kViewNames) == static_cast<size_t>(View::Count));

std::string Quoted(std::string_view text) {
    std::string out = "\"";
    for (char c : text) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += c;
        } else if (static_cast<unsigned char>(c) < 0x20) {
            char escaped[16];
            std::snprintf(escaped, sizeof escaped, "\\u%04x", static_cast<unsigned>(c));
            out += escaped;
        } else {
            out += c;
        }
    }
    return out + "\"";
}

std::string Number(double value) {
    char text[40];
    std::snprintf(text, sizeof text, "%.6g", value);
    return text;
}

std::string Qpc(int64_t value) { return value ? std::to_string(value) : "null"; }

// Kite's UI thread only.
HWND window = nullptr;
struct OpenInput {
    std::string kind;
    int64_t qpc;
};
struct OpenFrame {
    int64_t qpc, target;
    double offset, theme, rate;
};
struct Waiting {
    bool frame;
    std::string kind;
    int64_t inputQpc, commitQpc;
    UINT64 frameId;
    OpenFrame data;
};
std::optional<OpenInput> openInput;
std::optional<OpenFrame> openFrame;
std::vector<Waiting> waiting;

// The DirectComposition target (adapter and VidPN source) of the monitor Kite's window is on,
// from the display configuration, once per monitor.
std::optional<std::pair<LUID, UINT>> WindowTarget() {
    static std::map<HMONITOR, std::optional<std::pair<LUID, UINT>>> cache;
    HMONITOR monitor = window ? MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) : nullptr;
    if (!monitor) return std::nullopt;
    if (auto it = cache.find(monitor); it != cache.end()) return it->second;
    std::optional<std::pair<LUID, UINT>> found;
    MONITORINFOEXW info{};
    info.cbSize = sizeof info;
    UINT32 pathCount = 0, modeCount = 0;
    if (GetMonitorInfoW(monitor, &info) && GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount) == ERROR_SUCCESS) {
        std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
        std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
        if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount, modes.data(), nullptr) == ERROR_SUCCESS) {
            for (UINT32 i = 0; i < pathCount && !found; ++i) {
                DISPLAYCONFIG_SOURCE_DEVICE_NAME name{};
                name.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                name.header.size = sizeof name;
                name.header.adapterId = paths[i].sourceInfo.adapterId;
                name.header.id = paths[i].sourceInfo.id;
                if (DisplayConfigGetDeviceInfo(&name.header) == ERROR_SUCCESS && std::wcscmp(name.viewGdiDeviceName, info.szDevice) == 0) {
                    found = std::make_pair(paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id);
                }
            }
        }
    }
    cache[monitor] = found;
    return found;
}

// When the first frame the compositor made after `commitFrame` (the frame it was making as the
// commit came) was meant to show and was presented. Nullopt until that frame is complete. The
// target's presentedStats is its latest present, so it's that frame's only while that frame is
// the latest completed one.
struct Presented {
    int64_t presentQpc = 0, targetQpc = 0;
};
std::optional<Presented> LookUp(UINT64 commitFrame) {
    const Dcomp& d = Functions();
    if (!d.getFrameId || !d.getStatistics || !d.getTargetStatistics || !commitFrame) return Presented{};
    UINT64 completed = 0;
    if (FAILED(d.getFrameId(kFrameCompleted, &completed))) return Presented{};
    const UINT64 frame = commitFrame + 1;
    if (completed < frame) return std::nullopt;
    FrameStats stats{};
    TargetId targets[8]{};
    UINT count = 0;
    Presented out;
    if (FAILED(d.getStatistics(frame, &stats, 8, targets, &count))) return out;
    out.targetQpc = static_cast<int64_t>(stats.targetTime);
    if (completed != frame || count == 0) return out;
    count = std::min<UINT>(count, 8);
    // The target on Kite's monitor, else the first.
    UINT pick = 0;
    if (const auto target = WindowTarget()) {
        for (UINT i = 0; i < count; ++i) {
            if (targets[i].displayAdapterLuid.LowPart == target->first.LowPart &&
                targets[i].displayAdapterLuid.HighPart == target->first.HighPart && targets[i].vidPnSourceId == target->second) {
                pick = i;
            }
        }
    }
    TargetStats t{};
    if (SUCCEEDED(d.getTargetStatistics(frame, &targets[pick], &t))) {
        const UINT64 time = t.presentTime ? t.presentTime : t.presentedStats.time;
        if (time >= stats.startTime) out.presentQpc = static_cast<int64_t>(time);
    }
    return out;
}

void WriteWaiting(const Waiting& w, const Presented& p) {
    const std::string id = w.frameId ? std::to_string(w.frameId + 1) : "null";
    if (w.frame) {
        Write("{\"type\":\"frame\",\"qpc\":" + Qpc(w.data.qpc) + ",\"target\":" + Qpc(w.data.target) + ",\"offset\":" +
              Number(w.data.offset) + ",\"theme\":" + Number(w.data.theme) + ",\"rate\":" + Number(w.data.rate) +
              ",\"commitQpc\":" + Qpc(w.commitQpc) + ",\"frameId\":" + id + ",\"targetQpc\":" + Qpc(p.targetQpc) +
              ",\"presentQpc\":" + Qpc(p.presentQpc) + "}\n");
    } else {
        Write("{\"type\":\"input\",\"kind\":" + Quoted(w.kind) + ",\"inputQpc\":" + Qpc(w.inputQpc) + ",\"commitQpc\":" +
              Qpc(w.commitQpc) + ",\"frameId\":" + id + ",\"targetQpc\":" + Qpc(p.targetQpc) + ",\"presentQpc\":" + Qpc(p.presentQpc) +
              "}\n");
    }
}

// An input that no commit followed within 250 ms.
void Uncommitted(OpenInput input) { WriteWaiting(Waiting{false, std::move(input.kind), input.qpc, 0, 0, {}}, Presented{}); }

}  // namespace

std::wstring Open(const std::filesystem::path& path, const std::vector<std::string>& chromiumSwitches) {
    file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return L"couldn't create " + path.wstring();
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    frequency = f.QuadPart;
    std::string switches = "[";
    for (const std::string& s : chromiumSwitches) switches += (switches.size() > 1 ? "," : "") + Quoted(s);
    buffer = "{\"type\":\"header\",\"version\":1,\"qpcFrequency\":" + std::to_string(frequency) +
             ",\"pid\":" + std::to_string(GetCurrentProcessId()) + ",\"chromiumSwitches\":" + switches + "]}\n";
    writer = std::thread(WriteOut);
    State::on_ = true;
    return {};
}

void Close() {
    if (!On()) return;
    if (openInput) Uncommitted(std::move(*openInput));
    openInput.reset();
    for (const Waiting& w : waiting) WriteWaiting(w, LookUp(w.frameId).value_or(Presented{}));
    waiting.clear();
    Mark("exit");
    {
        std::lock_guard lock(mutex);
        quit = true;
    }
    wake.notify_one();
    writer.join();
    CloseHandle(file);
    file = INVALID_HANDLE_VALUE;
    State::on_ = false;
}

void Mark(std::string_view name, std::string_view detail) {
    if (!On()) return;
    std::string line = "{\"type\":\"mark\",\"name\":" + Quoted(name) + ",\"detail\":" + Quoted(detail) + ",\"qpc\":" +
                       std::to_string(Now()) + ",\"presents\":" + std::to_string(counters.presents.Get()) +
                       ",\"commits\":" + std::to_string(counters.commits.Get()) + ",\"surfaceDraws\":{";
    for (int i = 0; i < static_cast<int>(View::Count); ++i) {
        if (i) line += ',';
        line += Quoted(kViewNames[i]) + ":" + std::to_string(counters.surfaceDraws[i].Get());
    }
    Write(line + "}}\n");
}

void SetWindow(HWND hwnd) { window = hwnd; }

void Dispatched(UINT message, int64_t began) {
    const double ms = static_cast<double>(Now() - began) * 1000.0 / static_cast<double>(frequency);
    if (ms <= 8) return;
    Write("{\"type\":\"dispatch\",\"msg\":" + std::to_string(message) + ",\"qpc\":" + std::to_string(began) + ",\"ms\":" + Number(ms) +
          "}\n");
}

void Input(std::string_view kind, int64_t qpc) {
    if (openInput) Uncommitted(std::move(*openInput));
    openInput = OpenInput{std::string(kind), qpc};
}

void Frame(double target, double offset, double theme, double rateHz) {
    // One that drew nothing (minimized) is logged without a frame.
    if (openFrame) WriteWaiting(Waiting{true, {}, 0, 0, 0, *openFrame}, Presented{});
    openFrame = OpenFrame{Now(), static_cast<int64_t>(target * static_cast<double>(frequency)), offset, theme, rateHz};
}

void Committed() {
    if (!openInput && !openFrame) return;
    const int64_t now = Now();
    UINT64 frame = 0;
    const Dcomp& d = Functions();
    if (!d.getFrameId || FAILED(d.getFrameId(kFrameCreated, &frame))) frame = 0;
    if (openInput) {
        if (now - openInput->qpc <= frequency / 4) waiting.push_back(Waiting{false, std::move(openInput->kind), openInput->qpc, now, frame, {}});
        else Uncommitted(std::move(*openInput));
        openInput.reset();
    }
    if (openFrame) waiting.push_back(Waiting{true, {}, 0, now, frame, *openFrame});
    openFrame.reset();
}

bool Pending() { return openInput.has_value() || !waiting.empty(); }

void Poll() {
    const int64_t now = Now();
    if (openInput && now - openInput->qpc > frequency / 4) {
        Uncommitted(std::move(*openInput));
        openInput.reset();
    }
    std::erase_if(waiting, [&](const Waiting& w) {
        std::optional<Presented> presented = LookUp(w.frameId);
        // Statistics are kept for a short history only: a second on, it's logged without.
        if (!presented && now - w.commitQpc < frequency) return false;
        WriteWaiting(w, presented.value_or(Presented{}));
        return true;
    });
}

}  // namespace kite::perf
