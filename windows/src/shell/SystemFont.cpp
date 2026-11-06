#include "shell/SystemFont.h"

#include <dwrite_3.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <iterator>
#include <mutex>

using Microsoft::WRL::ComPtr;

namespace kite::system_font {

namespace {

namespace W = text_weight;

// DirectWrite's typographic family, whose optical sizes are one family (GDI and DirectWrite's
// weight-stretch-style model split them into "Segoe UI Variable Small", "Text" and "Display",
// each with its opsz fixed, so only the typographic name takes an optical size).
constexpr wchar_t kVariableFamily[] = L"Segoe UI Variable";
constexpr wchar_t kVariableGdiFamily[] = L"Segoe UI Variable Text";
constexpr wchar_t kStaticFamily[] = L"Segoe UI";

std::atomic<bool> forcedStatic{false};

ComPtr<IDWriteFactory> SharedFactory() {
    ComPtr<IDWriteFactory> factory;
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(factory.GetAddressOf()));
    return factory;
}

bool Installed(const wchar_t* family) {
    const ComPtr<IDWriteFactory> factory = SharedFactory();
    ComPtr<IDWriteFontCollection> fonts;
    UINT32 index = 0;
    BOOL exists = FALSE;
    return factory && SUCCEEDED(factory->GetSystemFontCollection(fonts.GetAddressOf())) && fonts &&
           SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
}

// Segoe UI Variable's font resource, when DirectWrite can set its axes (IDWriteFactory6, from
// Windows 10 2004) and it has both of the axes the mapping sets, over their whole ranges.
ComPtr<IDWriteFontResource> FindVariable() {
    ComPtr<IDWriteFactory6> factory;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory6), reinterpret_cast<IUnknown**>(factory.GetAddressOf())))) {
        return nullptr;
    }
    ComPtr<IDWriteFontCollection2> fonts;
    ComPtr<IDWriteFontFamily2> family;
    ComPtr<IDWriteFont3> font;
    ComPtr<IDWriteFontFace3> face;
    ComPtr<IDWriteFontFace5> variable;
    ComPtr<IDWriteFontResource> resource;
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (FAILED(factory->GetSystemFontCollection(FALSE, DWRITE_FONT_FAMILY_MODEL_TYPOGRAPHIC, fonts.GetAddressOf())) ||
        FAILED(fonts->FindFamilyName(kVariableFamily, &index, &exists)) || !exists ||
        FAILED(fonts->GetFontFamily(index, family.GetAddressOf())) || family->GetFontCount() == 0 ||
        FAILED(family->GetFont(0, font.GetAddressOf())) || FAILED(font->CreateFontFace(face.GetAddressOf())) || FAILED(face.As(&variable)) ||
        FAILED(variable->GetFontResource(resource.GetAddressOf()))) {
        return nullptr;
    }
    const UINT32 count = resource->GetFontAxisCount();
    if (count == 0 || count > 16) return nullptr;
    DWRITE_FONT_AXIS_RANGE ranges[16]{};
    if (FAILED(resource->GetFontAxisRanges(ranges, count))) return nullptr;
    bool weight = false, opticalSize = false;
    for (UINT32 i = 0; i < count; ++i) {
        if (ranges[i].axisTag == DWRITE_FONT_AXIS_TAG_WEIGHT) {
            weight = ranges[i].minValue <= W::kRegularAxis - W::kRegularGiveBack * (W::kTextOpticalSize - W::kMinOpticalSize) &&
                     ranges[i].maxValue >= W::kMaxWeightAxis;
        }
        if (ranges[i].axisTag == DWRITE_FONT_AXIS_TAG_OPTICAL_SIZE) {
            opticalSize = ranges[i].minValue <= W::kMinOpticalSize && ranges[i].maxValue >= W::kTextOpticalSize;
        }
    }
    return weight && opticalSize ? resource : nullptr;
}

const ComPtr<IDWriteFontResource>& Variable() {
    static const ComPtr<IDWriteFontResource> resource = FindVariable();
    return resource;
}

