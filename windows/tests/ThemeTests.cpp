// KiteCoreTests.swift ThemeTests, case for case.

#include <cmath>

#include "Check.h"
#include "core/OKLab.h"

using namespace kite;

TEST(okLabRoundTrips) {
    for (const auto& theme : Theme::Presets()) {
        for (const auto& color : theme.colors) {
            ThemeColor back = oklab::ToSRGB(oklab::FromSRGB(color));
            CHECK(std::fabs(back.r - color.r) < 0.002f);
            CHECK(std::fabs(back.g - color.g) < 0.002f);
            CHECK(std::fabs(back.b - color.b) < 0.002f);
        }
    }
}

TEST(whiteAndBlackLightness) {
    CHECK(std::fabs(oklab::FromSRGB(ThemeColor::FromHex(0xFFFFFF)).L - 1) < 0.001f);
    CHECK(std::fabs(oklab::FromSRGB(ThemeColor::FromHex(0x000000)).L) < 0.001f);
}

TEST(foregroundFollowsLightness) {
    CHECK(PrefersDarkForeground(Theme::Make({ThemeColor::FromHex(0xF4F4F0)})));
    CHECK(!PrefersDarkForeground(Theme::Make({ThemeColor::FromHex(0x1F2329)})));
}

TEST(clampsColorCount) {
    Theme theme = Theme::Make(std::vector<ThemeColor>(7, ThemeColor::FromHex(0x123456)));
    CHECK(theme.colors.size() == Theme::kMaxColors);
}

// Not in the Mac suite: the glow and accent stay in gamut and in their lightness bands.
TEST(glowAndAccentStayInRange) {
    for (const auto& theme : Theme::Presets()) {
        auto [a, b] = GlowColors(theme);
        for (const ThemeColor& c : {a, b, Accent(theme)}) {
            CHECK(c.r >= 0 && c.r <= 1 && c.g >= 0 && c.g <= 1 && c.b >= 0 && c.b <= 1);
        }
        float accentL = oklab::FromSRGB(Accent(theme)).L;
        CHECK(accentL > 0.45f && accentL < 0.67f);
    }
}
