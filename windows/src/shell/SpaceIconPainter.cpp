// See SpaceIconPainter.h.

#include "shell/SpaceIconPainter.h"

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
constexpr char16_t kBriefcase = u'\uE821';  // in both fonts (the PC's cmap check)
// Outlines are made at this em and scaled down, so their bounds keep their precision.
constexpr float kOutlineEm = 100;

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
    ComPtr<IDWriteFontCollection> fonts;
    if (HRESULT hr = dwrite->GetSystemFontCollection(fonts.GetAddressOf()); FAILED(hr)) {
        error = HResultMessage(L"GetSystemFontCollection", hr);
        return nullptr;
    }
    // Neither installed isn't a failure: symbols draw nothing.
    for (auto [family, slot] : {std::pair{L"Segoe Fluent Icons", &painter->fluent_}, std::pair{L"Segoe MDL2 Assets", &painter->mdl2_}}) {
        if (auto face = FaceNamed(fonts.Get(), family)) {
            slot->emplace();
            (*slot)->face = *face;
        }
    }
    // The folder by its full path with the \\?\ prefix, so a name the Mac allows that Windows
    // reserves (CON.png, COM1.png, a trailing dot) is an ordinary file there, never a device.
    std::error_code ignored;
    std::filesystem::path absolute = std::filesystem::absolute(pictures, ignored).lexically_normal();
    absolute.make_preferred();
    painter->folder_ = absolute.native().starts_with(L"\\\\") ? absolute : std::filesystem::path(L"\\\\?\\" + absolute.native());
    // WIC on this (the UI) thread for the painter's life; no WIC is no pictures, not a failure.
    painter->comInitialized_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(painter->wic_.GetAddressOf()));
    return painter;
}

SpaceIconPainter::~SpaceIconPainter() {
    pictures_.clear();
    wic_.Reset();
    if (comInitialized_) CoUninitialize();
}

void SpaceIconPainter::ReleaseDevice() {
    pictures_.clear();
    for (std::optional<Face>* face : {&fluent_, &mdl2_}) {
        if (*face) (*face)->outlines.clear();
    }
    d2d_.Reset();
}

void SpaceIconPainter::Retain(const std::set<std::string>& names) {
    std::erase_if(pictures_, [&](const auto& entry) { return !names.contains(entry.first); });
}

void SpaceIconPainter::UseFactoryOf(ID2D1DeviceContext* context) {
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    if (factory == d2d_) return;
    ReleaseDevice();
    d2d_ = factory;
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
            // One factor per font, from its briefcase (tried again if its outline couldn't be made).
            if (const Outline* briefcase = OutlineIn(f, kBriefcase)) {
                f.emPerPoint = kBriefcaseInkPerPoint * kOutlineEm / (briefcase->ink.right - briefcase->ink.left);
                f.calibrated = true;
            } else {
                f.outlines.erase(kBriefcase);
                continue;
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

ComPtr<ID2D1Bitmap> SpaceIconPainter::Decode(ID2D1DeviceContext* context, const std::string& name, UINT pixels, float scale) {
    if (!wic_ || name.empty() || pixels == 0) return nullptr;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    ComPtr<IWICBitmapClipper> clipper;
    ComPtr<IWICBitmapScaler> scaler;
    const std::filesystem::path file = folder_ / Widen(name);
    UINT width = 0, height = 0;
    if (FAILED(wic_->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf())) ||
        FAILED(decoder->GetFrame(0, frame.GetAddressOf())) || FAILED(frame->GetSize(&width, &height)) || !width || !height ||
        FAILED(wic_->CreateFormatConverter(converter.GetAddressOf())) ||
        FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeMedianCut))) {
        return nullptr;
    }
    // Its centred square, filling the icon as the Mac's aspect fill does (Kite stores them square
    // already; a file put there by hand needn't be).
    const UINT side = std::min(width, height);
    const WICRect square{static_cast<INT>((width - side) / 2), static_cast<INT>((height - side) / 2), static_cast<INT>(side),
                         static_cast<INT>(side)};
    // High-quality cubic where there is one (4 in the SDK's enum, which MinGW's headers don't have
    // yet), Fant before, as the favicons.
    constexpr auto kHighQualityCubic = static_cast<WICBitmapInterpolationMode>(4);
    if (FAILED(wic_->CreateBitmapClipper(clipper.GetAddressOf())) || FAILED(clipper->Initialize(converter.Get(), &square)) ||
        FAILED(wic_->CreateBitmapScaler(scaler.GetAddressOf())) ||
        (FAILED(scaler->Initialize(clipper.Get(), pixels, pixels, kHighQualityCubic)) &&
         FAILED(scaler->Initialize(clipper.Get(), pixels, pixels, WICBitmapInterpolationModeFant)))) {
        return nullptr;
    }
    std::vector<BYTE> bgra(static_cast<size_t>(pixels) * pixels * 4);
    if (FAILED(scaler->CopyPixels(nullptr, pixels * 4, static_cast<UINT>(bgra.size()), bgra.data()))) return nullptr;
    // Its pixels are the window's: `pixels` of them is `pixels / scale` points.
    const float dpi = USER_DEFAULT_SCREEN_DPI * scale;
    ComPtr<ID2D1Bitmap> bitmap;
    if (FAILED(context->CreateBitmap(D2D1::SizeU(pixels, pixels), bgra.data(), pixels * 4,
                                     D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi,
                                                            dpi),
                                     bitmap.GetAddressOf()))) {
        return nullptr;
    }
    return bitmap;
}

