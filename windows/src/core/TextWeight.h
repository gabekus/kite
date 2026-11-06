#pragma once
// Kite-wide: how the Mac's system font (SF Pro at an NSFont.Weight and a point size) is set on
// Windows, so text inks as heavy and runs as wide as the Mac's. Every view asks for the Mac's
// weight; nothing else picks a Windows weight (shell/SystemFont applies this to DirectWrite).
//
// Measured against every review/*-mac reference (W-text-weight, windows/helix/checkpoints.md):
// Segoe UI inks 0.69–0.85 of SF Pro at the Mac's own weights and runs 0.91–0.97 as wide. SF is
// heavier at every weight, so each Mac weight maps higher on Segoe UI Variable's weight axis:
// regular to about 590 (which matches SF's ink and width), medium 650, semibold 675. Bold takes the
// axis's top (700) and its smallest optical size, the heaviest the font draws: the Mac's semibold
// and bold are past what the axis reaches, and they stay apart rather than both ending at 700.
// The optical size otherwise follows the size, as Windows sets it: Segoe UI Variable's opsz is
// in typographic points at 96 DPI, 0.75 of a DIP (Kite's DIP is the Mac's point). Below the Text
// instance's 10.5 (14pt) the smaller optical sizes are heavier and wider. Regular takes them,
// which widens small text towards SF's, and gives the weight back so it doesn't ink past the
// Mac's; medium and semibold stay at the Text instance there, so a small size can't close the
// 25 between them on the axis or bring semibold up to bold.
//
// Windows 10 has no Segoe UI Variable: Segoe UI's named weights (Regular, Semibold, Bold, Black)
// keep the four apart, regular as before, each heavier one a named step up (medium is the Semibold
// that its 500 already matched, semibold Bold, bold Black), each within the Mac's ink and width.

#include <optional>
#include <string_view>

namespace kite {

// The weights Kite for Mac sets text in (NSFont.Weight).
enum class MacWeight { Regular, Medium, Semibold, Bold };

namespace text_weight {

// Segoe UI Variable's axes (its fvar table): wght 300–700, opsz 5–36, with its named instances at
// opsz 8 (Small), 10.5 (Text) and 36 (Display).
constexpr float kMinWeightAxis = 300;
constexpr float kMaxWeightAxis = 700;
constexpr float kMinOpticalSize = 5;
constexpr float kMaxOpticalSize = 36;
constexpr float kTextOpticalSize = 10.5f;
// Typographic points per DIP: Windows' optical sizes are points at 96 DPI.
constexpr float kPointsPerDip = 0.75f;

// The weight axis per Mac weight at the Text optical size and above.
constexpr float kRegularAxis = 590;
constexpr float kMediumAxis = 650;
constexpr float kSemiboldAxis = 675;
constexpr float kBoldAxis = kMaxWeightAxis;
// What regular gives back per optical-size point below the Text instance's 10.5.
constexpr float kRegularGiveBack = 22;

struct VariableSetting {
    float weight;       // wght
    float opticalSize;  // opsz
};

// The optical size Windows draws `size` DIPs at (clamped to the axis).
float OpticalSize(float size);
// Segoe UI Variable (Windows 11): the axis values for the Mac's `weight` at `size` DIPs.
VariableSetting Variable(MacWeight weight, float size);
// Segoe UI (Windows 10, no axes): the named weight, as DWRITE_FONT_WEIGHT's value.
int StaticWeight(MacWeight weight);
// The weight the Mac names (400, 500, 600, 700), for what DirectWrite reports of a format.
int MacWeightValue(MacWeight weight);

std::string_view Name(MacWeight weight);  // "regular", "medium", "semibold", "bold"
std::optional<MacWeight> ParseWeight(std::string_view name);
constexpr MacWeight kAllWeights[] = {MacWeight::Regular, MacWeight::Medium, MacWeight::Semibold, MacWeight::Bold};

}  // namespace text_weight
}  // namespace kite
