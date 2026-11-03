// Writes Tests/Fixtures/theme-backdrop.json: the theme backdrop's colour at a grid of pixels for
// a few themes, from core's CPU reference of Kite.metal (core/ThemeBackdrop.h).
//
//   cmake --build <dir> --target gen-theme-golden && <dir>/gen-theme-golden > Tests/Fixtures/theme-backdrop.json
//
// Both suites read the file: the Windows tests pin the CPU reference (and through
// --backdrop-test, Theme.hlsl) to it, and the Mac's ThemeShaderGoldenTests renders the same
// themes with Kite.metal and checks it agrees. That's what ties the Windows port to the Mac's
// shader rather than to a second reading of it. Regenerate only on a deliberate shader change.

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "core/Json.h"
#include "core/Models.h"
#include "core/ThemeBackdrop.h"

using namespace kite;

namespace {

struct Case {
    std::string name;
    Theme from, to;
    float progress;
    int width, height;
};

json::Value ThemeJson(const Theme& theme) {
    json::Array colors;
    for (const ThemeColor& c : theme.colors) {
        colors.push_back(json::Value(json::Array{json::Value(c.r), json::Value(c.g), json::Value(c.b)}));
    }
    return json::Value(json::Object{
        {"colors", json::Value(std::move(colors))}, {"grain", json::Value(theme.grain)}, {"tint", json::Value(theme.tint)}});
}

}  // namespace

int main() {
    auto hex = [](std::initializer_list<uint32_t> values) {
        std::vector<ThemeColor> colors;
        for (uint32_t v : values) colors.push_back(ThemeColor::FromHex(v));
        return colors;
    };
    const Theme one = Theme::Make(hex({0x5FD3E6}), 0, 1);
    const Theme work = Theme::Make(hex({0xFF9A6C, 0xF0629B}));
    const Theme three = Theme::Make(hex({0xFF9A6C, 0xF0629B, 0x8A5CF5}));
    const Theme four = Theme::Make(hex({0xFF9A6C, 0xF0629B, 0x8A5CF5, 0x5FD3E6}), 0.6f, 0.9f);
    const Theme fadedOne = Theme::Make(hex({0x2E6BE6}), 0, 0.3f);
    const Theme dark = Theme::Make(hex({0x1E1E2E}));
    // Channels at or near 0, so sRGB's linear segment (c <= 0.0031308) is drawn too.
    const Theme saturated = Theme::Make(hex({0xFF0000, 0x050505, 0x0000FF}), 0, 1);
    const std::vector<Case> cases = {
        {"one colour, no grain, opaque", one, one, 1, 300, 300},
        {"two colours", work, work, 1, 1280, 820},
        {"three colours at 2x", three, three, 1, 1280, 840},
        {"four colours, grain 0.6, tint 0.9", four, four, 1, 800, 500},
        {"crossfade one colour to four at 0.4", fadedOne, four, 0.4f, 800, 500},
        {"dark single colour with grain", dark, dark, 1, 640, 420},
        {"saturated red, near-black and blue, opaque", saturated, saturated, 1, 640, 420},
    };

    // Written by hand rather than json::Write, one sample a line, so a regenerated file diffs
    // readably. %.9g round-trips a float.
    constexpr int kColumns = 16, kRows = 10;
    std::printf("{\n  \"about\": \"The theme backdrop (Kite.metal's kite_theme_fragment) at pixel centres x+0.5, y+0.5: "
                "premultiplied RGBA before the material. Samples are [x, y, r, g, b, a]. Written by "
                "windows/tests/GenThemeGolden.cpp.\",\n  \"cases\": [\n");
    for (size_t i = 0; i < cases.size(); ++i) {
        const Case& c = cases[i];
        const ThemeUniforms u = MakeThemeUniforms(c.from, c.to, c.progress, static_cast<float>(c.width), static_cast<float>(c.height));
        std::printf("    {\n      \"name\": \"%s\",\n      \"from\": %s,\n      \"to\": %s,\n", c.name.c_str(),
                    json::Write(ThemeJson(c.from)).c_str(), json::Write(ThemeJson(c.to)).c_str());
        std::printf("      \"progress\": %.9g,\n      \"size\": [%d, %d],\n      \"samples\": [\n", c.progress, c.width, c.height);
        for (int row = 0; row < kRows; ++row) {
            for (int column = 0; column < kColumns; ++column) {
                const int x = static_cast<int>(std::floor((column + 0.5) * c.width / kColumns));
                const int y = static_cast<int>(std::floor((row + 0.5) * c.height / kRows));
                const Rgba p = ShadeThemePixel(u, x + 0.5f, y + 0.5f);
                const bool last = row == kRows - 1 && column == kColumns - 1;
                std::printf("        [%d, %d, %.9g, %.9g, %.9g, %.9g]%s\n", x, y, p.r, p.g, p.b, p.a, last ? "" : ",");
            }
        }
        std::printf("      ]\n    }%s\n", i + 1 == cases.size() ? "" : ",");
    }
    std::printf("  ]\n}\n");
}
