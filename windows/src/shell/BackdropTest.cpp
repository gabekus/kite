// See BackdropTest.h.

#include "shell/BackdropTest.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <vector>

#include "core/OKLab.h"
#include "core/ThemeBackdrop.h"
#include "shell/Renderer.h"

namespace kite {
namespace {

struct Case {
    std::wstring name;
    ThemeUniforms uniforms;
    Rgba base;
    UINT width, height;
};

int Quantize(float v) { return static_cast<int>(std::lround(std::clamp(v, 0.f, 1.f) * 255.f)); }

}  // namespace

std::wstring RunBackdropTest(std::wstring& report) {
    std::wstring error;
    auto renderer = Renderer::Create(error);
    if (!renderer) return error;
    report += renderer->IsSoftware() ? L"device: WARP (software)\n" : L"device: hardware\n";

    std::vector<Case> cases;
    const auto& presets = Theme::Presets();
    for (size_t i = 0; i < presets.size(); ++i) {
        const bool dark = !PrefersDarkForeground(presets[i]);
        for (UINT scale : {1u, 2u}) {
            const UINT w = 640 * scale, h = 420 * scale;
            cases.push_back({L"preset " + std::to_wstring(i) + L" @" + std::to_wstring(scale) + L"x",
                             MakeThemeUniforms(presets[i], static_cast<float>(w), static_cast<float>(h)), MaterialFallback(dark), w, h});
        }
    }
    cases.push_back({L"crossfade 1 -> 6 at 0.4", MakeThemeUniforms(presets[1], presets[6], 0.4f, 800, 500), MaterialFallback(true), 800, 500});
    cases.push_back({L"transparent base (Windows 11 backdrop)", MakeThemeUniforms(presets[2], 640, 420), Rgba{}, 640, 420});

    std::wstring failures;
    for (const Case& c : cases) {
        auto pixels = renderer->RenderTheme(c.width, c.height, c.uniforms, c.base, error);
        if (!pixels) return c.name + L": " + error;
        size_t outliers = 0;
        int worst = 0;
        double total = 0;
        for (UINT y = 0; y < c.height; ++y) {
            for (UINT x = 0; x < c.width; ++x) {
                const Rgba expected = Over(ShadeThemePixel(c.uniforms, x + 0.5f, y + 0.5f), c.base);
                const uint8_t* p = pixels->bgra.data() + (static_cast<size_t>(y) * c.width + x) * 4;
                const int diffs[4] = {std::abs(p[2] - Quantize(expected.r)), std::abs(p[1] - Quantize(expected.g)),
                                      std::abs(p[0] - Quantize(expected.b)), std::abs(p[3] - Quantize(expected.a))};
                const int diff = *std::max_element(std::begin(diffs), std::end(diffs));
                worst = std::max(worst, diff);
                total += diffs[0] + diffs[1] + diffs[2] + diffs[3];
                // Two levels covers float differences between GPU and CPU; more means the grain or
                // dither hash landed on the other side of a fract() boundary, which is rare.
                if (diff > 2) ++outliers;
            }
        }
        const double count = static_cast<double>(c.width) * c.height;
        const double outlierShare = outliers / count;
        const double mean = total / (count * 4);
        wchar_t line[256];
        std::swprintf(line, std::size(line), L"%ls: %ux%u, mean |diff| %.3f, worst %d, %.3f%% over 2 levels\n", c.name.c_str(),
                      c.width, c.height, mean, worst, outlierShare * 100);
        report += line;
        if (outlierShare > 0.005 || mean > 0.6) failures += line;
    }
    return failures;
}

}  // namespace kite
