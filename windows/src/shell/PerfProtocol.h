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

// The file a test profile has (kiteperf writes it into each fresh profile, CI's steps create
// it): the measurement hooks run only on a KITE_SUPPORT_PATH that holds it.
constexpr wchar_t kTestProfileMarker[] = L"kite-test-profile";

// --chromium-switches: only what measuring Chromium's own cost needs (the switch audit, P12).
// Each was checked against "nothing that weakens the sandbox, site isolation or web security,
// opens a debugging port, or changes a path or a process Chromium launches": they choose the GPU
// backend and rasterization (all still in the sandboxed GPU process; no in-process GPU),
// throttling and backgrounding, and how many renderers Chromium keeps (a soft limit: site
// isolation still never shares a process across sites). Features only by name, from a list.
// `name` without its dashes; `value` empty for none.
inline bool AllowedChromiumSwitch(std::string_view name, std::string_view value) {
    const auto digits = [&] {
        return !value.empty() && value.size() <= 4 && std::all_of(value.begin(), value.end(), [](char c) { return c >= '0' && c <= '9'; });
    };
    static constexpr std::string_view kFlags[] = {
        "process-per-site",
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
        "disable-domain-reliability",
        "disable-spell-checking",
        "enable-low-end-device-mode",
    };
    // Features the audit turns off one at a time: occlusion, timer throttling, the spare
    // renderer and the back/forward cache.
    static constexpr std::string_view kFeatures[] = {
        "CalculateNativeWinOcclusion",
        "IntensiveWakeUpThrottling",
        "SpareRendererForSitePerProcess",
        "BackForwardCache",
    };
    if (std::find(std::begin(kFlags), std::end(kFlags), name) != std::end(kFlags)) return value.empty();
    if (name == "disable-features") {
        if (value.empty()) return false;
        for (size_t start = 0; start <= value.size();) {
            const size_t comma = std::min(value.find(',', start), value.size());
            if (std::find(std::begin(kFeatures), std::end(kFeatures), value.substr(start, comma - start)) == std::end(kFeatures)) return false;
            start = comma + 1;
        }
        return true;
    }
    if (name == "renderer-process-limit" || name == "num-raster-threads") return digits();
    if (name == "use-angle") return value == "d3d11" || value == "d3d11on12" || value == "d3d9" || value == "vulkan" || value == "warp";
    return false;
}

}  // namespace kite::perf
