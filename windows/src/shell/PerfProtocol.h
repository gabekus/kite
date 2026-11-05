#pragma once
// What Kite.exe's measurement hooks and windows/tools/perf/kiteperf share (docs/windows.md,
// Measuring performance): the --perf-control message's tag, Kite's window class, the clock,
// and which --chromium-switches a test run may pass. Header-only, so kiteperf links nothing of
// Kite's but the model (core/ChromiumSwitches.h's feature lists).

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/ChromiumSwitches.h"
#include "shell/Text.h"

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
// isolation still never shares a process across sites). Features only by name, from a list:
// four that can be turned off, and the one Kite turns off by default (Chromium's native
// occlusion tracker) turned back on.
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
    // Features Kite turns off by default (core/ChromiumSwitches.h) that a run may turn back on:
    // Chromium's native occlusion tracker, for its A/B tool and a check after a CEF update.
    static constexpr std::string_view kEnableFeatures[] = {
        chromium_switches::kNativeOcclusion,
    };
    const auto listed = [&](const auto& names) {
        if (value.empty()) return false;
        for (size_t start = 0; start <= value.size();) {
            const size_t comma = std::min(value.find(',', start), value.size());
            if (std::find(std::begin(names), std::end(names), value.substr(start, comma - start)) == std::end(names)) return false;
            start = comma + 1;
        }
        return true;
    };
    if (std::find(std::begin(kFlags), std::end(kFlags), name) != std::end(kFlags)) return value.empty();
    if (name == "disable-features") return listed(kFeatures);
    if (name == "enable-features") return listed(kEnableFeatures);
    if (name == "renderer-process-limit" || name == "num-raster-threads") return digits();
    if (name == "use-angle") return value == "d3d11" || value == "d3d11on12" || value == "d3d9" || value == "vulkan" || value == "warp";
    return false;
}

// --chromium-switches' value, "--a --b=c" split on spaces, as "a" and "b=c": nullopt when a
// token isn't --name[=value], isn't on the allow-list, or turns a feature on that an earlier
// one turned off (or off that one turned on), with that token in `refused`.
inline std::optional<std::vector<std::string>> ParseChromiumSwitches(std::wstring_view text, std::wstring& refused) {
    std::vector<std::string> out, enabled, disabled;
    for (size_t start = 0; start < text.size();) {
        if (text[start] == L' ') {
            ++start;
            continue;
        }
        const size_t end = std::min(text.find(L' ', start), text.size());
        const std::wstring_view token = text.substr(start, end - start);
        start = end;
        const std::string entry = token.starts_with(L"--") ? Narrow(token.substr(2)) : std::string();
        const size_t equals = entry.find('=');
        const std::string_view name = std::string_view(entry).substr(0, equals);
        const std::string_view value = equals == std::string::npos ? std::string_view() : std::string_view(entry).substr(equals + 1);
        bool conflict = false;
        if (name == "enable-features" || name == "disable-features") {
            const bool on = name == "enable-features";
            for (std::string& feature : chromium_switches::FeatureNames(value)) {
                const std::vector<std::string>& other = on ? disabled : enabled;
                conflict = conflict || std::find(other.begin(), other.end(), feature) != other.end();
                (on ? enabled : disabled).push_back(std::move(feature));
            }
        }
        if (name.empty() || !AllowedChromiumSwitch(name, value) || conflict) {
            refused = std::wstring(token);
            return std::nullopt;
        }
        out.push_back(entry);
    }
    return out;
}

}  // namespace kite::perf
