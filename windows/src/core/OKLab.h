#pragma once
// Björn Ottosson's OKLab and the theme colour math built on it. Port of Theme.swift's OKLab
// and Theme helpers; tests/ThemeTests.cpp ports ThemeTests. The HLSL backdrop gets its
// colours already converted here, so the shader never converts per pixel (as on the Mac).

#include <utility>

#include "core/Models.h"

namespace kite {

struct Lab {
    float L = 0, a = 0, b = 0;
};

namespace oklab {
Lab FromSRGB(const ThemeColor& c);
ThemeColor ToSRGB(const Lab& lab);  // clamps to 0...1
}  // namespace oklab

// Mean OKLab lightness of the theme's colours, for choosing dark or light sidebar text.
float Lightness(const Theme& theme);
bool PrefersDarkForeground(const Theme& theme);
// Two vivid colours for the loading glow, from the ends of the palette.
std::pair<ThemeColor, ThemeColor> GlowColors(const Theme& theme);
// The palette's most saturated colour at a readable lightness, for highlighted rows.
ThemeColor Accent(const Theme& theme);

}  // namespace kite
