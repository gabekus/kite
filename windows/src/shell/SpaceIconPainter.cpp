// See SpaceIconPainter.h.

#include "shell/SpaceIconPainter.h"

#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <vector>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// The Mac's briefcase at 12.5pt semibold inks 15pt wide (30px in its 2x capture of the bar).
constexpr float kBriefcaseInkPerPoint = 15.0f / 12.5f;
constexpr char16_t kBriefcase = u'';  // in both fonts (the PC's cmap check)
// Outlines are made at this em and scaled down, so their bounds keep their precision.
constexpr float kOutlineEm = 100;
// SpaceIconView.imageSide and the picture's cornerRadius.
constexpr float kPictureSide = 1.2f, kPictureCorner = 0.22f;
// The missing picture's "photo", at 0.8 of the icon size in secondaryLabelColor (white 55% on
// dark, black 50% on light).
constexpr float kPlaceholderSize = 0.8f;
constexpr float kSecondaryDark = 0.55f, kSecondaryLight = 0.5f;

std::optional<ComPtr<IDWriteFontFace>> FaceNamed(IDWriteFontCollection* fonts, const wchar_t* family) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    ComPtr<IDWriteFontFamily> found;
    ComPtr<IDWriteFont> font;
    ComPtr<IDWriteFontFace> face;
    if (FAILED(fonts->FindFamilyName(family, &index, &exists)) || !exists || FAILED(fonts->GetFontFamily(index, found.GetAddressOf())) ||
        FAILED(found->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                           font.GetAddressOf())) ||
        FAILED(font->CreateFontFace(face.GetAddressOf()))) {
        return std::nullopt;
    }
    return face;
}

}  // namespace

std::unique_ptr<SpaceIconPainter> SpaceIconPainter::Create(IDWriteFactory* dwrite, std::filesystem::path pictures, std::wstring& error) {
    std::unique_ptr<SpaceIconPainter> painter(new SpaceIconPainter());
    painter->folder_ = std::move(pictures);
    ComPtr<IDWriteFontCollection> fonts;
    if (HRESULT hr = dwrite->GetSystemFontCollection(fonts.GetAddressOf()); FAILED(hr)) {
        error = HResultMessage(L"GetSystemFontCollection", hr);
        return nullptr;
    }
    // Neither installed isn't a failure: symbols draw nothing, as on a Mac without the symbol.
    for (auto [family, slot] : {std::pair{L"Segoe Fluent Icons", &painter->fluent_}, std::pair{L"Segoe MDL2 Assets", &painter->mdl2_}}) {
        if (auto face = FaceNamed(fonts.Get(), family)) {
            slot->emplace();
            (*slot)->face = *face;
        }
    }
    return painter;
}

void SpaceIconPainter::ReleaseDevice() {
    pictures_.clear();
    for (std::optional<Face>* face : {&fluent_, &mdl2_}) {
        if (*face) (*face)->outlines.clear();
    }
    d2d_.Reset();
}

const SpaceIconPainter::Outline* SpaceIconPainter::OutlineIn(Face& face, char16_t codePoint) {
    if (codePoint == 0) return nullptr;
    if (auto it = face.outlines.find(codePoint); it != face.outlines.end()) return it->second ? &*it->second : nullptr;
    std::optional<Outline>& made = face.outlines[codePoint];
    const UINT32 character = codePoint;
    UINT16 index = 0;
    if (FAILED(face.face->GetGlyphIndices(&character, 1, &index)) || index == 0) return nullptr;
    Outline outline;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(d2d_->CreatePathGeometry(outline.geometry.GetAddressOf())) || FAILED(outline.geometry->Open(sink.GetAddressOf())) ||
        FAILED(face.face->GetGlyphRunOutline(kOutlineEm, &index, nullptr, nullptr, 1, FALSE, FALSE, sink.Get())) || FAILED(sink->Close()) ||
        FAILED(outline.geometry->GetBounds(nullptr, &outline.ink)) || outline.ink.right <= outline.ink.left) {
        return nullptr;
    }
    made = std::move(outline);
    return &*made;
}

std::pair<SpaceIconPainter::Face*, const SpaceIconPainter::Outline*> SpaceIconPainter::OutlineOf(const SymbolGlyph& glyph) {
    for (auto [face, codePoint] : {std::pair{&fluent_, glyph.fluent}, std::pair{&mdl2_, glyph.mdl2}}) {
        if (!*face) continue;
        Face& f = **face;
        if (!f.calibrated) {
            // One factor per font, from its briefcase.
            f.calibrated = true;
            if (const Outline* briefcase = OutlineIn(f, kBriefcase)) {
                f.emPerPoint = kBriefcaseInkPerPoint * kOutlineEm / (briefcase->ink.right - briefcase->ink.left);
            }
        }
        if (const Outline* outline = OutlineIn(f, codePoint)) return {&f, outline};
    }
    return {nullptr, nullptr};
}

void SpaceIconPainter::DrawSymbol(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SymbolGlyph& glyph, D2D1_POINT_2F centre,
                                  float size, D2D1_COLOR_F color) {
    const auto [face, outline] = OutlineOf(glyph);
    if (!outline) return;
    // From the outline's em to points, its ink's middle on `centre`.
    const float scale = size * face->emPerPoint / kOutlineEm;
    const float midX = (outline->ink.left + outline->ink.right) / 2, midY = (outline->ink.top + outline->ink.bottom) / 2;
    D2D1_MATRIX_3X2_F transform{};
    context->GetTransform(&transform);
    context->SetTransform(D2D1::Matrix3x2F::Translation(-midX, -midY) * D2D1::Matrix3x2F::Scale(scale, scale) *
                          D2D1::Matrix3x2F::Translation(centre.x, centre.y) * transform);
    brush->SetColor(color);
    context->FillGeometry(outline->geometry.Get(), brush);
    context->SetTransform(transform);
}

