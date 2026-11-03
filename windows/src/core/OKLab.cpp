// Port of Theme.swift's OKLab and Theme helpers; see OKLab.h.

#include "core/OKLab.h"

#include <algorithm>
#include <cmath>

namespace kite {
namespace oklab {
namespace {

// The Mac does these steps in Double; so do we, for identical results.
float ToLinear(float c) { return c <= 0.04045f ? c / 12.92f : static_cast<float>(std::pow((static_cast<double>(c) + 0.055) / 1.055, 2.4)); }

float ToGamma(float c) {
    float x = std::clamp(c, 0.f, 1.f);
    return x <= 0.0031308f ? 12.92f * x : static_cast<float>(1.055 * std::pow(static_cast<double>(x), 1 / 2.4) - 0.055);
}

float Cbrt(float x) { return static_cast<float>(std::cbrt(static_cast<double>(x))); }

}  // namespace

Lab FromSRGB(const ThemeColor& c) {
    float r = ToLinear(c.r), g = ToLinear(c.g), b = ToLinear(c.b);
    float l = Cbrt(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b);
    float m = Cbrt(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b);
    float s = Cbrt(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b);
    return {0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
            1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
            0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s};
}

ThemeColor ToSRGB(const Lab& lab) {
    float l_ = lab.L + 0.3963377774f * lab.a + 0.2158037573f * lab.b;
    float m_ = lab.L - 0.1055613458f * lab.a - 0.0638541728f * lab.b;
    float s_ = lab.L - 0.0894841775f * lab.a - 1.2914855480f * lab.b;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return {ToGamma(4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s),
            ToGamma(-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s),
            ToGamma(-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s)};
}

}  // namespace oklab

float Lightness(const Theme& theme) {
    if (theme.colors.empty()) return 0;
    float sum = 0;
    for (const auto& c : theme.colors) sum += oklab::FromSRGB(c).L;
    return sum / static_cast<float>(theme.colors.size());
}

bool PrefersDarkForeground(const Theme& theme) { return Lightness(theme) > 0.7f; }

std::pair<ThemeColor, ThemeColor> GlowColors(const Theme& theme) {
    auto vivid = [](const ThemeColor& c, float lift) {
        Lab lab = oklab::FromSRGB(c);
        lab.L = std::min(std::max(lab.L, 0.72f) + lift, 0.95f);
        lab.a *= 1.2f;
        lab.b *= 1.2f;
        return oklab::ToSRGB(lab);
    };
    const ThemeColor& first = theme.colors.front();
    const bool several = theme.colors.size() > 1;
    const ThemeColor& last = several ? theme.colors.back() : first;
    return {vivid(first, 0), vivid(last, several ? 0 : 0.12f)};
}

ThemeColor Accent(const Theme& theme) {
    Lab best = oklab::FromSRGB(theme.colors.front());
    float bestChroma = std::hypot(best.a, best.b);
    for (const auto& c : theme.colors) {
        Lab lab = oklab::FromSRGB(c);
        float chroma = std::hypot(lab.a, lab.b);
        // Strictly greater: Swift's max(by:) keeps the first of equal maxima.
        if (chroma > bestChroma) {
            best = lab;
            bestChroma = chroma;
        }
    }
    best.L = std::min(std::max(best.L, 0.5f), 0.62f);
    return oklab::ToSRGB(best);
}

}  // namespace kite
