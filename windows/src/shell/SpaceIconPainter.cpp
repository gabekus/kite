// See SpaceIconPainter.h.

#include "shell/SpaceIconPainter.h"

#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
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
// What the worker will decode: Kite's own pictures are 128px PNGs of a few tens of KB.
constexpr uintmax_t kMaxFileBytes = 1 << 20;
constexpr UINT kMaxFrameSide = 2048;
// An unreadable picture is looked for again at a draw this long after.
constexpr auto kRetryAfter = std::chrono::seconds(2);

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

// The folder by its full path with the \\?\ prefix (\\?\UNC\ for a share), so a name the Mac
// allows that Windows reserves (CON.png, COM1.png, a trailing dot) is an ordinary file there,
// never a device. Empty when it has no full path.
std::filesystem::path Verbatim(const std::filesystem::path& folder) {
    std::error_code error;
    std::filesystem::path absolute = std::filesystem::absolute(folder, error).lexically_normal();
    if (error || absolute.empty()) return {};
    absolute.make_preferred();
    const std::wstring& text = absolute.native();
    if (text.starts_with(L"\\\\?\\")) return absolute;
    if (text.starts_with(L"\\\\")) return std::filesystem::path(L"\\\\?\\UNC\\" + text.substr(2));
    return std::filesystem::path(L"\\\\?\\" + text);
}

// `name` in `folder` decoded, its centred square (the Mac's aspect fill; Kite stores them square
// already, a file put there by hand needn't be) scaled to `side` px; none when it can't be read
// or is too big.
std::optional<Pixels> DecodePicture(IWICImagingFactory* wic, const std::filesystem::path& folder, const std::string& name, UINT side) {
    if (!wic || folder.empty() || name.empty() || side == 0) return std::nullopt;
    const std::filesystem::path file = folder / Widen(name);
    std::error_code error;
    const uintmax_t bytes = std::filesystem::file_size(file, error);
    if (error || bytes == 0 || bytes > kMaxFileBytes) return std::nullopt;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    ComPtr<IWICBitmapClipper> clipper;
    ComPtr<IWICBitmapScaler> scaler;
    UINT width = 0, height = 0;
    if (FAILED(wic->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf())) ||
        FAILED(decoder->GetFrame(0, frame.GetAddressOf())) || FAILED(frame->GetSize(&width, &height)) || !width || !height ||
        width > kMaxFrameSide || height > kMaxFrameSide || FAILED(wic->CreateFormatConverter(converter.GetAddressOf())) ||
        FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeMedianCut))) {
        return std::nullopt;
    }
    const UINT square = std::min(width, height);
    const WICRect crop{static_cast<INT>((width - square) / 2), static_cast<INT>((height - square) / 2), static_cast<INT>(square),
                       static_cast<INT>(square)};
    // High-quality cubic where there is one (4 in the SDK's enum, which MinGW's headers don't have
    // yet), Fant before, as the favicons.
    constexpr auto kHighQualityCubic = static_cast<WICBitmapInterpolationMode>(4);
    if (FAILED(wic->CreateBitmapClipper(clipper.GetAddressOf())) || FAILED(clipper->Initialize(converter.Get(), &crop)) ||
        FAILED(wic->CreateBitmapScaler(scaler.GetAddressOf())) ||
        (FAILED(scaler->Initialize(clipper.Get(), side, side, kHighQualityCubic)) &&
         FAILED(scaler->Initialize(clipper.Get(), side, side, WICBitmapInterpolationModeFant)))) {
        return std::nullopt;
    }
    Pixels pixels;
    pixels.width = pixels.height = side;
    pixels.bgra.resize(static_cast<size_t>(side) * side * 4);
    if (FAILED(scaler->CopyPixels(nullptr, side * 4, static_cast<UINT>(pixels.bgra.size()), pixels.bgra.data()))) return std::nullopt;
    return pixels;
}

struct Job {
    std::string name;
    UINT side = 0;
};
struct Result {
    std::string name;
    UINT side = 0;
    std::optional<Pixels> pixels;
};

}  // namespace

struct SpaceIconPainter::Shared {
    HWND window = nullptr;
    UINT message = 0;
    std::filesystem::path folder;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Job> queue;
    std::deque<Result> done;
    bool stopping = false;
    bool posted = false;
};

namespace {

void Work(const std::shared_ptr<SpaceIconPainter::Shared>& shared) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IWICImagingFactory> wic;
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()));
    for (;;) {
        Job job;
        {
            std::unique_lock lock(shared->mutex);
            shared->wake.wait(lock, [&] { return shared->stopping || !shared->queue.empty(); });
            if (shared->stopping) break;
            job = std::move(shared->queue.front());
            shared->queue.pop_front();
        }
        Result result{job.name, job.side, DecodePicture(wic.Get(), shared->folder, job.name, job.side)};
        std::lock_guard lock(shared->mutex);
        if (shared->stopping) break;
        shared->done.push_back(std::move(result));
        // One wake for however many arrive before the window takes them.
        if (!shared->posted) shared->posted = PostMessageW(shared->window, shared->message, 0, 0) != FALSE;
    }
    wic.Reset();
    if (SUCCEEDED(com)) CoUninitialize();
}

}  // namespace