// Segoe UI's Black (seguibl.ttf, in Windows since Windows 8), Windows 11's bold.
bool HasBlack() {
    static const bool black = [] {
        const ComPtr<IDWriteFactory> factory = SharedFactory();
        ComPtr<IDWriteFontCollection> fonts;
        ComPtr<IDWriteFontFamily> family;
        ComPtr<IDWriteFont> font;
        UINT32 index = 0;
        BOOL exists = FALSE;
        return factory && SUCCEEDED(factory->GetSystemFontCollection(fonts.GetAddressOf())) &&
               SUCCEEDED(fonts->FindFamilyName(kStaticFamily, &index, &exists)) && exists &&
               SUCCEEDED(fonts->GetFontFamily(index, family.GetAddressOf())) &&
               SUCCEEDED(family->GetFirstMatchingFont(static_cast<DWRITE_FONT_WEIGHT>(W::kBoldBlackWeight), DWRITE_FONT_STRETCH_NORMAL,
                                                      DWRITE_FONT_STYLE_NORMAL, font.GetAddressOf())) &&
               font->GetWeight() >= W::kBoldBlackWeight - 50 && font->GetSimulations() == DWRITE_FONT_SIMULATIONS_NONE;
    }();
    return black;
}

// Whether `weight` is drawn on Segoe UI's named weights, and at which: Windows 10's, or Windows
// 11's bold in Black.
bool NamedOnly(MacWeight weight, int& named) {
    if (Current() == Face::Variable) {
        if (!W::Windows11UsesBlack(weight) || !HasBlack()) return false;
        named = W::kBoldBlackWeight;
        return true;
    }
    named = W::StaticWeight(weight);
    return true;
}

void AxesFor(MacWeight weight, float size, DWRITE_FONT_AXIS_VALUE (&axes)[2]) {
    const W::VariableSetting setting = W::Variable(weight, size);
    axes[0] = {DWRITE_FONT_AXIS_TAG_WEIGHT, setting.weight};
    axes[1] = {DWRITE_FONT_AXIS_TAG_OPTICAL_SIZE, setting.opticalSize};
}

// What the mapping's weights were measured on: SF Pro's and Segoe UI Variable's scripts (Latin,
// Greek, Cyrillic), their marks, and the punctuation and symbols around them. Anything else is
// drawn by a fallback font (Yu Gothic UI, Malgun Gothic, Leelawadee UI, Nirmala UI, Segoe UI's
// Arabic, Segoe UI Emoji), whose weights are their own.
bool Tuned(char32_t c) {
    return c < 0x0530 || (c >= 0x1D00 && c < 0x2C00) || (c >= 0x2C60 && c < 0x2C80) || (c >= 0x2DE0 && c < 0x2E80) ||
           (c >= 0xA640 && c < 0xA6A0) || (c >= 0xA720 && c < 0xA800) || (c >= 0xAB30 && c < 0xAB70) || (c >= 0xFB00 && c < 0xFB07);
}

// How much of [position, position + length) is of one kind, tuned or not (at most what the
// source hands over in one piece; DirectWrite asks again for the rest).
UINT32 SameKind(IDWriteTextAnalysisSource* source, UINT32 position, UINT32 length, bool& tuned) {
    const WCHAR* text = nullptr;
    UINT32 available = 0;
    tuned = true;
    if (FAILED(source->GetTextAtPosition(position, &text, &available)) || !text || available == 0) return length;
    available = std::min(available, length);
    UINT32 i = 0;
    while (i < available) {
        char32_t c = text[i];
        UINT32 units = 1;
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < available && text[i + 1] >= 0xDC00 && text[i + 1] < 0xE000) {
            c = 0x10000 + ((c - 0xD800) << 10) + (static_cast<char32_t>(text[i + 1]) - 0xDC00);
            units = 2;
        }
        const bool kind = Tuned(c);
        if (i == 0) tuned = kind;
        else if (kind != tuned) break;
        i += units;
    }
    return i;
}

