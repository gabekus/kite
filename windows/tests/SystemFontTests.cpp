// The faces DirectWrite really draws Kite's text formats in (shell/SystemFont): each glyph run of a
// laid-out line, read back through a text renderer. Windows only (it needs Windows' fonts); a
// cross-compile builds it.

#include <windows.h>  // first: the DirectX headers need its types

#include <dwrite_3.h>
#include <wrl/client.h>

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "Check.h"
#include "core/TextWeight.h"
#include "shell/SystemFont.h"

using Microsoft::WRL::ComPtr;
using namespace kite;
namespace W = kite::text_weight;

namespace {

struct Run {
    std::wstring family;  // the face's weight-stretch-style family name
    int weight = 0;       // its DWRITE_FONT_WEIGHT
    float wght = -1;      // its weight-axis value, for a variable face
};

// Records each glyph run's face.
class Recorder final : public IDWriteTextRenderer {
public:
    std::vector<Run> runs;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWritePixelSnapping) || riid == __uuidof(IDWriteTextRenderer)) {
            *out = static_cast<IDWriteTextRenderer*>(this);
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* disabled) override {
        *disabled = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* transform) override {
        *transform = DWRITE_MATRIX{1, 0, 0, 1, 0, 0};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* pixels) override {
        *pixels = 1;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*, FLOAT, FLOAT, DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN* glyphs,
                                           const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override {
        Run run;
        ComPtr<IDWriteFontFace3> face;
        if (glyphs->fontFace && SUCCEEDED(glyphs->fontFace->QueryInterface(IID_PPV_ARGS(face.GetAddressOf())))) {
            run.weight = face->GetWeight();
            ComPtr<IDWriteLocalizedStrings> names;
            UINT32 index = 0;
            BOOL exists = FALSE;
            if (SUCCEEDED(face->GetFamilyNames(names.GetAddressOf())) && SUCCEEDED(names->FindLocaleName(L"en-us", &index, &exists))) {
                UINT32 length = 0;
                names->GetStringLength(exists ? index : 0, &length);
                run.family.resize(length + 1);
                names->GetString(exists ? index : 0, run.family.data(), length + 1);
                run.family.resize(length);
            }
            ComPtr<IDWriteFontFace5> variable;
            if (SUCCEEDED(face.As(&variable)) && variable->HasVariations()) {
                DWRITE_FONT_AXIS_VALUE axes[8]{};
                const UINT32 count = variable->GetFontAxisValueCount();
                if (count <= 8 && SUCCEEDED(variable->GetFontAxisValues(axes, count))) {
                    for (UINT32 i = 0; i < count; ++i) {
                        if (axes[i].axisTag == DWRITE_FONT_AXIS_TAG_WEIGHT) run.wght = axes[i].value;
                    }
                }
            }
        }
        runs.push_back(run);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL, IUnknown*) override { return S_OK; }
};

ComPtr<IDWriteFactory> Factory() {
    ComPtr<IDWriteFactory> factory;
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(factory.GetAddressOf()));
    return factory;
}

std::vector<Run> Faces(IDWriteTextFormat* format, const std::wstring& text) {
    Recorder recorder;
    ComPtr<IDWriteTextLayout> layout;
    if (SUCCEEDED(Factory()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 10000, 1000, layout.GetAddressOf()))) {
        layout->Draw(nullptr, &recorder, 0, 0);
    }
    return recorder.runs;
}

std::vector<Run> KiteFaces(MacWeight weight, float size, const std::wstring& text) {
    ComPtr<IDWriteTextFormat> format;
    if (FAILED(system_font::CreateTextFormat(Factory().Get(), weight, size, format))) return {};
    return Faces(format.Get(), text);
}

// What DirectWrite's own fallback picks for `text` at the Mac's weight: a plain Segoe UI format at
// 400, 500, 600 or 700.
std::vector<Run> MacWeightFaces(MacWeight weight, float size, const std::wstring& text) {
    ComPtr<IDWriteTextFormat> format;
    if (FAILED(Factory()->CreateTextFormat(L"Segoe UI", nullptr, static_cast<DWRITE_FONT_WEIGHT>(W::MacWeightValue(weight)), DWRITE_FONT_STYLE_NORMAL,
                                           DWRITE_FONT_STRETCH_NORMAL, size, L"", format.GetAddressOf()))) {
        return {};
    }
    return Faces(format.Get(), text);
}

