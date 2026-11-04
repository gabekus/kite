#pragma once
// What Kite.exe's measurement hooks and windows/tools/perf/kiteperf share (docs/windows.md,
// Measuring performance): the --perf-control message's tag, Kite's window class, the clock,
// and which --chromium-switches a test run may pass. Header-only, so kiteperf links nothing of
// Kite's.

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <string_view>

namespace kite::perf {

// WM_COPYDATA's dwData for a --perf-control request ('KPRF').
constexpr ULONG_PTR kControlTag = 0x4B505246;
// The browser window's class (MainWindow), which kiteperf looks for in Kite's process.
constexpr wchar_t kWindowClass[] = L"KiteBrowserWindow";

// The clock every perf record uses: raw QueryPerformanceCounter ticks, the same in every
// process on the machine.
inline int64_t Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

// --chromium-switches: only what measuring Chromium's own cost needs (the switch audit, P12),
// so a test run can't weaken the sandbox or web security, open a debugging port, or change a
// path or a process Chromium launches. `name` without its dashes; `value` empty for none.
inline bool AllowedChromiumSwitch(std::string_view name, std::string_view value) {
    const auto all = [&](auto pred) { return !value.empty() && std::all_of(value.begin(), value.end(), pred); };
    const auto digits = [&] { return all([](char c) { return c >= '0' && c <= '9'; }) && value.size() <= 4; };
    const auto featureList = [&] {
        return all([](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == ','; });
    };
    // Flags without a value.
    static constexpr std::string_view kFlags[] = {
        "process-per-site",
        "in-process-gpu",
        "disable-gpu",
        "disable-gpu-compositing",
        "disable-gpu-rasterization",
        "enable-gpu-rasterization",
        "enable-zero-copy",
        "disable-zero-copy",
        "disable-partial-raster",
        "disable-direct-composition",
        "disable-gpu-vsync",
        "disable-frame-rate-limit",
        "disable-gpu-shader-disk-cache",
        "disable-background-timer-throttling",
        "disable-renderer-backgrounding",
        "disable-backgrounding-occluded-windows",
        "disable-smooth-scrolling",
        "disable-renderer-accessibility",
        "disable-extensions",
        "disable-component-update",
        "disable-background-networking",
        "disable-domain-reliability",
        "disable-spell-checking",
        "enable-low-end-device-mode",
    };
    if (std::find(std::begin(kFlags), std::end(kFlags), name) != std::end(kFlags)) return value.empty();
    if (name == "enable-features" || name == "disable-features") return featureList();
    if (name == "renderer-process-limit" || name == "num-raster-threads") return digits();
    if (name == "use-angle") return value == "d3d11" || value == "d3d11on12" || value == "d3d9" || value == "vulkan" || value == "warp";
    return false;
}

}  // namespace kite::perf
