// See PerfLog.h.

#include "shell/PerfLog.h"

#include <cstdio>
#include <iterator>
#include <mutex>
#include <optional>
#include <vector>

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
constexpr int kFrameCreated = 0, kFrameCompleted = 2;  // COMPOSITION_FRAME_ID_TYPE
using GetFrameIdFn = HRESULT(WINAPI*)(int type, UINT64* id);
using GetStatisticsFn = HRESULT(WINAPI*)(UINT64 id, FrameStats* stats, UINT count, TargetId* targets, UINT* actual);
using GetTargetStatisticsFn = HRESULT(WINAPI*)(UINT64 id, const TargetId* target, TargetStats* stats);

GetFrameIdFn getFrameId = nullptr;
GetStatisticsFn getStatistics = nullptr;
GetTargetStatisticsFn getTargetStatistics = nullptr;

std::mutex mutex;  // the file, for marks from CEF's thread
HANDLE file = INVALID_HANDLE_VALUE;
int64_t frequency = 1;

constexpr const char* kViewNames[] = {"sidebar", "spaceBar", "spaceTip", "captionButtons", "commandBar"};
static_assert(std::size(kViewNames) == static_cast<size_t>(View::Count));

// Kite's UI thread only.
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

void Write(const std::string& line) {
    std::lock_guard lock(mutex);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

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

// When the first frame the compositor made after `commitFrame` (the frame it was making as the
// commit came) reached the screen: the earliest present on any of its targets (the vblank it was
// presented at, when it's this frame's; Windows 11 leaves presentTime 0), and the time the
// compositor aimed for. Nullopt
// until that frame is complete.
struct Presented {
    int64_t presentQpc = 0, targetQpc = 0;
};
std::optional<Presented> LookUp(UINT64 commitFrame) {
    if (!getFrameId || !getStatistics || !getTargetStatistics || !commitFrame) return Presented{};
    UINT64 completed = 0;
    if (FAILED(getFrameId(kFrameCompleted, &completed))) return Presented{};
    const UINT64 frame = commitFrame + 1;
    if (completed < frame) return std::nullopt;
    FrameStats stats{};
    TargetId targets[8]{};
    UINT count = 0;
    Presented out;
    if (FAILED(getStatistics(frame, &stats, 8, targets, &count))) return out;
    out.targetQpc = static_cast<int64_t>(stats.targetTime);
    for (UINT i = 0; i < count && i < 8; ++i) {
        TargetStats target{};
        if (FAILED(getTargetStatistics(frame, &targets[i], &target))) continue;
        // presentedStats is the target's latest present, which can be an earlier frame's.
        const UINT64 presented = target.presentedStats.time >= stats.startTime ? target.presentedStats.time : 0;
        const auto time = static_cast<int64_t>(target.presentTime ? target.presentTime : presented);
        if (!time) continue;
        if (!out.presentQpc || time < out.presentQpc) out.presentQpc = time;
    }
    return out;
}

void WriteWaiting(const Waiting& w, const Presented& p) {
    const std::string id = w.frameId ? std::to_string(w.frameId + 1) : "null";
    if (w.frame) {
        Write("{\"type\":\"frame\",\"qpc\":" + Qpc(w.data.qpc) + ",\"target\":" + Qpc(w.data.target) +
              ",\"offset\":" + Number(w.data.offset) + ",\"theme\":" + Number(w.data.theme) + ",\"rate\":" + Number(w.data.rate) +
              ",\"commitQpc\":" + Qpc(w.commitQpc) + ",\"frameId\":" + id + ",\"targetQpc\":" + Qpc(p.targetQpc) +
              ",\"presentQpc\":" + Qpc(p.presentQpc) + "}\n");
    } else {
        Write("{\"type\":\"input\",\"kind\":" + Quoted(w.kind) + ",\"inputQpc\":" + Qpc(w.inputQpc) + ",\"commitQpc\":" +
              Qpc(w.commitQpc) + ",\"frameId\":" + id + ",\"targetQpc\":" + Qpc(p.targetQpc) + ",\"presentQpc\":" + Qpc(p.presentQpc) +
              "}\n");
    }
}

}  // namespace

