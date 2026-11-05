#pragma once
// Kite.exe's measurement log (--perf-log FILE, a test profile only), read by
// windows/tools/perf/kiteperf. JSON lines; every time is a raw QueryPerformanceCounter value
// (PerfProtocol.h's Now()), which the harness shares on the same machine. The lines:
//
//   {"type":"header","version":1,"qpcFrequency":F,"pid":P,"chromiumSwitches":[..]}
//   {"type":"mark","name":N,"detail":D,"qpc":Q,"presents":..,"commits":..,"pointerMoves":..,
//    "surfaceDraws":{"sidebar":..,"spaceBar":..,"spaceTip":..,"captionButtons":..,"commandBar":..,"findBar":..,"iconPicker":..}}
//   {"type":"dispatch","msg":M,"qpc":Q,"ms":X}       a dispatched message that took over 8 ms
//   {"type":"input","kind":K,"inputQpc":..,"commitQpc":..,"frameId":..,"targetQpc":..,"presentQpc":..}
//   {"type":"frame","qpc":..,"target":..,"offset":..,"theme":..,"rate":Hz,"commitQpc":..,"frameId":..,
//    "targetQpc":..,"presentQpc":..}
//
// An input is a --perf-control move or command; commitQpc is its first commit within 250 ms,
// or null when nothing committed in that time (then the frame fields are null too). A frame is
// one of the frame clock's (--frame-log's content, `target` the time it was drawn for, plus the
// compositor's rate). frameId is the first composition frame the compositor made after the
// commit: a lower bound, since DirectComposition can take a commit up in a later frame.
// targetQpc is the vblank the compositor made that frame for, and presentQpc when it was
// presented on the monitor Kite's window is on, known only when that frame was the latest
// completed one as it was looked up (DCompositionGetStatistics, Windows 11); otherwise null.
//
// Off (the default) every entry point is one predictable branch on On() and nothing allocates.
// On, lines are appended to a buffer that a writer thread flushes within 50 ms; marks may come
// from any thread (Chromium's from CEF's), the rest from Kite's UI thread.

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

#include "shell/PerfProtocol.h"

namespace kite::perf {

// Whose surface drew (Compositor::DrawSurface's callers, and the command bar's swap chain).
enum class View { Sidebar, SpaceBar, SpaceTip, CaptionButtons, CommandBar, FindBar, IconPicker, Count };

// Opens FILE (replacing it), writes the header and turns the log on. Call once, before Kite
// starts any thread that marks. Empty on success.
std::wstring Open(const std::filesystem::path& file, const std::vector<std::string>& chromiumSwitches);
// The "exit" mark, then the last lines are written and the file closes.
void Close();

class State {
public:
    static bool On() { return on_.load(std::memory_order_relaxed); }

private:
    friend std::wstring Open(const std::filesystem::path&, const std::vector<std::string>&);
    friend void Close();
    static inline std::atomic<bool> on_{false};  // set by Open, cleared by Close; read on every thread
};
inline bool On() { return State::On(); }

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
    // The real pointer's moves over the window and its leaving it (WM_MOUSEMOVE, WM_NCMOUSEMOVE,
    // WM_MOUSELEAVE, WM_NCMOUSELEAVE), not --perf-control's: what tells "Kite drew by itself"
    // from "someone hovered it". The chrome only: a page is CEF's own window and its moves don't
    // come here.
    Counter pointerMoves;
    Counter surfaceDraws[static_cast<int>(View::Count)];
};
inline Counters counters;
inline void CountPresent() {
    if (On()) counters.presents.Add();
}
inline void CountCommit() {
    if (On()) counters.commits.Add();
}
inline void CountSurfaceDraw(View view) {
    if (On()) counters.surfaceDraws[static_cast<int>(view)].Add();
}
inline void CountPointerMove() {
    if (On()) counters.pointerMoves.Add();
}

// A mark with the counters as they are now. Any thread.
void Mark(std::string_view name, std::string_view detail = {});

// Kite's UI thread only, and only while On():
// The window whose monitor's presents count (DirectComposition reports one per display).
void SetWindow(HWND window);
// The displays changed (WM_DISPLAYCHANGE): their targets are looked up again.
void DisplayChanged();
// A dispatched message that took more than 8 ms (`began` from Now()).
void Dispatched(UINT message, int64_t began);
// An input at `qpc`: the next commit within 250 ms is its (an input with none is logged so).
void Input(std::string_view kind, int64_t qpc);
// A frame of the frame clock's (`target` in FrameClock's seconds): logged with the frame its
// commit shows in.
void Frame(double target, double offset, double theme, double rateHz);
// After every commit (Compositor::Commit).
void Committed();
// Whether an input or a frame waits for its commit or its frame's statistics; Poll looks them
// up (the message loop's wait has a short timeout only then).
bool Pending();
void Poll();

}  // namespace kite::perf
