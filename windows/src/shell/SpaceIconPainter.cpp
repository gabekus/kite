// See SpaceIconPainter.h.

#include "shell/SpaceIconPainter.h"

#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <system_error>
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
// already, a file put there by hand needn't be) scaled to each of `sides` px; none when it can't
// be read or is too big. The file is read and decoded once for all of them.
std::optional<std::vector<Pixels>> DecodePicture(IWICImagingFactory* wic, const std::filesystem::path& folder, const std::string& name,
                                                 const std::vector<UINT>& sides) {
    if (!wic || folder.empty() || name.empty() || sides.empty()) return std::nullopt;
    const std::filesystem::path file = folder / Widen(name);
    std::error_code error;
    const uintmax_t bytes = std::filesystem::file_size(file, error);
    if (error || bytes == 0 || bytes > kMaxFileBytes) return std::nullopt;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    ComPtr<IWICBitmapClipper> clipper;
    ComPtr<IWICBitmap> square;
    UINT width = 0, height = 0;
    if (FAILED(wic->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf())) ||
        FAILED(decoder->GetFrame(0, frame.GetAddressOf())) || FAILED(frame->GetSize(&width, &height)) || !width || !height ||
        width > kMaxFrameSide || height > kMaxFrameSide || FAILED(wic->CreateFormatConverter(converter.GetAddressOf())) ||
        FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeMedianCut))) {
        return std::nullopt;
    }
    const UINT side = std::min(width, height);
    const WICRect crop{static_cast<INT>((width - side) / 2), static_cast<INT>((height - side) / 2), static_cast<INT>(side),
                       static_cast<INT>(side)};
    // Decoded once into memory, then scaled to each size from there.
    if (FAILED(wic->CreateBitmapClipper(clipper.GetAddressOf())) || FAILED(clipper->Initialize(converter.Get(), &crop)) ||
        FAILED(wic->CreateBitmapFromSource(clipper.Get(), WICBitmapCacheOnLoad, square.GetAddressOf()))) {
        return std::nullopt;
    }
    // High-quality cubic where there is one (4 in the SDK's enum, which MinGW's headers don't have
    // yet), Fant before, as the favicons.
    constexpr auto kHighQualityCubic = static_cast<WICBitmapInterpolationMode>(4);
    std::vector<Pixels> out;
    for (UINT to : sides) {
        ComPtr<IWICBitmapScaler> scaler;
        if (to == 0 || FAILED(wic->CreateBitmapScaler(scaler.GetAddressOf())) ||
            (FAILED(scaler->Initialize(square.Get(), to, to, kHighQualityCubic)) &&
             FAILED(scaler->Initialize(square.Get(), to, to, WICBitmapInterpolationModeFant)))) {
            return std::nullopt;
        }
        Pixels pixels;
        pixels.width = pixels.height = to;
        pixels.bgra.resize(static_cast<size_t>(to) * to * 4);
        if (FAILED(scaler->CopyPixels(nullptr, to * 4, static_cast<UINT>(pixels.bgra.size()), pixels.bgra.data()))) return std::nullopt;
        out.push_back(std::move(pixels));
    }
    return out;
}

// One file to read, at every size asked of it while it waited.
struct Job {
    std::string name;
    std::vector<UINT> sides;
};
struct Result {
    std::string name;
    std::vector<UINT> sides;
    std::optional<std::vector<Pixels>> pixels;  // one per side; none when it can't be read
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
        Result result{job.name, job.sides, DecodePicture(wic.Get(), shared->folder, job.name, job.sides)};
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
    if (!painter->synchronous_) {
        try {
            std::thread(Work, painter->shared_).detach();
        } catch (const std::system_error&) {
            // No thread to be had: decode in place rather than never.
            painter->synchronous_ = true;
        }
    }
    return painter;
}

SpaceIconPainter::~SpaceIconPainter() {
    {
        std::lock_guard lock(shared_->mutex);
        shared_->stopping = true;
        shared_->queue.clear();
    }
    shared_->wake.notify_all();
    sized_.clear();
    captureWic_.Reset();
    if (captureCom_) CoUninitialize();
}

void SpaceIconPainter::ReleaseDevice() {
    for (auto& [key, sized] : sized_) {
        sized.bitmap.Reset();
        sized.brush.Reset();
    }
    for (std::optional<Face>* face : {&fluent_, &mdl2_}) {
        if (*face) (*face)->outlines.clear();
    }
    shapes_.clear();
    d2d_.Reset();
}