// The system's font fallback, but other scripts get the Mac's own weight: DirectWrite picks the
// fallback face with the format's weight-axis value (or its named weight on Windows 10), which
// would draw Japanese in Yu Gothic UI Semibold for a regular label at 590. Characters the mapping
// was measured on keep the format's values, axes and all.
class MacWeightFallback final : public IDWriteFontFallback1 {
public:
    MacWeightFallback(ComPtr<IDWriteFontFallback> system, MacWeight weight)
        : system_(std::move(system)), weight_(static_cast<float>(W::MacWeightValue(weight))) {
        system_.As(&system1_);
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWriteFontFallback) || (riid == __uuidof(IDWriteFontFallback1) && system1_)) {
            *out = static_cast<IDWriteFontFallback1*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&references_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG left = InterlockedDecrement(&references_);
        if (left == 0) delete this;
        return static_cast<ULONG>(left);
    }

    HRESULT STDMETHODCALLTYPE MapCharacters(IDWriteTextAnalysisSource* source, UINT32 position, UINT32 length, IDWriteFontCollection* fonts,
                                            const WCHAR* family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style, DWRITE_FONT_STRETCH stretch,
                                            UINT32* mapped, IDWriteFont** font, FLOAT* scale) override {
        bool tuned = true;
        const UINT32 run = SameKind(source, position, length, tuned);
        return system_->MapCharacters(source, position, run, fonts, family, tuned ? weight : static_cast<DWRITE_FONT_WEIGHT>(std::lround(weight_)),
                                      style, stretch, mapped, font, scale);
    }

    HRESULT STDMETHODCALLTYPE MapCharacters(IDWriteTextAnalysisSource* source, UINT32 position, UINT32 length, IDWriteFontCollection* fonts,
                                            const WCHAR* family, const DWRITE_FONT_AXIS_VALUE* axes, UINT32 count, UINT32* mapped, FLOAT* scale,
                                            IDWriteFontFace5** face) override {
        if (!system1_) return E_NOTIMPL;
        bool tuned = true;
        const UINT32 run = SameKind(source, position, length, tuned);
        if (tuned) return system1_->MapCharacters(source, position, run, fonts, family, axes, count, mapped, scale, face);
        // Matched by the named weight, as a plain format at the Mac's weight is (the weight axis
        // would match a medium's 500 down to Regular, where the named weight's matching, Windows
        // 10's and a plain format's, takes Semibold).
        *face = nullptr;
        ComPtr<IDWriteFont> font;
        HRESULT hr = system_->MapCharacters(source, position, run, fonts, family, static_cast<DWRITE_FONT_WEIGHT>(std::lround(weight_)),
                                            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, mapped, font.GetAddressOf(), scale);
        if (FAILED(hr) || !font) return hr;
        ComPtr<IDWriteFontFace> mappedFace;
        if (SUCCEEDED(hr = font->CreateFontFace(mappedFace.GetAddressOf()))) hr = mappedFace->QueryInterface(IID_PPV_ARGS(face));
        return hr;
    }

private:
    ~MacWeightFallback() = default;

    ComPtr<IDWriteFontFallback> system_;
    ComPtr<IDWriteFontFallback1> system1_;
    float weight_;
    LONG references_ = 1;
};

// One per Mac weight, over the system's fallback (none before Windows 8.1's IDWriteFactory2).
ComPtr<IDWriteFontFallback> FallbackFor(IDWriteFactory* dwrite, MacWeight weight) {
    static std::mutex lock;
    static ComPtr<IDWriteFontFallback> made[std::size(W::kAllWeights)];
    const size_t index = static_cast<size_t>(weight);
    const std::lock_guard<std::mutex> hold(lock);
    if (!made[index]) {
        ComPtr<IDWriteFactory2> factory;
        ComPtr<IDWriteFontFallback> system;
        if (FAILED(dwrite->QueryInterface(IID_PPV_ARGS(factory.GetAddressOf()))) || FAILED(factory->GetSystemFontFallback(system.GetAddressOf()))) {
            return nullptr;
        }
        made[index].Attach(new MacWeightFallback(std::move(system), weight));
    }
    return made[index];
}