bool Installed(const wchar_t* family) {
    ComPtr<IDWriteFontCollection> fonts;
    UINT32 index = 0;
    BOOL exists = FALSE;
    return SUCCEEDED(Factory()->GetSystemFontCollection(fonts.GetAddressOf())) && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) &&
           exists;
}

std::string Narrow(const std::wstring& text) {
    std::string out;
    for (const wchar_t c : text) out.push_back(c < 0x80 ? static_cast<char>(c) : '?');
    return out;
}

// Japanese, Korean, Thai, Hindi and Arabic, with no spaces (a space is Latin, in the base face).
const std::wstring kScripts[] = {L"日本語の文字", L"한국어", L"ภาษาไทย",
                                 L"हिन्दी", L"العربية"};

// Every script's runs at every weight are the faces the Mac's own weight picks.
void CheckOtherScripts(const char* face) {
    for (const MacWeight weight : W::kAllWeights) {
        for (const std::wstring& text : kScripts) {
            for (const float size : {11.0f, 13.0f, 17.0f}) {
                const std::vector<Run> kite = KiteFaces(weight, size, text), mac = MacWeightFaces(weight, size, text);
                CHECK(!kite.empty() && kite.size() == mac.size());
                for (size_t i = 0; i < kite.size() && i < mac.size(); ++i) {
                    const bool same = kite[i].family == mac[i].family && kite[i].weight == mac[i].weight;
                    if (!same) {
                        std::fprintf(stderr, "  %s, %s %.0fpt: %s %d, not %s %d\n", face, std::string(W::Name(weight)).c_str(), size,
                                     Narrow(kite[i].family).c_str(), kite[i].weight, Narrow(mac[i].family).c_str(), mac[i].weight);
                    }
                    CHECK(same);
                }
            }
        }
    }
    // The reviewer's case: a regular label's Japanese in Yu Gothic UI Regular, not Semibold.
    if (Installed(L"Yu Gothic UI")) {
        const std::vector<Run> japanese = KiteFaces(MacWeight::Regular, 13, kScripts[0]);
        CHECK(!japanese.empty() && japanese[0].family == L"Yu Gothic UI" && japanese[0].weight == 400);
    }
}

}  // namespace

TEST(textInEveryFaceKeepsTheMappingAndOtherScriptsFallBackAtTheMacsWeight) {
    if (system_font::Current() == system_font::Face::Variable) {
        // Latin on Segoe UI Variable's axes (bold in Segoe UI Black).
        const std::vector<Run> regular = KiteFaces(MacWeight::Regular, 14, L"Kite");
        CHECK(regular.size() == 1 && regular[0].family.rfind(L"Segoe UI Variable", 0) == 0 && std::fabs(regular[0].wght - 590) < 0.5f);
        const std::vector<Run> semibold = KiteFaces(MacWeight::Semibold, 13, L"Kite");
        CHECK(semibold.size() == 1 && std::fabs(semibold[0].wght - 675) < 0.5f);
        const std::vector<Run> bold = KiteFaces(MacWeight::Bold, 17, L"Kite");
        CHECK(bold.size() == 1 && bold[0].family.rfind(L"Segoe UI", 0) == 0 && bold[0].wght < 0 && bold[0].weight == W::kBoldBlackWeight);
        CheckOtherScripts("Windows 11");
    } else {
        std::printf("  (no Segoe UI Variable with its axes here: Windows 10's face only)\n");
    }
    // Windows 10's face: Segoe UI's named weights for Latin, the Mac's weight for the rest.
    system_font::UseStaticForTesting();
    for (const MacWeight weight : W::kAllWeights) {
        const std::vector<Run> latin = KiteFaces(weight, 13, L"Kite");
        CHECK(latin.size() == 1 && latin[0].family.rfind(L"Segoe UI", 0) == 0 && latin[0].weight == W::StaticWeight(weight));
    }
    CheckOtherScripts("Windows 10");
}