void SpaceIconPainter::Prepare(ID2D1DeviceContext* context, const SpaceIconLook& look, float size, float scale) {
    if (look.kind != SpaceIconLook::Kind::Picture || look.text.empty()) return;
    UseFactoryOf(context);
    const UINT pixels = PictureFrameAt(0, 0, size, scale).pixels;
    if (auto it = pictures_.find(look.text); it != pictures_.end() && it->second.pixels == pixels) return;
    Picture picture;
    picture.pixels = pixels;
    picture.bitmap = Decode(context, look.text, pixels, scale);
    if (picture.bitmap &&
        FAILED(context->CreateBitmapBrush(picture.bitmap.Get(),
                                          D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP,
                                                                      D2D1_BITMAP_INTERPOLATION_MODE_LINEAR),
                                          picture.brush.GetAddressOf()))) {
        picture.bitmap.Reset();
    }
    pictures_[look.text] = std::move(picture);
}

void SpaceIconPainter::Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre,
                            float size, float scale, D2D1_COLOR_F symbol, bool dark) {
    UseFactoryOf(context);
    if (look.kind == SpaceIconLook::Kind::Symbol) {
        if (look.glyph) DrawSymbol(context, brush, *look.glyph, centre, size, symbol);
        return;
    }
    if (look.kind != SpaceIconLook::Kind::Picture) return;
    Prepare(context, look, size, scale);
    const auto it = pictures_.find(look.text);
    if (it != pictures_.end() && it->second.brush) {
        const PictureFrame frame = PictureFrameAt(centre.x, centre.y, size, scale);
        it->second.brush->SetTransform(D2D1::Matrix3x2F::Translation(frame.left, frame.top));
        // Circular corners where the Mac's are continuous (a squircle's): within a pixel at these sizes.
        context->FillRoundedRectangle(
            D2D1::RoundedRect(D2D1::RectF(frame.left, frame.top, frame.left + frame.side, frame.top + frame.side), frame.radius, frame.radius),
            it->second.brush.Get());
        return;
    }
    // The file can't be read: the placeholder.
    if (const auto photo = SymbolGlyphFor("photo")) {
        const float c = dark ? 1.0f : 0.0f;
        DrawSymbol(context, brush, *photo, centre, size * kPlaceholderSize,
                   D2D1_COLOR_F{c, c, c, dark ? kPlaceholderAlphaDark : kPlaceholderAlphaLight});
    }
}

}  // namespace kite