std::unique_ptr<SpaceIconPainter> SpaceIconPainter::Create(IDWriteFactory* dwrite, HWND window, const Pictures& pictures,
                                                           std::wstring& error) {
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
    painter->shared_ = std::make_shared<Shared>();
    painter->shared_->window = window;
    painter->shared_->message = pictures.message;
    painter->shared_->folder = Verbatim(pictures.folder);
    painter->synchronous_ = pictures.synchronous;
    // The worker holds the queue too, so it outlives the painter if a read is still running.
    if (!painter->synchronous_) std::thread(Work, painter->shared_).detach();
    return painter;
}

SpaceIconPainter::~SpaceIconPainter() {
    {
        std::lock_guard lock(shared_->mutex);
        shared_->stopping = true;
        shared_->queue.clear();
    }
    shared_->wake.notify_all();
}

void SpaceIconPainter::ReleaseDevice() {
    for (auto& [key, picture] : pictures_) {
        picture.bitmap.Reset();
        picture.brush.Reset();
    }
    for (std::optional<Face>* face : {&fluent_, &mdl2_}) {
        if (*face) (*face)->outlines.clear();
    }
    d2d_.Reset();
}

void SpaceIconPainter::Retain(const std::set<std::string>& names) {
    std::erase_if(pictures_, [&](const auto& entry) { return !names.contains(entry.first.first); });
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

void SpaceIconPainter::Arrived(const PictureKey& key, std::optional<Pixels> pixels) {
    auto it = pictures_.find(key);
    if (it == pictures_.end() || it->second.state != Picture::State::Loading) return;  // no longer shown
    Picture& picture = it->second;
    if (pixels) {
        picture.state = Picture::State::Ready;
        picture.pixels = std::move(*pixels);
    } else {
        picture.state = Picture::State::Unreadable;
        picture.unreadableAt = std::chrono::steady_clock::now();
    }
}

bool SpaceIconPainter::TakeResults() {
    std::deque<Result> done;
    {
        std::lock_guard lock(shared_->mutex);
        done.swap(shared_->done);
        shared_->posted = false;
    }
    bool changed = false;
    for (Result& result : done) {
        const PictureKey key{result.name, result.side};
        const auto it = pictures_.find(key);
        changed = changed || (it != pictures_.end() && it->second.state == Picture::State::Loading);
        Arrived(key, std::move(result.pixels));
    }
    return changed;
}

void SpaceIconPainter::Prepare(ID2D1DeviceContext* context, const SpaceIconLook& look, float size, float scale) {
    if (look.kind != SpaceIconLook::Kind::Picture || look.text.empty()) return;
    UseFactoryOf(context);
    const PictureKey key{look.text, PictureFrameAt(0, 0, size, scale).pixels};
    Picture& picture = pictures_[key];
    if (picture.state == Picture::State::Unreadable && std::chrono::steady_clock::now() - picture.unreadableAt >= kRetryAfter) {
        picture = Picture{};  // looked for again
    }
    if (picture.state == Picture::State::Loading && !picture.requested) {
        picture.requested = true;
        if (synchronous_) {
            // A capture's one frame: decoded here, with this thread's COM for the while.
            const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            {
                ComPtr<IWICImagingFactory> wic;
                CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()));
                Arrived(key, DecodePicture(wic.Get(), shared_->folder, key.first, key.second));
            }
            if (SUCCEEDED(com)) CoUninitialize();
        } else {
            {
                std::lock_guard lock(shared_->mutex);
                shared_->queue.push_back(Job{key.first, key.second});
            }
            shared_->wake.notify_one();
        }
    }
    if (picture.state != Picture::State::Ready || picture.bitmap) return;
    // Its pixels are the window's: `pixels` of them is `pixels / scale` points. A failure here
    // (the device's) is tried again at the next draw.
    const float dpi = USER_DEFAULT_SCREEN_DPI * scale;
    const UINT side = picture.pixels.width;
    ComPtr<ID2D1Bitmap> bitmap;
    ComPtr<ID2D1BitmapBrush> brush;
    if (SUCCEEDED(context->CreateBitmap(D2D1::SizeU(side, side), picture.pixels.bgra.data(), side * 4,
                                        D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
                                                               dpi, dpi),
                                        bitmap.GetAddressOf())) &&
        SUCCEEDED(context->CreateBitmapBrush(bitmap.Get(),
                                             D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP,
                                                                         D2D1_BITMAP_INTERPOLATION_MODE_LINEAR),
                                             brush.GetAddressOf()))) {
        picture.bitmap = std::move(bitmap);
        picture.brush = std::move(brush);
    }
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
    const PictureFrame frame = PictureFrameAt(centre.x, centre.y, size, scale);
    const auto it = pictures_.find(PictureKey{look.text, frame.pixels});
    const bool unreadable = look.text.empty() || (it != pictures_.end() && it->second.state == Picture::State::Unreadable);
    if (!unreadable) {
        // Loading draws nothing; ready, the picture.
        if (it == pictures_.end() || !it->second.brush) return;
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
