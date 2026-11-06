#include "core/TextWeight.h"

#include <algorithm>
#include <cmath>

namespace kite::text_weight {

float OpticalSize(float size) {
    if (!std::isfinite(size)) return kTextOpticalSize;
    return std::clamp(size * kPointsPerDip, kMinOpticalSize, kMaxOpticalSize);
}

VariableSetting Variable(MacWeight weight, float size) {
    const float opsz = OpticalSize(size);
    switch (weight) {
    case MacWeight::Regular:
        return {std::clamp(kRegularAxis - kRegularGiveBack * std::max(0.0f, kTextOpticalSize - opsz), kMinWeightAxis, kMaxWeightAxis), opsz};
    // Never below the Text instance: the smaller optical sizes would bring them up to bold's ink.
    case MacWeight::Medium: return {kMediumAxis, std::max(opsz, kTextOpticalSize)};
    case MacWeight::Semibold: return {kSemiboldAxis, std::max(opsz, kTextOpticalSize)};
    case MacWeight::Bold: return {kBoldAxis, kMinOpticalSize};
    }
    return {kRegularAxis, opsz};
}

int StaticWeight(MacWeight weight) {
    switch (weight) {
    case MacWeight::Regular: return 400;   // Regular
    case MacWeight::Medium: return 600;    // Semibold (Segoe UI has no Medium; 500 matched it already)
    case MacWeight::Semibold: return 700;  // Bold
    case MacWeight::Bold: return 900;      // Black
    }
    return 400;
}

int MacWeightValue(MacWeight weight) {
    switch (weight) {
    case MacWeight::Regular: return 400;
    case MacWeight::Medium: return 500;
    case MacWeight::Semibold: return 600;
    case MacWeight::Bold: return 700;
    }
    return 400;
}

std::string_view Name(MacWeight weight) {
    switch (weight) {
    case MacWeight::Regular: return "regular";
    case MacWeight::Medium: return "medium";
    case MacWeight::Semibold: return "semibold";
    case MacWeight::Bold: return "bold";
    }
    return "regular";
}

std::optional<MacWeight> ParseWeight(std::string_view name) {
    for (const MacWeight weight : kAllWeights) {
        if (Name(weight) == name) return weight;
    }
    return std::nullopt;
}

}  // namespace kite::text_weight
