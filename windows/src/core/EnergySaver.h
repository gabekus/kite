#pragma once
// Chromium's Energy Saver, which drops pages to 30 fps on battery below 20%: the Mac's
// KCRuntime.energySaverEnabled (CEFBridge/KCRuntime.mm) and its chromiumEnergySaver
// default (AppDelegate.swift, main.swift). Off unless the user turns it on, so pages render
// at the display's rate. The shell (shell/Chromium) writes it to Chromium's global
// preferences; Windows has no Settings toggle for it yet.

#include <string_view>

namespace kite {

// The local-state preference Chromium keeps it in.
inline constexpr std::string_view kEnergySaverPreference = "performance_tuning.battery_saver_mode.state";

// Chromium's BatterySaverModeState, as far as Kite uses it. Chrome's own default is
// EnabledBelowThreshold.
enum class BatterySaverModeState : int { Disabled = 0, EnabledBelowThreshold = 1 };

struct EnergySaver {
    // The user's setting: off, as the Mac's unset chromiumEnergySaver default reads.
    bool enabled = false;

    // What Kite sets Chromium's preference to.
    BatterySaverModeState State() const;
};

}  // namespace kite