void SpaceIconPainter::Retain(const std::set<std::string>& names) {
    loads_.Retain(names);
    std::erase_if(sized_, [&](const auto& entry) { return !names.contains(entry.first.first); });
    // And the reads nobody will show.
    std::lock_guard lock(shared_->mutex);
    std::erase_if(shared_->queue, [&](const Job& job) { return !names.contains(job.name); });
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

namespace {

// One layer's figures as a path, filled by the nonzero rule (core orients them for it).
ComPtr<ID2D1PathGeometry> LayerPath(ID2D1Factory* d2d, const ShapeLayer& layer) {
    ComPtr<ID2D1PathGeometry> path;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(d2d->CreatePathGeometry(path.GetAddressOf())) || FAILED(path->Open(sink.GetAddressOf()))) return nullptr;
    sink->SetFillMode(D2D1_FILL_MODE_WINDING);
    for (const ShapeFigure& figure : layer.figures) {
        sink->BeginFigure(D2D1::Point2F(figure.start.x, figure.start.y), D2D1_FIGURE_BEGIN_FILLED);
        for (const ShapeSegment& segment : figure.segments) {
            if (segment.cubic) {
                sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(segment.c1.x, segment.c1.y), D2D1::Point2F(segment.c2.x, segment.c2.y),
                                                    D2D1::Point2F(segment.to.x, segment.to.y)));
            } else {
                sink->AddLine(D2D1::Point2F(segment.to.x, segment.to.y));
            }
        }
        sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    }
    return SUCCEEDED(sink->Close()) ? path : nullptr;
}

// How closely a cut or a join follows the curves, in the shape's points: 0.04 is a fifth of a
// pixel at the header's 15pt (1.2x the shape) on a 4x screen, inside Direct2D's default quarter.
constexpr float kShapeTolerance = 0.04f;

}  // namespace

ComPtr<ID2D1Geometry> MakeShapeGeometry(ID2D1Factory* d2d, const SymbolShape& shape) {
    ComPtr<ID2D1Geometry> joined;
    for (const ShapeLayer& layer : shape.layers) {
        ComPtr<ID2D1PathGeometry> path = LayerPath(d2d, layer);
        if (!path) return nullptr;
        if (!joined) {
            if (layer.cut) continue;  // nothing to cut yet
            joined = path;
            continue;
        }
        ComPtr<ID2D1PathGeometry> combined;
        ComPtr<ID2D1GeometrySink> sink;
        const D2D1_COMBINE_MODE mode = layer.cut ? D2D1_COMBINE_MODE_EXCLUDE : D2D1_COMBINE_MODE_UNION;
        if (FAILED(d2d->CreatePathGeometry(combined.GetAddressOf())) || FAILED(combined->Open(sink.GetAddressOf())) ||
            FAILED(joined->CombineWithGeometry(path.Get(), mode, nullptr, kShapeTolerance, sink.Get())) || FAILED(sink->Close())) {
            return nullptr;
        }
        joined = combined;
    }
    return joined;
}

ID2D1Geometry* SpaceIconPainter::ShapeGeometry(const SymbolShape& shape) {
    if (auto it = shapes_.find(&shape); it != shapes_.end()) return it->second.Get();
    if (!d2d_) return nullptr;
    // Kept even when it fails, so a failure isn't retried every frame (the next factory tries).
    ComPtr<ID2D1Geometry>& made = shapes_[&shape];
    made = MakeShapeGeometry(d2d_.Get(), shape);
    return made.Get();
}

double SpaceIconPainter::Now() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool SpaceIconPainter::Arrived(const std::string& name, const std::vector<UINT>& sides, std::vector<Pixels> pixels) {
    if (!loads_.Known(name)) return false;  // no longer shown
    const bool readable = !pixels.empty() && pixels.size() == sides.size();
    const PictureLoads::Answer answer = loads_.Arrived(name, std::vector<unsigned>(sides.begin(), sides.end()), readable, Now());
    if (readable) {
        for (size_t i = 0; i < sides.size(); ++i) sized_[SizedKey{name, sides[i]}] = Sized{std::move(pixels[i]), nullptr, nullptr};
    }
    for (unsigned side : answer.evicted) sized_.erase(SizedKey{name, side});
    return answer.changed;
}

std::set<std::string> SpaceIconPainter::TakeResults() {
    std::deque<Result> done;
    {
        std::lock_guard lock(shared_->mutex);
        done.swap(shared_->done);
        shared_->posted = false;
    }
    std::set<std::string> changed;
    for (Result& result : done) {
        if (Arrived(result.name, result.sides, result.pixels ? std::move(*result.pixels) : std::vector<Pixels>{})) changed.insert(result.name);
    }
    return changed;
}

