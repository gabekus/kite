#pragma once
// Kite.exe's measurement log (--perf-log FILE, a test profile only), read by
// windows/tools/perf/kiteperf. JSON lines with raw QueryPerformanceCounter values, which the
// harness shares on the same machine; the first line has qpcFrequency.
//
//   {"type":"header","qpcFrequency":F,"pid":P}
//   {"type":"mark","name":N,"detail":D,"qpc":Q,"presents":..,"commits":..,"surfaceDraws":{..}}
//   {"type":"dispatch","msg":M,"qpc":Q,"ms":X}             a message that took over 8 ms
//   {"type":"input","kind":K,"inputQpc":..,"commitQpc":..,"frameId":..,"presentQpc":..}
//   {"type":"frame","qpc":..,"target":..,"offset":..,"theme":..,"rate":Hz,"frameId":..,"presentQpc":..}
//
// An input's and a frame's frameId is the first composition frame made after its commit;
// targetQpc is when the compositor meant it to show and presentQpc when it was presented
// (DCompositionGetStatistics, Windows 11; null where there are none).
//
// Marks come from either thread (Chromium's are on CEF's); the counters, inputs and frames are
// Kite's UI thread's. Off (the default), the counters are plain stores and everything else is
// behind On(), one predictable branch: nothing allocates and nothing is written.

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace kite::perf {

// Whose surface drew (Compositor::DrawSurface's callers, and the command bar's swap chain).
enum class View { Sidebar, SpaceBar, SpaceTip, CaptionButtons, CommandBar, Count };

// Bumped on Kite's UI thread only, read from any: a relaxed load and store, no locked add.
class Counter {
public:
    void Add() { value_.store(value_.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed); }
    uint64_t Get() const { return value_.load(std::memory_order_relaxed); }

private:
    std::atomic<uint64_t> value_{0};
};

struct Counters {
    Counter presents;  // the backdrop's and the command bar's Present
    Counter commits;   // every IDCompositionDevice::Commit (Compositor::Commit)
    Counter surfaceDraws[static_cast<int>(View::Count)];
};
inline Counters counters;
inline void CountPresent() { counters.presents.Add(); }
inline void CountCommit() { counters.commits.Add(); }
inline void CountSurfaceDraw(View view) { counters.surfaceDraws[static_cast<int>(view)].Add(); }

// Set once, before Kite starts any thread; read-only after.
inline bool enabled = false;
inline bool On() { return enabled; }

// Opens FILE (replacing it) and writes the header. Empty on success.
std::wstring Open(const std::filesystem::path& file);
// The "exit" mark, then the file closes.
void Close();
int64_t Now();
// A mark with the counters as they are now. Any thread.
void Mark(std::string_view name, std::string_view detail = {});

// Kite's UI thread only, and only while On():
// A dispatched message that took more than 8 ms (`began` from Now()).
void Dispatched(UINT message, int64_t began);
// An input at `qpc`: the next commit within 250 ms is its, and is logged with the frame it
// reaches the screen in.
void Input(std::string_view kind, int64_t qpc);
// A frame of the frame clock's (the --frame-log content; `target` in FrameClock's seconds):
// logged with the frame its commit shows in, its present time and the compositor's rate.
void Frame(double target, double offset, double theme, double rateHz);
// After every commit (Compositor::Commit).
void Committed();
// Whether frames wait for their present time; Poll looks them up (the message loop's wait has
// a short timeout only then).
bool Pending();
void Poll();

}  // namespace kite::perf