ID2D1Bitmap* SpaceIconPainter::Picture(ID2D1DeviceContext* context, const std::string& name, UINT pixels, float scale) {
    const auto key = std::pair{name, pixels};
    if (auto it = pictures_.find(key); it != pictures_.end()) return it->second.Get();
    if (name.empty() || pixels == 0) return nullptr;
    // A missing file isn't remembered: the cell asks again only when it draws again.
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    ComPtr<ID2D1Bitmap> bitmap;
    {
        ComPtr<IWICImagingFactory> wic;
        ComPtr<IWICBitmapDecoder> decoder;
        ComPtr<IWICBitmapFrameDecode> frame;
        ComPtr<IWICFormatConverter> converter;
        ComPtr<IWICBitmapClipper> clipper;
        ComPtr<IWICBitmapScaler> scaler;
        const std::filesystem::path file = folder_ / Widen(name);
        UINT width = 0, height = 0;
        bool ok = SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()))) &&
                  SUCCEEDED(wic->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                           decoder.GetAddressOf())) &&
                  SUCCEEDED(decoder->GetFrame(0, frame.GetAddressOf())) && SUCCEEDED(frame->GetSize(&width, &height)) && width && height &&
                  SUCCEEDED(wic->CreateFormatConverter(converter.GetAddressOf())) &&
                  SUCCEEDED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                                  WICBitmapPaletteTypeMedianCut));
        // Its centred square, filling the icon as the Mac's aspect fill does (Kite stores them
        // square already; a file put there by hand needn't be).
        const UINT side = std::min(width, height);
        const WICRect square{static_cast<INT>((width - side) / 2), static_cast<INT>((height - side) / 2), static_cast<INT>(side),
                             static_cast<INT>(side)};
        ok = ok && SUCCEEDED(wic->CreateBitmapClipper(clipper.GetAddressOf())) && SUCCEEDED(clipper->Initialize(converter.Get(), &square)) &&
             SUCCEEDED(wic->CreateBitmapScaler(scaler.GetAddressOf()));
        // High-quality cubic where there is one (4 in the SDK's enum, which MinGW's headers
        // don't have yet), Fant before, as the favicons.
        constexpr auto kHighQualityCubic = static_cast<WICBitmapInterpolationMode>(4);
        ok = ok && (SUCCEEDED(scaler->Initialize(clipper.Get(), pixels, pixels, kHighQualityCubic)) ||
                    SUCCEEDED(scaler->Initialize(clipper.Get(), pixels, pixels, WICBitmapInterpolationModeFant)));
        std::vector<BYTE> bgra(static_cast<size_t>(pixels) * pixels * 4);
        ok = ok && SUCCEEDED(scaler->CopyPixels(nullptr, pixels * 4, static_cast<UINT>(bgra.size()), bgra.data()));
        // Its pixels are the window's: `pixels` of them is `pixels / scale` points.
        const float dpi = USER_DEFAULT_SCREEN_DPI * scale;
        ok = ok && SUCCEEDED(context->CreateBitmap(D2D1::SizeU(pixels, pixels), bgra.data(), pixels * 4,
                                                   D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
                                                                          dpi, dpi),
                                                   bitmap.GetAddressOf()));
        if (!ok) bitmap.Reset();
    }
    if (SUCCEEDED(init)) CoUninitialize();
    if (!bitmap) return nullptr;
    return (pictures_[key] = bitmap).Get();
}

void SpaceIconPainter::Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre,
                            float size, float scale, D2D1_COLOR_F symbol, bool dark) {
    // Outlines belong to their factory: a context from another (a new device) makes them again.
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    if (factory != d2d_) {
        ReleaseDevice();
        d2d_ = factory;
    }
    if (look.kind == SpaceIconLook::Kind::Symbol) {
        if (look.glyph) DrawSymbol(context, brush, *look.glyph, centre, size, symbol);
        return;
    }
    if (look.kind != SpaceIconLook::Kind::Picture) return;
    // A whole number of points on a side, on the pixel grid.
    const float side = std::round(size * kPictureSide);
    const UINT pixels = static_cast<UINT>(std::lround(side * scale));
    if (ID2D1Bitmap* picture = Picture(context, look.text, pixels, scale)) {
        const float extent = pixels / scale;
        const float left = std::round((centre.x - extent / 2) * scale) / scale, top = std::round((centre.y - extent / 2) * scale) / scale;
        ComPtr<ID2D1BitmapBrush> fill;
        if (FAILED(context->CreateBitmapBrush(picture, D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP,
                                                                                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR),
                                              fill.GetAddressOf()))) {
            return;
        }
        fill->SetTransform(D2D1::Matrix3x2F::Translation(left, top));
        // Circular corners where the Mac's are continuous (a squircle's): within a pixel at these sizes.
        const float radius = side * kPictureCorner;
        context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(left, top, left + extent, top + extent), radius, radius), fill.Get());
        return;
    }
    // The file is gone: the placeholder.
    if (const auto photo = SymbolGlyphFor("photo")) {
        const float c = dark ? 1.0f : 0.0f;
        DrawSymbol(context, brush, *photo, centre, size * kPlaceholderSize, D2D1_COLOR_F{c, c, c, dark ? kSecondaryDark : kSecondaryLight});
    }
}

}  // namespace kite
