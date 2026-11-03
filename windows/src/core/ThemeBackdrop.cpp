// CPU reference of the theme backdrop shader; see ThemeBackdrop.h. Every step mirrors
// kite_theme_fragment in Kite.metal, in float like the GPU, so the two can be compared.

#include "core/ThemeBackdrop.h"

#include <algorithm>
#include <cfloat>
#include <cmath>

#include "core/OKLab.h"

// Every step rounds to float as the GPU does; x87's wider intermediates would drift off the
// golden fixture the Mac's shader is tested against.
static_assert(FLT_EVAL_METHOD == 0, "the reference needs float arithmetic evaluated in float");

namespace kite {
namespace {

struct F2 {
    float x, y;
};
struct F3 {
    float x, y, z;
};

float Fract(float v) { return v - std::floor(v); }
float Saturate(float v) { return std::clamp(v, 0.f, 1.f); }

// Dave Hoskins' hash12, as in Kite.metal.
float Hash12(F2 p) {
    F3 p3{Fract(p.x * 0.1031f), Fract(p.y * 0.1031f), Fract(p.x * 0.1031f)};
    const float d = p3.x * (p3.y + 33.33f) + p3.y * (p3.z + 33.33f) + p3.z * (p3.x + 33.33f);
    p3 = {p3.x + d, p3.y + d, p3.z + d};
    return Fract((p3.x + p3.y) * p3.z);
}

F3 OklabToLinearSRGB(F3 c) {
    const float l_ = c.x + 0.3963377774f * c.y + 0.2158037573f * c.z;
    const float m_ = c.x - 0.1055613458f * c.y - 0.0638541728f * c.z;
    const float s_ = c.x - 0.0894841775f * c.y - 1.2914855480f * c.z;
    const float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return {4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
            -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
            -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s};
}

float LinearToSRGB(float c) {
    c = Saturate(c);
    return c <= 0.0031308f ? 12.92f * c : 1.055f * std::pow(c, 1.f / 2.4f) - 0.055f;
}

// Where each colour sits, by palette size (kAnchors).
constexpr F2 kAnchors[4][4] = {
    {{0.5f, 0.5f}, {0, 0}, {0, 0}, {0, 0}},
    {{0.0f, 0.0f}, {1.0f, 1.0f}, {0, 0}, {0, 0}},
    {{0.0f, 0.0f}, {1.0f, 0.25f}, {0.35f, 1.0f}, {0, 0}},
    {{0.0f, 0.0f}, {1.0f, 0.0f}, {0.0f, 1.0f}, {1.0f, 1.0f}},
};

F3 ThemeLab(const float (&lab)[4][4], uint32_t count, F2 uv, float aspect) {
    count = std::clamp(count, 1u, 4u);
    if (count == 1) {
        // A touch of vertical falloff keeps a single colour from looking flat.
        return {lab[0][0] - 0.05f * uv.y, lab[0][1], lab[0][2]};
    }
    F3 sum{0, 0, 0};
    float weights = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const F2 d{(uv.x - kAnchors[count - 1][i].x) * aspect, uv.y - kAnchors[count - 1][i].y};
        const float w = std::exp(-(d.x * d.x + d.y * d.y) * 1.6f);
        sum = {sum.x + lab[i][0] * w, sum.y + lab[i][1] * w, sum.z + lab[i][2] * w};
        weights += w;
    }
    const float k = std::max(weights, 1e-4f);
    return {sum.x / k, sum.y / k, sum.z / k};
}

float Mix(float a, float b, float t) { return a + (b - a) * t; }

// The colours drawn: at most four, and never none (the Mac's Theme.init traps on an empty
// palette; `colors` is a public vector here, so an empty one draws the default colour).
const std::vector<ThemeColor>& DrawnColors(const Theme& theme) {
    static const std::vector<ThemeColor> fallback = Theme{}.colors;
    return theme.colors.empty() ? fallback : theme.colors;
}

uint32_t DrawnCount(const Theme& theme) {
    return static_cast<uint32_t>(std::min(DrawnColors(theme).size(), Theme::kMaxColors));
}

void SetPalette(float (&out)[4][4], const Theme& theme) {
    // palette(_:) in ThemeView.swift: four slots, the last colour repeated.
    const std::vector<ThemeColor>& colors = DrawnColors(theme);
    for (size_t i = 0; i < 4; ++i) {
        const ThemeColor& c = colors[std::min<size_t>(i, DrawnCount(theme) - 1)];
        const Lab lab = oklab::FromSRGB(c);
        out[i][0] = lab.L;
        out[i][1] = lab.a;
        out[i][2] = lab.b;
        out[i][3] = 0;
    }
}

}  // namespace

ThemeUniforms MakeThemeUniforms(const Theme& from, const Theme& to, float progress, float widthPx, float heightPx) {
    ThemeUniforms u{};
    SetPalette(u.fromLab, from);
    SetPalette(u.toLab, to);
    u.size[0] = widthPx;
    u.size[1] = heightPx;
    u.fromGrain = from.grain;
    u.toGrain = to.grain;
    u.progress = std::clamp(progress, 0.f, 1.f);
    u.fromCount = DrawnCount(from);
    u.toCount = DrawnCount(to);
    u.fromTint = from.tint;
    u.toTint = to.tint;
    return u;
}

Rgba ShadeThemePixel(const ThemeUniforms& u, float px, float py) {
    const F2 uv{px / u.size[0], py / u.size[1]};
    const float aspect = u.size[0] / std::max(u.size[1], 1.f);
    const F3 a = ThemeLab(u.fromLab, u.fromCount, uv, aspect);
    const F3 b = ThemeLab(u.toLab, u.toCount, uv, aspect);
    const F3 lab{Mix(a.x, b.x, u.progress), Mix(a.y, b.y, u.progress), Mix(a.z, b.z, u.progress)};
    const F3 linear = OklabToLinearSRGB(lab);
    F3 rgb{LinearToSRGB(linear.x), LinearToSRGB(linear.y), LinearToSRGB(linear.z)};

    const float dither = (Hash12({px + 91.7f, py + 91.7f}) - 0.5f) / 255.f;  // so 8-bit gradients don't band
    rgb = {rgb.x + dither, rgb.y + dither, rgb.z + dither};
    const float alpha = Mix(u.fromTint, u.toTint, u.progress);
    const Rgba color{Saturate(rgb.x) * alpha, Saturate(rgb.y) * alpha, Saturate(rgb.z) * alpha, alpha};

    // Film grain multiplied in: a grey grain (mean 0.73, sd 0.21) at 26% opacity per unit of
    // the theme's grain, one grain per device pixel.
    const float grain = Mix(u.fromGrain, u.toGrain, u.progress) * 0.259f;
    const float grey = Saturate(0.73f + (Hash12({px, py}) - 0.5f) * 0.735f);
    const Rgba g{grey * grain, grey * grain, grey * grain, grain};
    auto channel = [&](float gc, float c) { return gc * c + gc * (1 - color.a) + c * (1 - g.a); };
    return {channel(g.r, color.r), channel(g.g, color.g), channel(g.b, color.b), channel(g.a, color.a)};
}

}  // namespace kite