void SpaceIconPainter::Request(const std::string& name, UINT side) {
    if (synchronous_) {
        // A capture's one frame: decoded here, with one WIC factory for the run.
        if (!captureWic_) {
            captureCom_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
            ComPtr<IWICImagingFactory> wic;
            CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()));
            captureWic_ = wic;
        }
        ComPtr<IWICImagingFactory> wic;
        if (captureWic_) captureWic_.As(&wic);
        auto pixels = DecodePicture(wic.Get(), shared_->folder, name, {side});
        Arrived(name, {side}, pixels ? std::move(*pixels) : std::vector<Pixels>{});
        return;
    }
    // Into the file's read if it's still waiting; the worker wakes at SendRequests, after the
    // sidebar's whole draw, so the bar's size and the header's are one read.
    std::lock_guard lock(shared_->mutex);
    auto job = std::find_if(shared_->queue.begin(), shared_->queue.end(), [&](const Job& j) { return j.name == name; });
    if (job != shared_->queue.end()) {
        job->sides.push_back(side);
        return;
    }
    shared_->queue.push_back(Job{name, {side}});
    requested_ = true;
}

void SpaceIconPainter::SendRequests() {
    if (!requested_) return;
    requested_ = false;
    shared_->wake.notify_one();
}

void SpaceIconPainter::Prepare(ID2D1DeviceContext* context, const SpaceIconLook& look, float size, float scale) {
    if (look.kind != SpaceIconLook::Kind::Picture || look.text.empty()) return;
    UseFactoryOf(context);
    const UINT side = PictureFrameAt(0, 0, size, scale).pixels;
    const PictureLoads::Need need = loads_.Prepare(look.text, side, Now());
    if (need.ask) Request(look.text, side);
    if (need.show != PictureLoads::Show::Picture) return;
    const auto found = sized_.find(SizedKey{look.text, side});
    if (found == sized_.end() || found->second.bitmap) return;
    Sized& sized = found->second;
    // Its pixels are the window's: `side` of them is `side / scale` points. A failure here (the
    // device's) is tried again at the next draw.
    const float dpi = USER_DEFAULT_SCREEN_DPI * scale;
    ComPtr<ID2D1Bitmap> bitmap;
    ComPtr<ID2D1BitmapBrush> brush;
    if (SUCCEEDED(context->CreateBitmap(D2D1::SizeU(side, side), sized.pixels.bgra.data(), side * 4,
                                        D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
                                                               dpi, dpi),
                                        bitmap.GetAddressOf())) &&
        SUCCEEDED(context->CreateBitmapBrush(bitmap.Get(),
                                             D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP,
                                                                         D2D1_BITMAP_INTERPOLATION_MODE_LINEAR),
                                             brush.GetAddressOf()))) {
        sized.bitmap = std::move(bitmap);
        sized.brush = std::move(brush);
    }
}

void SpaceIconPainter::Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre,
                            float size, float scale, D2D1_COLOR_F symbol, bool dark) {
    UseFactoryOf(context);
    if (look.kind == SpaceIconLook::Kind::Symbol) {
        if (look.glyph && look.glyph->drawn) {
            // Kite's own shape, from the bar's 12.5 to `size`, its origin on `centre`.
            const SymbolShape* shape = SymbolShapeFor(look.text);
            if (ID2D1Geometry* geometry = shape ? ShapeGeometry(*shape) : nullptr) {
                const float factor = size / kSymbolShapeSize;
                D2D1_MATRIX_3X2_F transform{};
                context->GetTransform(&transform);
                context->SetTransform(D2D1::Matrix3x2F::Scale(factor, factor) * D2D1::Matrix3x2F::Translation(centre.x, centre.y) *
                                      transform);
                brush->SetColor(symbol);
                context->FillGeometry(geometry, brush);
                context->SetTransform(transform);
            }
        } else if (look.glyph) {
            DrawSymbol(context, brush, *look.glyph, centre, size, symbol);
        }
        return;
    }
    if (look.kind != SpaceIconLook::Kind::Picture) return;
    Prepare(context, look, size, scale);
    const PictureFrame frame = PictureFrameAt(centre.x, centre.y, size, scale);
    const PictureLoads::Show shows = loads_.Shows(look.text, frame.pixels);
    if (shows == PictureLoads::Show::Nothing) return;  // still loading
    if (shows == PictureLoads::Show::Picture) {
        const auto sized = sized_.find(SizedKey{look.text, frame.pixels});
        if (sized == sized_.end() || !sized->second.brush) return;  // its bitmap failed: tried again at the next draw
        sized->second.brush->SetTransform(D2D1::Matrix3x2F::Translation(frame.left, frame.top));
        // Circular corners where the Mac's are continuous (a squircle's): within a pixel at these sizes.
        context->FillRoundedRectangle(
            D2D1::RoundedRect(D2D1::RectF(frame.left, frame.top, frame.left + frame.side, frame.top + frame.side), frame.radius, frame.radius),
            sized->second.brush.Get());
        return;
    }
    // The file can't be read (or the name isn't valid): the placeholder.
    if (const auto photo = SymbolGlyphFor("photo")) {
        const float c = dark ? 1.0f : 0.0f;
        DrawSymbol(context, brush, *photo, centre, size * kPlaceholderSize,
                   D2D1_COLOR_F{c, c, c, dark ? kPlaceholderAlphaDark : kPlaceholderAlphaLight});
    }
}

}  // namespace kite
