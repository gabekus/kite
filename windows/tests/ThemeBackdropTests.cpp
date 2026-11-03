// core/ThemeBackdrop: the CPU reference of Kite.metal's kite_theme_fragment, which the HLSL
// shader is checked against on the GPU. These pin the reference to what the Metal source says.

#include <cmath>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "Check.h"
#include "core/Json.h"
#include "core/OKLab.h"
#include "core/ThemeBackdrop.h"

using namespace kite;

namespace {

bool Near(float a, float b, float tolerance) { return std::fabs(a - b) <= tolerance; }

// No grain, opaque: the pixel is the palette colour, give or take the ±0.5/255 dither.
Theme Flat(std::vector<ThemeColor> colors) { return Theme::Make(std::move(colors), 0, 1); }

}  // namespace

TEST(uniformsPadThePaletteWithItsLastColour) {
    Theme theme = Theme::Make({ThemeColor::FromHex(0xFF9A6C), ThemeColor::FromHex(0x8A5CF5)});
    ThemeUniforms u = MakeThemeUniforms(theme, 1280, 820);
    CHECK(u.fromCount == 2 && u.toCount == 2 && u.progress == 1);
    for (int c = 0; c < 4; ++c) CHECK(u.fromLab[2][c] == u.fromLab[1][c] && u.fromLab[3][c] == u.fromLab[1][c]);
    Lab first = oklab::FromSRGB(theme.colors[0]);
    CHECK(u.fromLab[0][0] == first.L && u.fromLab[0][1] == first.a && u.fromLab[0][2] == first.b);
    CHECK(u.size[0] == 1280 && u.size[1] == 820 && u.fromTint == theme.tint && u.fromGrain == theme.grain);
}

TEST(singleColourIsTheColourWithAVerticalFalloff) {
    ThemeColor c = ThemeColor::FromHex(0x5FD3E6);
    ThemeUniforms u = MakeThemeUniforms(Flat({c}), 100, 100);
    Rgba top = ShadeThemePixel(u, 50.5f, 0.5f);
    CHECK(Near(top.r, c.r, 2 / 255.f) && Near(top.g, c.g, 2 / 255.f) && Near(top.b, c.b, 2 / 255.f) && top.a == 1);
    // OKLab L drops by 0.05 from top to bottom.
    Lab bottomLab = oklab::FromSRGB(c);
    bottomLab.L -= 0.05f * 99.5f / 100;
    ThemeColor expected = oklab::ToSRGB(bottomLab);
    Rgba bottom = ShadeThemePixel(u, 50.5f, 99.5f);
    CHECK(Near(bottom.g, expected.g, 2 / 255.f) && bottom.g < top.g);
}

TEST(twoColoursSitInOppositeCorners) {
    ThemeColor a = ThemeColor::FromHex(0xFF0000), b = ThemeColor::FromHex(0x0000FF);
    ThemeUniforms u = MakeThemeUniforms(Flat({a, b}), 1000, 1000);
    Rgba topLeft = ShadeThemePixel(u, 0.5f, 0.5f), bottomRight = ShadeThemePixel(u, 999.5f, 999.5f);
    CHECK(topLeft.r > topLeft.b && bottomRight.b > bottomRight.r);
    // Equal weights at the centre: the OKLab midpoint of red and blue.
    Lab ra = oklab::FromSRGB(a), rb = oklab::FromSRGB(b);
    ThemeColor mid = oklab::ToSRGB({(ra.L + rb.L) / 2, (ra.a + rb.a) / 2, (ra.b + rb.b) / 2});
    Rgba centre = ShadeThemePixel(u, 500, 500);
    CHECK(Near(centre.r, mid.r, 2 / 255.f) && Near(centre.g, mid.g, 2 / 255.f) && Near(centre.b, mid.b, 2 / 255.f));
}

TEST(crossfadeFollowsProgress) {
    Theme from = Flat({ThemeColor::FromHex(0x000000)}), to = Flat({ThemeColor::FromHex(0xFFFFFF)});
    Rgba start = ShadeThemePixel(MakeThemeUniforms(from, to, 0, 10, 10), 5.5f, 0.5f);
    Rgba end = ShadeThemePixel(MakeThemeUniforms(from, to, 1, 10, 10), 5.5f, 0.5f);
    Rgba same = ShadeThemePixel(MakeThemeUniforms(to, 10, 10), 5.5f, 0.5f);
    CHECK(start.g < 2 / 255.f && end.g > 0.98f);
    CHECK(end.r == same.r && end.g == same.g && end.b == same.b && end.a == same.a);
}

TEST(tintIsTheOpacityAndGrainAddsItsOwn) {
    ThemeColor c = ThemeColor::FromHex(0x808080);
    Rgba clear = ShadeThemePixel(MakeThemeUniforms(Theme::Make({c}, 0, 0), 64, 64), 10.5f, 10.5f);
    CHECK(clear.r == 0 && clear.g == 0 && clear.b == 0 && clear.a == 0);
    Rgba grainOnly = ShadeThemePixel(MakeThemeUniforms(Theme::Make({c}, 1, 0), 64, 64), 10.5f, 10.5f);
    CHECK(Near(grainOnly.a, 0.259f, 1e-6f) && grainOnly.r > 0 && grainOnly.r <= grainOnly.a);
    Rgba half = ShadeThemePixel(MakeThemeUniforms(Theme::Make({c}, 0, 0.55f), 64, 64), 10.5f, 10.5f);
    CHECK(Near(half.a, 0.55f, 1e-6f) && half.r <= half.a);
}

