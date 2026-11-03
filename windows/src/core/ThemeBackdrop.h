#pragma once
// The space's gradient backdrop: the uniforms the HLSL shader takes (shell/shaders/Theme.hlsl)
// and a CPU reference of the same per-pixel maths. Both port `kite_theme_fragment` in the
// Mac's Shaders/Kite.metal line for line; the GPU's output is checked against ShadeThemePixel() in CI
// (Kite.exe --backdrop-test), so the reference is the spec the shader has to meet.

#include <cstddef>
#include <cstdint>

#include "core/Models.h"

namespace kite {

// Byte for byte the Mac's ThemeUniforms (176 bytes), which is also how HLSL packs the
// cbuffer: float4 arrays first, then the scalars in 16-byte registers.
struct ThemeUniforms {
    float fromLab[4][4];  // OKLab (L, a, b, unused), converted once on the CPU
    float toLab[4][4];
    float size[2];  // drawable px
    float fromGrain;
    float toGrain;
    float progress;  // space-switch crossfade, 0...1
    uint32_t fromCount;
    uint32_t toCount;
    float fromTint;  // opacity over the window's material, 0...1
    float toTint;
    float padding[3];
};
static_assert(sizeof(ThemeUniforms) == 176, "must match the Mac's ThemeUniforms and the HLSL cbuffer");
static_assert(offsetof(ThemeUniforms, size) == 128 && offsetof(ThemeUniforms, toTint) == 160);

// ThemeView.draw(in:): palettes padded with their last colour, counts, grain and tint.
ThemeUniforms MakeThemeUniforms(const Theme& from, const Theme& to, float progress, float widthPx, float heightPx);
inline ThemeUniforms MakeThemeUniforms(const Theme& theme, float widthPx, float heightPx) {
    return MakeThemeUniforms(theme, theme, 1, widthPx, heightPx);
}

// Premultiplied RGBA, 0...1.
struct Rgba {
    float r = 0, g = 0, b = 0, a = 0;
};

// The fragment shader at pixel centre (px, py) in drawable pixels, e.g. (0.5, 0.5) for the
// top-left pixel: the theme's premultiplied colour before it's composited over the material.
Rgba ShadeThemePixel(const ThemeUniforms& u, float px, float py);

// What the backdrop is drawn over where the system has no material (Windows 10, Server, or a
// capture, which must not depend on what's behind the window): Windows 11's own solid fallback
// colours for its backdrops. The Mac's .sidebar material has no fixed colour to copy, since it
// blurs whatever is behind the window. Dark unless the theme wants dark text, as on the Mac.
inline Rgba MaterialFallback(bool dark) {
    const float v = dark ? 0x20 / 255.f : 0xF3 / 255.f;
    return {v, v, v, 1};
}

// Porter-Duff "over" of premultiplied colours, as Core Animation and DirectComposition blend.
inline Rgba Over(const Rgba& top, const Rgba& bottom) {
    const float k = 1 - top.a;
    return {top.r + bottom.r * k, top.g + bottom.g * k, top.b + bottom.b * k, top.a + bottom.a * k};
}

}  // namespace kite
