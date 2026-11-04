#include "core/EnergySaver.h"

namespace kite {

BatterySaverModeState EnergySaver::State() const {
    return enabled ? BatterySaverModeState::EnabledBelowThreshold : BatterySaverModeState::Disabled;
}

}  // namespace kite
