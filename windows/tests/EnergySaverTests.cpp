// The Mac's Energy Saver decision (KCRuntime.mm's ApplyEnergySaver, AppDelegate.swift's
// chromiumEnergySaver default), which the Mac doesn't unit-test.

#include "Check.h"
#include "core/EnergySaver.h"

using namespace kite;

TEST(energySaverIsOffByDefault) {
    // Chromium's own default (1) would cap pages at 30 fps on a low battery.
    CHECK(!EnergySaver{}.enabled);
    CHECK(EnergySaver{}.State() == BatterySaverModeState::Disabled);
    CHECK(static_cast<int>(EnergySaver{}.State()) == 0);
}

TEST(energySaverOnIsChromesBelowThresholdMode) {
    CHECK(EnergySaver{true}.State() == BatterySaverModeState::EnabledBelowThreshold);
    CHECK(static_cast<int>(EnergySaver{true}.State()) == 1);
}

TEST(energySaverPreferenceIsTheMacs) {
    CHECK(kEnergySaverPreference == "performance_tuning.battery_saver_mode.state");
}
