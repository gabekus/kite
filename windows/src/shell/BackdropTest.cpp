// See BackdropTest.h.

#include "shell/BackdropTest.h"

#include <algorithm>
#include <cmath>
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

// The GPU and CPU agree to about 1e-6 on CI's software adapter (mean 3e-8, worst 1.4e-6);
// the Mac's own Kite.metal is within 1.6e-5 of the same reference on an Apple GPU, so a
// hardware GPU's exp and pow get the same room. A channel off by more than kTolerance is an
// outlier: half the ±0.5/255 dither, so dropping the dither fails, as does a misplaced grain.
// A missed row or column of the smallest case (333×217: 1/333 of it) is more than
// kMaxOutlierShare.
constexpr double kTolerance = 1e-3;
constexpr double kMaxOutlierShare = 0.0005;
constexpr double kMaxMeanDifference = 1e-4;

}  // namespace

BackdropTestOutcome RunBackdropTest(std::wstring& report, std::wstring& problem) {
    auto renderer = Renderer::Create(problem);
    if (!renderer) return BackdropTestOutcome::CouldNotRun;
    report += L"device: " + renderer->AdapterName() + (renderer->IsSoftware() ? L" (software)\n" : L" (GPU)\n");

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
    // A crossfade between themes that differ in everything the shader mixes: colour count,
    // grain and tint, both ways.
    const Theme one = Theme::Make({ThemeColor::FromHex(0x2E6BE6)}, 0, 0.3f);
    const Theme four = Theme::Make({ThemeColor::FromHex(0xFF9A6C), ThemeColor::FromHex(0xF0629B), ThemeColor::FromHex(0x8A5CF5),
                                    ThemeColor::FromHex(0x5FD3E6)},
                                   0.6f, 0.9f);
    cases.push_back({L"crossfade 1 colour -> 4 at 0.4", MakeThemeUniforms(one, four, 0.4f, 800, 500), MaterialFallback(true), 800, 500});
    cases.push_back({L"crossfade 4 colours -> 1 at 0.7", MakeThemeUniforms(four, one, 0.7f, 800, 500), MaterialFallback(false), 800, 500});
    // Channels at or near 0, so sRGB's linear segment is drawn too.
    const Theme saturated = Theme::Make({ThemeColor::FromHex(0xFF0000), ThemeColor::FromHex(0x050505), ThemeColor::FromHex(0x0000FF)}, 0, 1);
    cases.push_back({L"saturated red, near-black and blue", MakeThemeUniforms(saturated, 640, 420), MaterialFallback(true), 640, 420});
    cases.push_back({L"odd size 333x217", MakeThemeUniforms(presets[3], 333, 217), MaterialFallback(true), 333, 217});
    cases.push_back({L"transparent base (Windows 11 backdrop)", MakeThemeUniforms(presets[2], 640, 420), Rgba{}, 640, 420});

    for (const Case& c : cases) {
        std::wstring error;
        auto pixels = renderer->RenderTheme(c.width, c.height, c.uniforms, c.base, error);
        if (!pixels) {
            problem = c.name + L": " + error;
            return BackdropTestOutcome::CouldNotRun;
        }
        size_t outliers = 0;
        double worst = 0, total = 0;
        for (UINT y = 0; y < c.height; ++y) {
            for (UINT x = 0; x < c.width; ++x) {
                const Rgba expected = Over(ShadeThemePixel(c.uniforms, x + 0.5f, y + 0.5f), c.base);
                const float* p = pixels->data() + (static_cast<size_t>(y) * c.width + x) * 4;
                const double diffs[4] = {std::fabs(p[0] - expected.r), std::fabs(p[1] - expected.g), std::fabs(p[2] - expected.b),
                                         std::fabs(p[3] - expected.a)};
                const double diff = *std::max_element(std::begin(diffs), std::end(diffs));
                worst = std::max(worst, diff);
                total += diffs[0] + diffs[1] + diffs[2] + diffs[3];
                if (!(diff <= kTolerance)) ++outliers;  // NaN counts
            }
        }
        const double count = static_cast<double>(c.width) * c.height;
        const double outlierShare = outliers / count;
        const double mean = total / (count * 4);
        wchar_t line[256];
        std::swprintf(line, std::size(line), L"%ls: %ux%u, mean |diff| %.2e, worst %.2e, %.4f%% over %.0e\n", c.name.c_str(), c.width,
                      c.height, mean, worst, outlierShare * 100, kTolerance);
        report += line;
        if (outlierShare > kMaxOutlierShare || !(mean <= kMaxMeanDifference)) problem += line;
    }
    return problem.empty() ? BackdropTestOutcome::Matches : BackdropTestOutcome::Differs;
}

}  // namespace kite