// Other scripts in `out` fall back at the Mac's weight. Without IDWriteTextFormat1 (before
// Windows 8.1) the system's own fallback stays.
HRESULT UseMacWeightFallback(IDWriteFactory* dwrite, MacWeight weight, IDWriteTextFormat* out) {
    ComPtr<IDWriteTextFormat1> format;
    const ComPtr<IDWriteFontFallback> fallback = FallbackFor(dwrite, weight);
    if (!fallback || FAILED(out->QueryInterface(IID_PPV_ARGS(format.GetAddressOf())))) return S_OK;
    return format->SetFontFallback(fallback.Get());
}

}  // namespace

Face Current() { return !forcedStatic && Variable() ? Face::Variable : Face::Static; }

void UseStaticForTesting() { forcedStatic = true; }

HRESULT CreateTextFormat(IDWriteFactory* dwrite, MacWeight weight, float size, ComPtr<IDWriteTextFormat>& out) {
    out.Reset();
    int named = 0;
    if (!NamedOnly(weight, named)) {
        DWRITE_FONT_AXIS_VALUE axes[2];
        AxesFor(weight, size, axes);
        // The named weight is only what DirectWrite matches before the axes apply (and what the
        // format reports); the axis values set the face.
        HRESULT hr = dwrite->CreateTextFormat(kVariableFamily, nullptr, static_cast<DWRITE_FONT_WEIGHT>(std::lround(axes[0].value)),
                                              DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
        ComPtr<IDWriteTextFormat3> variable;
        if (SUCCEEDED(hr)) hr = out.As(&variable);
        if (SUCCEEDED(hr)) hr = variable->SetFontAxisValues(axes, 2);
        if (SUCCEEDED(hr)) hr = UseMacWeightFallback(dwrite, weight, out.Get());
        if (SUCCEEDED(hr)) return hr;
        out.Reset();  // the axes didn't take: Segoe UI's named weights, as on Windows 10
        named = W::StaticWeight(weight);
    }
    HRESULT hr = dwrite->CreateTextFormat(kStaticFamily, nullptr, static_cast<DWRITE_FONT_WEIGHT>(named), DWRITE_FONT_STYLE_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
    if (SUCCEEDED(hr)) hr = UseMacWeightFallback(dwrite, weight, out.Get());
    if (FAILED(hr)) out.Reset();
    return hr;
}

HRESULT CopyTextFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, float size, ComPtr<IDWriteTextFormat>& out) {
    out.Reset();
    wchar_t family[64]{};
    wchar_t locale[LOCALE_NAME_MAX_LENGTH]{};
    HRESULT hr = format->GetFontFamilyName(family, static_cast<UINT32>(std::size(family)));
    if (SUCCEEDED(hr)) hr = format->GetLocaleName(locale, static_cast<UINT32>(std::size(locale)));
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextFormat(family, nullptr, format->GetFontWeight(), format->GetFontStyle(), format->GetFontStretch(), size, locale,
                                      out.GetAddressOf());
    }
    ComPtr<IDWriteTextFormat3> from, to;
    if (SUCCEEDED(hr) && SUCCEEDED(format->QueryInterface(IID_PPV_ARGS(from.GetAddressOf())))) {
        const UINT32 count = from->GetFontAxisValueCount();
        if (count > 0) {
            DWRITE_FONT_AXIS_VALUE axes[8]{};
            if (count > std::size(axes)) return E_UNEXPECTED;
            hr = from->GetFontAxisValues(axes, count);
            if (SUCCEEDED(hr)) hr = out.As(&to);
            if (SUCCEEDED(hr)) hr = to->SetFontAxisValues(axes, count);
        }
    }
    // And its fallback, which gives other scripts the Mac's weight.
    ComPtr<IDWriteTextFormat1> from1, to1;
    ComPtr<IDWriteFontFallback> fallback;
    if (SUCCEEDED(hr) && SUCCEEDED(format->QueryInterface(IID_PPV_ARGS(from1.GetAddressOf()))) &&
        SUCCEEDED(from1->GetFontFallback(fallback.GetAddressOf())) && fallback) {
        hr = out.As(&to1);
        if (SUCCEEDED(hr)) hr = to1->SetFontFallback(fallback.Get());
    }
    if (FAILED(hr)) out.Reset();
    return hr;
}