int64_t Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

std::wstring Open(const std::filesystem::path& path) {
    file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return L"couldn't create " + path.wstring();
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    frequency = f.QuadPart;
    HMODULE dcomp = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (dcomp) {
        getFrameId = reinterpret_cast<GetFrameIdFn>(reinterpret_cast<void*>(GetProcAddress(dcomp, "DCompositionGetFrameId")));
        getStatistics = reinterpret_cast<GetStatisticsFn>(reinterpret_cast<void*>(GetProcAddress(dcomp, "DCompositionGetStatistics")));
        getTargetStatistics =
            reinterpret_cast<GetTargetStatisticsFn>(reinterpret_cast<void*>(GetProcAddress(dcomp, "DCompositionGetTargetStatistics")));
    }
    enabled = true;
    Write("{\"type\":\"header\",\"version\":1,\"qpcFrequency\":" + std::to_string(frequency) +
          ",\"pid\":" + std::to_string(GetCurrentProcessId()) + ",\"frameStatistics\":" + (getStatistics ? "true" : "false") + "}\n");
    return {};
}

void Close() {
    if (!enabled) return;
    for (const Waiting& w : waiting) WriteWaiting(w, LookUp(w.frameId).value_or(Presented{}));
    waiting.clear();
    Mark("exit");
    std::lock_guard lock(mutex);
    CloseHandle(file);
    file = INVALID_HANDLE_VALUE;
}

void Mark(std::string_view name, std::string_view detail) {
    if (!enabled) return;
    std::string line = "{\"type\":\"mark\",\"name\":" + Quoted(name) + ",\"detail\":" + Quoted(detail) + ",\"qpc\":" +
                       std::to_string(Now()) + ",\"presents\":" + std::to_string(counters.presents.Get()) +
                       ",\"commits\":" + std::to_string(counters.commits.Get()) + ",\"surfaceDraws\":{";
    for (int i = 0; i < static_cast<int>(View::Count); ++i) {
        if (i) line += ',';
        line += Quoted(kViewNames[i]) + ":" + std::to_string(counters.surfaceDraws[i].Get());
    }
    Write(line + "}}\n");
}

void Dispatched(UINT message, int64_t began) {
    const int64_t now = Now();
    const double ms = static_cast<double>(now - began) * 1000.0 / static_cast<double>(frequency);
    if (ms <= 8) return;
    Write("{\"type\":\"dispatch\",\"msg\":" + std::to_string(message) + ",\"qpc\":" + std::to_string(began) + ",\"ms\":" + Number(ms) +
          "}\n");
}

void Input(std::string_view kind, int64_t qpc) { openInput = OpenInput{std::string(kind), qpc}; }

void Frame(double target, double offset, double theme, double rateHz) {
    // One that drew nothing (minimized) is logged without a frame.
    if (openFrame) WriteWaiting(Waiting{true, {}, 0, 0, 0, *openFrame}, Presented{});
    openFrame = OpenFrame{Now(), static_cast<int64_t>(target * static_cast<double>(frequency)), offset, theme, rateHz};
}

void Committed() {
    if (!openInput && !openFrame) return;
    const int64_t now = Now();
    UINT64 frame = 0;
    if (!getFrameId || FAILED(getFrameId(kFrameCreated, &frame))) frame = 0;
    if (openInput && now - openInput->qpc <= frequency / 4) {
        waiting.push_back(Waiting{false, std::move(openInput->kind), openInput->qpc, now, frame, {}});
    }
    openInput.reset();
    if (openFrame) waiting.push_back(Waiting{true, {}, 0, now, frame, *openFrame});
    openFrame.reset();
}

bool Pending() { return !waiting.empty(); }

void Poll() {
    const int64_t now = Now();
    std::erase_if(waiting, [&](const Waiting& w) {
        std::optional<Presented> presented = LookUp(w.frameId);
        // Statistics are kept for a short history only: a second on, it's logged without.
        if (!presented && now - w.commitQpc < frequency) return false;
        WriteWaiting(w, presented.value_or(Presented{}));
        return true;
    });
}

}  // namespace kite::perf
