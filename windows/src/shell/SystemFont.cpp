#include "shell/SystemFont.h"

#include <dwrite_3.h>

#include <atomic>
#include <cmath>
#include <iterator>

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

void AxesFor(MacWeight weight, float size, DWRITE_FONT_AXIS_VALUE (&axes)[2]) {
    const W::VariableSetting setting = W::Variable(weight, size);
    axes[0] = {DWRITE_FONT_AXIS_TAG_WEIGHT, setting.weight};
    axes[1] = {DWRITE_FONT_AXIS_TAG_OPTICAL_SIZE, setting.opticalSize};
}

}  // namespace

Face Current() { return !forcedStatic && Variable() ? Face::Variable : Face::Static; }

void UseStaticForTesting() { forcedStatic = true; }

HRESULT CreateTextFormat(IDWriteFactory* dwrite, MacWeight weight, float size, ComPtr<IDWriteTextFormat>& out) {
    out.Reset();
    if (Current() == Face::Variable) {
        DWRITE_FONT_AXIS_VALUE axes[2];
        AxesFor(weight, size, axes);
        // The named weight is only what DirectWrite matches before the axes apply (and what the
        // format reports); the axis values set the face.
        HRESULT hr = dwrite->CreateTextFormat(kVariableFamily, nullptr, static_cast<DWRITE_FONT_WEIGHT>(std::lround(axes[0].value)),
                                              DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
        ComPtr<IDWriteTextFormat3> variable;
        if (SUCCEEDED(hr)) hr = out.As(&variable);
        if (SUCCEEDED(hr)) hr = variable->SetFontAxisValues(axes, 2);
        if (SUCCEEDED(hr)) return hr;
        out.Reset();  // the axes didn't take: Segoe UI's named weights, as on Windows 10
    }
    return dwrite->CreateTextFormat(kStaticFamily, nullptr, static_cast<DWRITE_FONT_WEIGHT>(W::StaticWeight(weight)), DWRITE_FONT_STYLE_NORMAL,
                                    DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
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
    if (FAILED(hr)) out.Reset();
    return hr;
}

const wchar_t* GdiFaceName() { return Current() == Face::Variable ? kVariableGdiFamily : kStaticFamily; }

float CapHeight(IDWriteFactory* dwrite, MacWeight weight, float size) {
    DWRITE_FONT_METRICS metrics{};
    bool found = false;
    if (Current() == Face::Variable) {
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
            SUCCEEDED(family->GetFirstMatchingFont(static_cast<DWRITE_FONT_WEIGHT>(W::StaticWeight(weight)), DWRITE_FONT_STRETCH_NORMAL,
                                                   DWRITE_FONT_STYLE_NORMAL, font.GetAddressOf()))) {
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