TEST(grainAndDitherAreStablePerPixel) {
    ThemeUniforms u = MakeThemeUniforms(Theme::Presets()[1], 2560, 1640);
    Rgba a = ShadeThemePixel(u, 1234.5f, 567.5f), b = ShadeThemePixel(u, 1234.5f, 567.5f);
    CHECK(a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a);
    // Every preset stays a valid premultiplied colour everywhere.
    for (const Theme& theme : Theme::Presets()) {
        ThemeUniforms p = MakeThemeUniforms(theme, 640, 420);
        for (float y = 0.5f; y < 420; y += 37) {
            for (float x = 0.5f; x < 640; x += 41) {
                Rgba c = ShadeThemePixel(p, x, y);
                CHECK(c.a >= 0 && c.a <= 1 && c.r >= 0 && c.r <= c.a + 1e-6f && c.g <= c.a + 1e-6f && c.b <= c.a + 1e-6f);
            }
        }
    }
}

TEST(overAnOpaqueBaseIsOpaque) {
    Rgba base{0.125f, 0.125f, 0.125f, 1};
    Rgba top{0.25f, 0, 0, 0.5f};
    Rgba out = Over(top, base);
    CHECK(out.a == 1 && Near(out.r, 0.3125f, 1e-6f) && Near(out.g, 0.0625f, 1e-6f));
}

TEST(uniformsNeverDrawAnEmptyOrOversizedPalette) {
    // Theme::Make never makes these, but `colors` is public: no out-of-range read, no black.
    Theme empty;
    empty.colors.clear();
    ThemeUniforms u = MakeThemeUniforms(empty, 100, 100);
    CHECK(u.fromCount == 1);
    Lab fallback = oklab::FromSRGB(Theme{}.colors[0]);
    CHECK(u.fromLab[0][0] == fallback.L && u.fromLab[3][0] == fallback.L);
    Theme many;
    many.colors = std::vector<ThemeColor>(6, ThemeColor::FromHex(0x336699));
    CHECK(MakeThemeUniforms(many, 100, 100).fromCount == 4);
}

TEST(materialFallbackIsWindowsSolidBackdropColours) {
    // Windows 11's own fallback for its backdrops: #202020 dark, #F3F3F3 light, opaque.
    Rgba dark = MaterialFallback(true), light = MaterialFallback(false);
    CHECK(std::lround(dark.r * 255) == 0x20 && dark.r == dark.g && dark.g == dark.b && dark.a == 1);
    CHECK(std::lround(light.r * 255) == 0xF3 && light.r == light.g && light.g == light.b && light.a == 1);
}

namespace {

// The fixture's member `key`; the fixture is ours, so a missing one is a test bug.
const json::Value& At(const json::Value& value, const char* key) {
    static const json::Value null;
    const json::Value* member = value.Find(key);
    return member ? *member : null;
}

Theme ThemeFromJson(const json::Value& value) {
    std::vector<ThemeColor> colors;
    for (const json::Value& c : *At(value, "colors").AsArray()) {
        const json::Array& rgb = *c.AsArray();
        colors.push_back({static_cast<float>(*rgb[0].AsNumber()), static_cast<float>(*rgb[1].AsNumber()),
                          static_cast<float>(*rgb[2].AsNumber())});
    }
    return Theme::Make(std::move(colors), static_cast<float>(*At(value, "grain").AsNumber()), static_cast<float>(*At(value, "tint").AsNumber()));
}

}  // namespace

TEST(referenceMatchesTheGoldenFixtureTheMacChecksKiteMetalAgainst) {
    // Tests/Fixtures/theme-backdrop.json: the Mac's ThemeShaderGoldenTests renders these themes
    // with Kite.metal and compares, so this pins the CPU reference (and, through
    // --backdrop-test, Theme.hlsl) to the Mac's shader. Regenerate with gen-theme-golden only
    // for a deliberate change.
    std::ifstream file(std::filesystem::path(KITE_FIXTURES_DIR) / "theme-backdrop.json", std::ios::binary);
    std::stringstream text;
    text << file.rdbuf();
    auto parsed = json::Parse(text.str());
    CHECK(std::holds_alternative<json::Value>(parsed));
    if (!std::holds_alternative<json::Value>(parsed)) return;
    const json::Value& root = std::get<json::Value>(parsed);
    const json::Array& cases = *At(root, "cases").AsArray();
    CHECK(cases.size() == 6);
    for (const json::Value& c : cases) {
        const json::Array& size = *At(c, "size").AsArray();
        const ThemeUniforms u = MakeThemeUniforms(ThemeFromJson(At(c, "from")), ThemeFromJson(At(c, "to")),
                                                  static_cast<float>(*At(c, "progress").AsNumber()),
                                                  static_cast<float>(*size[0].AsNumber()), static_cast<float>(*size[1].AsNumber()));
        // Another compiler can round the grain hash's last step differently at a pixel or two.
        int off = 0;
        for (const json::Value& sample : *At(c, "samples").AsArray()) {
            const json::Array& v = *sample.AsArray();
            const Rgba p = ShadeThemePixel(u, static_cast<float>(*v[0].AsNumber()) + 0.5f, static_cast<float>(*v[1].AsNumber()) + 0.5f);
            const float expected[4] = {static_cast<float>(*v[2].AsNumber()), static_cast<float>(*v[3].AsNumber()),
                                       static_cast<float>(*v[4].AsNumber()), static_cast<float>(*v[5].AsNumber())};
            const float got[4] = {p.r, p.g, p.b, p.a};
            for (int i = 0; i < 4; ++i) {
                if (!(std::fabs(got[i] - expected[i]) <= 1e-5f)) {
                    ++off;
                    break;
                }
            }
        }
        CHECK(off <= 2);
    }
}