const wchar_t* GdiFaceName() { return Current() == Face::Variable ? kVariableGdiFamily : kStaticFamily; }

LONG GdiWeight(MacWeight weight, float size) {
    if (Current() == Face::Static) return W::StaticWeight(weight);
    if (W::Windows11UsesBlack(weight)) return 700;  // GDI's face is Segoe UI Variable Text's Bold
    // GDI has the Text instance's named weights: Light, Semilight, Regular, Semibold and Bold.
    constexpr LONG kNamed[] = {300, 350, 400, 600, 700};
    const float wght = W::Variable(weight, size).weight;
    LONG nearest = kNamed[0];
    for (const LONG named : kNamed) {
        if (std::fabs(static_cast<float>(named) - wght) < std::fabs(static_cast<float>(nearest) - wght)) nearest = named;
    }
    return nearest;
}

float CapHeight(IDWriteFactory* dwrite, MacWeight weight, float size) {
    DWRITE_FONT_METRICS metrics{};
    bool found = false;
    int named = 0;
    const bool namedOnly = NamedOnly(weight, named);
    if (!namedOnly) {
        DWRITE_FONT_AXIS_VALUE axes[2];
        AxesFor(weight, size, axes);
        ComPtr<IDWriteFontFace5> face;
        if (SUCCEEDED(Variable()->CreateFontFace(DWRITE_FONT_SIMULATIONS_NONE, axes, 2, face.GetAddressOf()))) {
            DWRITE_FONT_METRICS1 variable{};  // IDWriteFontFace1's overload, as MinGW's headers have it alone
            face->GetMetrics(&variable);
            metrics.designUnitsPerEm = variable.designUnitsPerEm;
            metrics.capHeight = variable.capHeight;
            found = true;
        }
    }
    if (!found) {
        ComPtr<IDWriteFontCollection> fonts;
        ComPtr<IDWriteFontFamily> family;
        ComPtr<IDWriteFont> font;
        UINT32 index = 0;
        BOOL exists = FALSE;
        if (SUCCEEDED(dwrite->GetSystemFontCollection(fonts.GetAddressOf())) && SUCCEEDED(fonts->FindFamilyName(kStaticFamily, &index, &exists)) &&
            exists && SUCCEEDED(fonts->GetFontFamily(index, family.GetAddressOf())) &&
            SUCCEEDED(family->GetFirstMatchingFont(static_cast<DWRITE_FONT_WEIGHT>(namedOnly ? named : W::StaticWeight(weight)),
                                                   DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, font.GetAddressOf()))) {
            font->GetMetrics(&metrics);
            found = true;
        }
    }
    if (!found || metrics.designUnitsPerEm == 0) return size * 0.7f;
    return size * metrics.capHeight / metrics.designUnitsPerEm;
}

bool HasFluentIcons() {
    static const bool fluent = Installed(L"Segoe Fluent Icons");
    return fluent;
}

const wchar_t* IconFamily(IconFont font) {
    if (font == IconFont::Emoji) return L"Segoe UI Emoji";
    return HasFluentIcons() ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
}

HRESULT CreateIconFormat(IDWriteFactory* dwrite, IconFont font, DWRITE_FONT_WEIGHT weight, float size, ComPtr<IDWriteTextFormat>& out) {
    out.Reset();
    return dwrite->CreateTextFormat(IconFamily(font), nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"",
                                    out.GetAddressOf());
}

}  // namespace kite::system_font
