// See SidebarView.h.

#include "shell/SidebarView.h"

#include <d3d11.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "core/OKLab.h"
#include "shell/Errors.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// ArcMetrics.Sidebar, in points: the rows' geometry from core, and how the view draws them.
namespace M {
using namespace sidebar_metrics;
constexpr float kUrlFieldTextInset = 12;
constexpr float kUrlFieldFontSize = 13;
constexpr float kUrlFieldTextOpacity = 0.6f;
constexpr float kCornerRadius = 11;  // the address field and the pills
constexpr float kFieldFill = 0.10f;  // white over the theme, for the address field
constexpr float kHeaderIconX = 13;   // in the window
constexpr float kHeaderTextX = 41;   // in the window
constexpr float kHeaderFontSize = 13;
constexpr float kHeaderTextOpacity = 0.45f;
constexpr float kHeaderEmojiSize = 15;
constexpr float kIconSize = 18;
constexpr float kIconTextGap = 8;
constexpr float kNestingIndent = 16;
constexpr float kTabFontSize = 14;
constexpr float kTabTextOpacity = 0.865f;
constexpr float kSelectedFill = 0.20f;
constexpr float kSelectedFillLight = 0.85f;
// A hovered pill: white 10% on a dark theme. A hovered tab on a light one is a dark wash
// instead (tabPillFill); folders and New Tab keep the white wash, 3.5 times as strong.
constexpr float kHoverFill = 0.10f;
constexpr float kHoverFillLight = 0.05f;
constexpr D2D1_COLOR_F kHoverWashLight{0.055f, 0.059f, 0.063f, kHoverFillLight};
constexpr float kDividerInset = 10;
constexpr float kDividerThickness = 0.5f;
constexpr float kDividerOpacity = 0.08f;
}  // namespace M

// NSColor.labelColor: black (light) or white (dark) at 85%. The Mac's sidebar labels are that
// colour, faded further by their view's alphaValue.
constexpr float kLabelAlpha = 0.85f;
// The Mac's SidebarLabel line box: SF Pro's ascender plus descender (0.952 + 0.241 of the
// size), rounded up to whole points; its text sits in the middle of the row, rounded down,
// with SF's baseline at the ascender. Kite puts Segoe UI's baseline where SF's is.
constexpr float kAscender = 0.952f;
constexpr float kDescender = 0.241f;
float LineHeight(float size) { return std::ceil(size * (kAscender + kDescender)); }
// The text's top in a box `height` tall: SidebarLabel's centring, half a point when odd.
float TextTop(float height, float line) {
    return std::floor((height - line) / 2) + std::fmod(height - line, 2.0f) / 2;
}
// Folder rows' trailing chevron (chevron.right, 9pt bold) is about this wide; its slot and
// gap stay reserved even while it's hidden (the Mac shows it on hover).
constexpr float kFolderChevronWidth = 6.5f;
// The header's chevron button and the gap around its Spacer (HStack spacing 2).
constexpr float kHeaderGap = M::kHeaderTextX - M::kHeaderIconX - M::kHeaderIconSize;
// FaviconImageView: corners of 19% of its side; the globe at 60% and Kite's page symbols at 80%.
constexpr float kFaviconCorner = 0.19f;
constexpr float kGlobeOpacity = 0.6f;
constexpr float kSymbolOpacity = 0.8f;
// The folder's symbol and New Tab's content (SidebarListCells.swift).
constexpr float kFolderIconOpacity = 0.75f;
constexpr float kNewTabOpacity = M::kTabTextOpacity * 0.75f;
constexpr float kHeaderChevronOpacity = 0.5f;
constexpr float kFolderChevronOpacity = 0.5f;
// A wheel notch scrolls 100pt for Windows' default 3 lines, as Chromium scrolls a page.
constexpr float kWheelLine = 100.0f / 3;

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) code points for the SF
// Symbols the Mac draws: globe, folder / folder.fill, plus, chevron.right, and the symbols of
// Kite's own pages (clock.arrow.circlepath, archivebox, gearshape, magnifyingglass).
constexpr wchar_t kGlobe = 0xE774;
constexpr wchar_t kFolder = 0xE8B7;
constexpr wchar_t kFolderFill = 0xE8D5;
constexpr wchar_t kPlus = 0xE710;
constexpr wchar_t kChevronRight = 0xE76C;
constexpr wchar_t kChevronDown = 0xE70D;  // chevron.right turned a quarter (an open folder or section)
constexpr wchar_t kHistory = 0xE81C;
constexpr wchar_t kArchive = 0xE7B8;
constexpr wchar_t kSettings = 0xE713;
constexpr wchar_t kSearch = 0xE721;
// The glyphs fill about this much of their em square, so a symbol meant to fill a box is set
// at the box's size over it, and one the Mac sets at a point size at that size over it (an
// SF Symbol is about as big as its point size).
constexpr float kGlyphInk = 0.9f;

std::wstring Widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(std::max(size, 0)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), size);
    return out;
}

bool IsDeviceLost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == static_cast<HRESULT>(D2DERR_RECREATE_TARGET);
}

D2D1_RECT_F Rect(float left, float top, float right, float bottom) { return D2D1_RECT_F{left, top, right, bottom}; }

}  // namespace

std::unique_ptr<SidebarView> SidebarView::Create(HWND window, Favicons* favicons, std::wstring& error) {
    std::unique_ptr<SidebarView> view(new SidebarView(window, favicons));
    D2D1_FACTORY_OPTIONS options{};
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options,
                                   reinterpret_cast<void**>(view->d2dFactory_.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"D2D1CreateFactory", hr);
        return nullptr;
    }
    if (FAILED(hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                        reinterpret_cast<IUnknown**>(view->dwrite_.GetAddressOf())))) {
        error = HResultMessage(L"DWriteCreateFactory", hr);
        return nullptr;
    }
    // The system UI font for the Mac's SF Pro, as the command bar: Segoe UI Variable on
    // Windows 11, Segoe UI before it. Both have Regular and Semibold.
    ComPtr<IDWriteFontCollection> fonts;
    view->dwrite_->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    const wchar_t* text = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    auto format = [&](const wchar_t* family, DWRITE_FONT_WEIGHT weight, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = view->dwrite_->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size,
                                                       L"", out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    if (FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kUrlFieldFontSize, view->addressFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kHeaderFontSize, view->headerFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kTabFontSize, view->tabFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kTabFontSize, view->folderFormat_)) ||
        FAILED(hr = format(L"Segoe UI Emoji", DWRITE_FONT_WEIGHT_REGULAR, M::kHeaderEmojiSize, view->emojiFormat_)) ||
        FAILED(hr = format(installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets", DWRITE_FONT_WEIGHT_REGULAR,
                           M::kIconSize, view->iconFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    // One line, cut off at the end with "…" in the label's own font (SidebarLabel's
    // byTruncatingTail).
    const DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
    for (IDWriteTextFormat* f : {view->addressFormat_.Get(), view->headerFormat_.Get(), view->tabFormat_.Get(), view->folderFormat_.Get()}) {
        ComPtr<IDWriteInlineObject> ellipsis;
        if (SUCCEEDED(view->dwrite_->CreateEllipsisTrimmingSign(f, ellipsis.GetAddressOf()))) f->SetTrimming(&trimming, ellipsis.Get());
    }
    // Emoji and symbols sit in the middle of their box.
    for (IDWriteTextFormat* f : {view->emojiFormat_.Get(), view->iconFormat_.Get()}) {
        f->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    return view;
}

SidebarView::~SidebarView() { ReleaseGpu(); }

void SidebarView::UseCompositor(Compositor* compositor) {
    ReleaseGpu();
    compositor_ = compositor;
    deviceLost_ = false;
    dirty_ = true;
}

bool SidebarView::CreateGpu(std::wstring& error) {
    ComPtr<IDXGIDevice> dxgi;
    HRESULT hr = compositor_->GetRenderer().Device()->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
    if (SUCCEEDED(hr)) hr = d2dFactory_->CreateDevice(dxgi.Get(), d2dDevice_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = d2dDevice_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, context_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = context_->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Device()->CreateVisual(visual_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Chrome()->AddVisual(visual_.Get(), FALSE, nullptr);
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"creating the sidebar's Direct2D device", hr);
        ReleaseGpu();
        return false;
    }
    // Grayscale, as the Mac draws text on its translucent sidebar (ClearType needs an opaque
    // background).
    context_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    return true;
}

void SidebarView::ReleaseGpu() {
    faviconBitmaps_.clear();
    if (context_) context_->SetTarget(nullptr);
    if (visual_ && compositor_) {
        visual_->SetContent(nullptr);
        compositor_->Chrome()->RemoveVisual(visual_.Get());
    }
    visual_.Reset();
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    brush_.Reset();
    context_.Reset();
    d2dDevice_.Reset();
}

void SidebarView::Update(const BrowserState& state) {
    Model next;
    next.dark = !PrefersDarkForeground(state.SelectedSpace().theme);
    next.address = AddressFieldText(state);
    next.rows = SidebarRows(state, state.SelectedSpaceIndex());
    if (next == model_) return;
    model_ = std::move(next);
    Invalidate();
    // Rows moved under a still pointer: it now hovers whatever is there.
    ScrollTo(scroll_);
    RefreshHover();
}

void SidebarView::Layout(float width, UINT dpi) {
    // The height comes with the window's: Draw draws again only when it changes what's shown.
    if (width == width_ && dpi == dpi_) return;
    width_ = width;
    dpi_ = dpi;
    dirty_ = true;
}

void SidebarView::Invalidate() {
    dirty_ = true;
    if (!redrawPosted_) redrawPosted_ = PostMessageW(window_, kRedrawMessage, 0, 0) != FALSE;
}

bool SidebarView::HandleMessage(UINT message) {
    if (message != kRedrawMessage) return false;
    redrawPosted_ = false;
    if (dirty_ && compositor_) {
        if (std::wstring problem = Draw(); !problem.empty()) {
            OutputDebugStringW((L"Kite: the sidebar couldn't draw: " + problem + L"\n").c_str());
        } else {
            compositor_->Commit();
        }
    }
    return true;
}

std::wstring SidebarView::Draw(Pixels* readBack) {
    if (!compositor_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    RECT client{};
    GetClientRect(window_, &client);
    // Minimized: nothing to draw into until it's restored (onSize lays it out again).
    if (client.bottom <= 0 || client.right <= 0) return {};
    // The surface runs down to the last row, or to where the list is cut off above the space
    // bar, whichever is higher: a window resize that moves neither draws nothing.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    // A window made taller (or rows taken away) can leave the list scrolled past its end.
    scroll_ = std::clamp(scroll_, 0.0f, SidebarMaxScroll(model_.rows, static_cast<float>(client.bottom) / scale));
    const float contentBottom = M::kHeaderAreaHeight + SidebarContentHeight(model_.rows) - scroll_;
    const float listBottom = SidebarListBottom(static_cast<float>(client.bottom) / scale);
    const float bottom = std::max(M::kHeaderAreaHeight, std::min(contentBottom, listBottom));
    const UINT largest = compositor_->GetRenderer().MaxTextureSize();
    const UINT width = std::clamp(static_cast<UINT>(std::ceil(width_ * scale)), 1u, largest);
    const UINT height = std::clamp(static_cast<UINT>(std::ceil(bottom * scale)), 1u, largest);
    if (height != surfaceHeight_ || width != surfaceWidth_) dirty_ = true;
    if (!dirty_ && !readBack) return {};
    std::wstring error;
    if (!context_ && !CreateGpu(error)) return error;
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        if (context_) context_->SetTarget(nullptr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    if (!surface_) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating the sidebar's surface", hr);
        }
    } else if (width != surfaceWidth_ || height != surfaceHeight_) {
        if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the sidebar's surface", hr);
    }
    surfaceWidth_ = width;
    surfaceHeight_ = height;

    const D2D1_BITMAP_PROPERTIES1 targetProps =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), static_cast<float>(dpi_),
                                static_cast<float>(dpi_));
    // Into `surface` (a DirectComposition surface, or the capture's texture) at `offset` px.
    auto render = [&](IDXGISurface* surface, POINT offset) -> HRESULT {
        ComPtr<ID2D1Bitmap1> target;
        HRESULT made = context_->CreateBitmapFromDxgiSurface(surface, &targetProps, target.GetAddressOf());
        if (FAILED(made)) return made;
        context_->SetTarget(target.Get());
        context_->SetDpi(static_cast<float>(dpi_), static_cast<float>(dpi_));
        context_->BeginDraw();
        context_->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(offset.x) / scale, static_cast<float>(offset.y) / scale));
        // A surface's update can sit in a shared atlas: draw only inside it.
        context_->PushAxisAlignedClip(Rect(0, 0, static_cast<float>(width) / scale, static_cast<float>(height) / scale),
                                      D2D1_ANTIALIAS_MODE_ALIASED);
        context_->Clear(D2D1_COLOR_F{0, 0, 0, 0});
        for (auto& entry : faviconBitmaps_) entry.second.used = false;
        DrawContent(context_.Get());
        // Only the icons this draw showed stay on the GPU.
        std::erase_if(faviconBitmaps_, [](const auto& entry) { return !entry.second.used; });
        context_->PopAxisAlignedClip();
        made = context_->EndDraw();
        context_->SetTarget(nullptr);
        return made;
    };
    ComPtr<IDXGISurface> update;
    POINT offset{};
    if (FAILED(hr = surface_->BeginDraw(nullptr, IID_PPV_ARGS(update.GetAddressOf()), &offset))) {
        return fail(L"starting to draw the sidebar", hr);
    }
    hr = render(update.Get(), offset);
    const HRESULT ended = surface_->EndDraw();
    if (FAILED(hr)) return fail(L"drawing the sidebar", hr);
    if (FAILED(ended)) return fail(L"finishing the sidebar's surface", ended);
    dirty_ = false;

    if (readBack) {
        // The same drawing into a texture of its own, read back as DirectComposition shows it.
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        ComPtr<ID3D11Texture2D> texture;
        ComPtr<IDXGISurface> surface;
        if (FAILED(hr = compositor_->GetRenderer().Device()->CreateTexture2D(&desc, nullptr, texture.GetAddressOf())) ||
            FAILED(hr = texture.As(&surface)) || FAILED(hr = render(surface.Get(), POINT{}))) {
            return fail(L"drawing the sidebar for the capture", hr);
        }
        auto pixels = compositor_->GetRenderer().ReadBack(texture.Get(), error);
        if (!pixels) return error;
        *readBack = std::move(*pixels);
    }
    return {};
}

D2D1_COLOR_F SidebarView::Primary(float alpha) const {
    const float c = model_.dark ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

float SidebarView::Baseline(IDWriteTextFormat* format) {
    if (auto found = baselines_.find(format); found != baselines_.end()) return found->second;
    float baseline = format->GetFontSize() * 0.9f;
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    if (SUCCEEDED(dwrite_->CreateTextLayout(L"Ag", 2, format, 1000, 1000, layout.GetAddressOf())) &&
        SUCCEEDED(layout->GetLineMetrics(&line, 1, &count)) && count == 1) {
        baseline = line.baseline;
    }
    baselines_[format] = baseline;
    return baseline;
}

void SidebarView::DrawText(ID2D1DeviceContext* context, const std::string& text, IDWriteTextFormat* format, float x, float baseline,
                           float maxWidth, D2D1_COLOR_F color) {
    if (text.empty() || maxWidth <= 0) return;
    const std::wstring wide = Widen(text);
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, maxWidth, format->GetFontSize() * 2,
                                         layout.GetAddressOf()))) {
        return;
    }
    brush_->SetColor(color);
    context->DrawTextLayout(D2D1::Point2F(x, baseline - Baseline(format)), layout.Get(), brush_.Get(),
                            D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

void SidebarView::DrawGlyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color) {
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(&glyph, 1, iconFormat_.Get(), box.right - box.left, box.bottom - box.top, layout.GetAddressOf()))) {
        return;
    }
    const DWRITE_TEXT_RANGE all{0, 1};
    layout->SetFontSize(size, all);
    brush_->SetColor(color);
    context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get());
}

void SidebarView::DrawFavicon(ID2D1DeviceContext* context, const SidebarRow& row, D2D1_RECT_F box) {
    const float side = box.right - box.left;
    if (row.favicon.symbol) {
        // Kite's own pages: their symbol, fitted to the square.
        wchar_t glyph = kSettings;
        switch (*row.favicon.symbol) {
        case InternalPage::History: glyph = kHistory; break;
        case InternalPage::Archive: glyph = kArchive; break;
        case InternalPage::SiteSettings:
        case InternalPage::Settings: glyph = kSettings; break;
        case InternalPage::SearchEngines: glyph = kSearch; break;
        }
        DrawGlyph(context, glyph, side / kGlyphInk, box, Primary(kLabelAlpha * kSymbolOpacity));
        return;
    }
    if (row.favicon.url && favicons_) {
        const UINT px = static_cast<UINT>(std::lround(side * static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI));
        const auto key = std::make_pair(*row.favicon.url, px);
        // Asked every draw, so an icon on screen stays recently used in the cache.
        const Pixels* pixels = favicons_->Get(*row.favicon.url, px);
        auto found = faviconBitmaps_.find(key);
        if (found == faviconBitmaps_.end()) {
            if (pixels) {
                D2D1_BITMAP_PROPERTIES1 props{};
                props.pixelFormat = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
                props.dpiX = props.dpiY = static_cast<float>(dpi_);
                ComPtr<ID2D1Bitmap1> bitmap;
                if (SUCCEEDED(context->CreateBitmap(D2D1::SizeU(pixels->width, pixels->height), pixels->bgra.data(), pixels->width * 4,
                                                    &props, bitmap.GetAddressOf()))) {
                    found = faviconBitmaps_.emplace(key, FaviconBitmap{bitmap, false}).first;
                }
            }
        }
        if (found != faviconBitmaps_.end()) {
            found->second.used = true;
            // Stretched to the square, its corners rounded (FaviconImageView's layer).
            ComPtr<ID2D1BitmapBrush1> brush;
            const D2D1_BITMAP_BRUSH_PROPERTIES1 props{D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_INTERPOLATION_MODE_LINEAR};
            if (SUCCEEDED(context->CreateBitmapBrush(found->second.bitmap.Get(), &props, nullptr, brush.GetAddressOf()))) {
                const D2D1_SIZE_F size = found->second.bitmap->GetSize();
                brush->SetTransform(D2D1::Matrix3x2F::Scale(side / size.width, side / size.height) *
                                    D2D1::Matrix3x2F::Translation(box.left, box.top));
                const float corner = side * kFaviconCorner;
                context->FillRoundedRectangle(D2D1::RoundedRect(box, corner, corner), brush.Get());
                return;
            }
        }
    }
    // No icon (yet): the globe, stretched to the square.
    DrawGlyph(context, kGlobe, side / kGlyphInk, box, Primary(kLabelAlpha * kGlobeOpacity));
}

void SidebarView::DrawRow(ID2D1DeviceContext* context, const SidebarRow& row, float top, bool hovered) {
    const float left = M::kPadding, right = width_ - M::kPadding;  // the row, in window points
    // The pill sits 2.5pt into its row: whole pixels at 2x as on the Mac's screens, snapped to
    // them at other scales so its edges and the favicon stay sharp.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    auto snap = [scale](float points) { return std::round(points * scale) / scale; };
    const float pillTop = snap(top + (M::kRowPitch - M::kPillHeight) / 2);
    const float pillBottom = snap(pillTop + M::kPillHeight);
    // The favicon's square, a whole number of pixels on the pixel grid.
    const float iconSide = std::round(M::kIconSize * scale) / scale;
    auto washPill = [&](D2D1_COLOR_F color) {
        brush_->SetColor(color);
        context->FillRoundedRectangle(D2D1::RoundedRect(Rect(snap(left), pillTop, snap(right), pillBottom), M::kCornerRadius, M::kCornerRadius),
                                      brush_.Get());
    };
    // chromeFill(hoverFill): the folder's and New Tab's hover.
    const D2D1_COLOR_F hoverWash{1, 1, 1, model_.dark ? M::kHoverFill : std::min(M::kHoverFill * 3.5f, 0.7f)};
    auto faviconBox = [&](float x) {
        const float iconLeft = snap(x), iconTop = snap(pillTop + (M::kPillHeight - M::kIconSize) / 2);
        return Rect(iconLeft, iconTop, iconLeft + iconSide, iconTop + iconSide);
    };
    const float tabLine = LineHeight(M::kTabFontSize);
    const float tabBaseline = pillTop + TextTop(M::kPillHeight, tabLine) + M::kTabFontSize * kAscender;
    switch (row.kind) {
    case SidebarRow::Kind::Header: {
        // An icon-less space has no icon slot: its name starts at the icon's place.
        float x = M::kHeaderIconX;
        const D2D1_RECT_F iconBox = Rect(x, top + M::kHeaderIconTop, x + M::kHeaderIconSize, top + M::kHeaderIconTop + M::kHeaderIconSize);
        if (!row.icon.empty()) {
            // An emoji is drawn; SF Symbols and pictures keep their slot for now.
            if (!row.icon.starts_with("symbol:") && !row.icon.starts_with("image:")) {
                const std::wstring icon = Widen(row.icon);
                ComPtr<IDWriteTextLayout> layout;
                if (SUCCEEDED(dwrite_->CreateTextLayout(icon.c_str(), static_cast<UINT32>(icon.size()), emojiFormat_.Get(), M::kHeaderIconSize,
                                                        M::kHeaderIconSize, layout.GetAddressOf()))) {
                    brush_->SetColor(Primary(1));
                    context->DrawTextLayout(D2D1::Point2F(iconBox.left, iconBox.top), layout.Get(), brush_.Get(),
                                            D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                }
            }
            x = M::kHeaderTextX;
        }
        float end = right;
        if (row.hasPinned) {
            // The chevron's slot: shown while the pinned tabs are collapsed (and on hover).
            end -= M::kIconInset - M::kPadding;
            end -= M::kHeaderIconSize;
            // Collapsed it shows; expanded, only while the header is hovered, turned down.
            if (row.pinnedCollapsed || hovered) {
                DrawGlyph(context, row.pinnedCollapsed ? kChevronRight : kChevronDown, 9 / kGlyphInk,
                          Rect(end, iconBox.top, end + M::kHeaderIconSize, iconBox.bottom), Primary(kLabelAlpha * kHeaderChevronOpacity));
            }
            end -= kHeaderGap;
        }
        end -= kHeaderGap;
        const float line = LineHeight(M::kHeaderFontSize);
        const float baseline = iconBox.top + std::floor((M::kHeaderIconSize - line) / 2) + M::kHeaderFontSize * kAscender;
        DrawText(context, row.title, headerFormat_.Get(), x, baseline, end - x, Primary(kLabelAlpha * M::kHeaderTextOpacity));
        break;
    }
    case SidebarRow::Kind::Tab: {
        if (row.selected) {
            // White on both appearances: 20% on a dark theme, 85% on a light one.
            washPill(D2D1_COLOR_F{1, 1, 1, model_.dark ? M::kSelectedFill : M::kSelectedFillLight});
        } else if (hovered) {
            washPill(model_.dark ? D2D1_COLOR_F{1, 1, 1, M::kHoverFill} : M::kHoverWashLight);
        }
        const float x = left + M::kIconInset + static_cast<float>(row.depth) * M::kNestingIndent;
        DrawFavicon(context, row, faviconBox(x));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        // Nothing trails a tab that isn't hovered: the title runs to 6pt and a gap from the end.
        const float textEnd = right - 6 - M::kIconTextGap;
        DrawText(context, row.title, tabFormat_.Get(), textX, tabBaseline, textEnd - textX, Primary(kLabelAlpha * M::kTabTextOpacity));
        break;
    }
    case SidebarRow::Kind::Folder: {
        if (hovered) washPill(hoverWash);
        const float x = left + M::kIconInset + static_cast<float>(row.depth) * M::kNestingIndent;
        // folder (open) or folder.fill (closed) at 14pt in the favicon's square.
        DrawGlyph(context, row.expanded ? kFolder : kFolderFill, 14 / kGlyphInk, faviconBox(x), Primary(kLabelAlpha * kFolderIconOpacity));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        const float textEnd = right - M::kIconInset - kFolderChevronWidth - M::kIconTextGap - M::kIconTextGap;
        DrawText(context, row.title, folderFormat_.Get(), textX, tabBaseline, textEnd - textX, Primary(kLabelAlpha * M::kTabTextOpacity));
        if (hovered) {
            // Its chevron, at the pill's end: turned down while it's open.
            const float centerX = right - M::kIconInset - kFolderChevronWidth / 2, centerY = (pillTop + pillBottom) / 2;
            DrawGlyph(context, row.expanded ? kChevronDown : kChevronRight, 9 / kGlyphInk,
                      Rect(centerX - M::kIconSize / 2, centerY - M::kIconSize / 2, centerX + M::kIconSize / 2, centerY + M::kIconSize / 2),
                      Primary(kLabelAlpha * kFolderChevronOpacity));
        }
        break;
    }
    case SidebarRow::Kind::Divider:
        if (row.showsLine) {
            // labelColor at 8% (its own alpha replaced, not multiplied).
            brush_->SetColor(Primary(M::kDividerOpacity));
            const float y = top + (M::kDividerRowHeight - M::kDividerThickness) / 2;
            context->FillRectangle(Rect(left + M::kDividerInset, y, right - M::kDividerInset, y + M::kDividerThickness), brush_.Get());
        }
        break;
    case SidebarRow::Kind::NewTab: {
        if (hovered) washPill(hoverWash);
        const float x = left + M::kIconInset;
        DrawGlyph(context, kPlus, 14 / kGlyphInk, faviconBox(x), Primary(kLabelAlpha * kNewTabOpacity));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        DrawText(context, row.title, tabFormat_.Get(), textX, tabBaseline, right - M::kIconInset - textX, Primary(kLabelAlpha * kNewTabOpacity));
        break;
    }
    }
}

void SidebarView::DrawContent(ID2D1DeviceContext* context) {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float height = static_cast<float>(surfaceHeight_) / scale;
    const float left = M::kPadding, right = width_ - M::kPadding;

    // The address field: the white wash (stronger on a light theme) and the host.
    const float fieldTop = M::kTopRowY + M::kTopRowHeight + M::kUrlFieldTopGap;
    brush_->SetColor(D2D1_COLOR_F{1, 1, 1, model_.dark ? M::kFieldFill : std::min(M::kFieldFill * 3.5f, 0.7f)});
    context->FillRoundedRectangle(D2D1::RoundedRect(Rect(left, fieldTop, right, fieldTop + M::kUrlFieldHeight), M::kCornerRadius,
                                                    M::kCornerRadius),
                                  brush_.Get());
    const float addressLine = LineHeight(M::kUrlFieldFontSize);
    const float addressBaseline = fieldTop + std::floor((M::kUrlFieldHeight - addressLine) / 2) + M::kUrlFieldFontSize * kAscender;
    const float addressX = left + M::kUrlFieldTextInset;
    // With no buttons in the field, the text runs to 2pt from its end (SidebarHeader's layout).
    DrawText(context, model_.address, addressFormat_.Get(), addressX, addressBaseline, right - 2 - addressX,
             Primary(kLabelAlpha * M::kUrlFieldTextOpacity));

    // The space's page, under the header and above the space bar (where Draw ends the
    // surface); rows past it are cut off (the Mac's list scrolls there).
    const float listTop = M::kHeaderAreaHeight;
    const float listBottom = std::max(listTop, height);
    context->PushAxisAlignedClip(Rect(0, listTop, width_, listBottom), D2D1_ANTIALIAS_MODE_ALIASED);
    for (size_t i = 0; i < model_.rows.size(); ++i) {
        const SidebarRow& row = model_.rows[i];
        const float top = listTop + row.top - scroll_;
        if (top >= listBottom) break;
        if (top + row.height <= listTop) continue;
        const bool hovered = (hover_.target == SidebarHit::Target::Row || hover_.target == SidebarHit::Target::PinnedChevron) && hover_.row == i;
        DrawRow(context, row, top, hovered);
    }
    context->PopAxisAlignedClip();
}

// Pointer --------------------------------------------------------------------------------

D2D1_POINT_2F SidebarView::PointOf(POINT client) const {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    return D2D1_POINT_2F{static_cast<float>(client.x) / scale, static_cast<float>(client.y) / scale};
}

float SidebarView::Height() const {
    RECT client{};
    GetClientRect(window_, &client);
    return static_cast<float>(client.bottom) / (static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI);
}

SidebarHit SidebarView::HitAt(D2D1_POINT_2F p) const {
    if (p.x < 0 || p.x >= width_) return {};
    return SidebarHitTest(model_.rows, width_, Height(), scroll_, p.x, p.y);
}

void SidebarView::RefreshHover() {
    SidebarHit hit = pointer_ ? HitAt(PointOf(*pointer_)) : SidebarHit{};
    // The address field has no hover of its own yet (its buttons come with the toolbar).
    if (hit.target == SidebarHit::Target::AddressField) hit = {};
    if (hit == hover_) return;
    hover_ = hit;
    Invalidate();
}

void SidebarView::ClearHover() {
    pointer_.reset();
    pressed_ = {};
    RefreshHover();
}

void SidebarView::ScrollTo(float scroll) {
    // Whole pixels, so the rows keep their crisp edges.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float clamped = std::clamp(scroll, 0.0f, SidebarMaxScroll(model_.rows, Height()));
    const float snapped = std::round(clamped * scale) / scale;
    if (snapped == scroll_) return;
    scroll_ = snapped;
    Invalidate();
    RefreshHover();
}

void SidebarView::Tap(const SidebarRow& row) {
    // The Mac's tapped(at:): a tab selects, a folder opens or closes, New Tab opens the bar.
    // (A click on the space's name renames it, which comes with renaming.)
    switch (row.kind) {
    case SidebarRow::Kind::Tab:
        if (actions_.selectTab) actions_.selectTab(row.id);
        break;
    case SidebarRow::Kind::Folder:
        if (actions_.setFolderExpanded) actions_.setFolderExpanded(row.id, !row.expanded);
        break;
    case SidebarRow::Kind::NewTab:
        if (actions_.newTab) actions_.newTab();
        break;
    case SidebarRow::Kind::Header:
    case SidebarRow::Kind::Divider:
        break;
    }
}

bool SidebarView::HandleMouse(UINT message, WPARAM wParam, LPARAM lParam) {
    using Target = SidebarHit::Target;
    switch (message) {
    case WM_MOUSEMOVE: {
        if (!trackingLeave_) {
            TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, window_, 0};
            trackingLeave_ = TrackMouseEvent(&track) != FALSE;
        }
        pointer_ = POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        RefreshHover();
        return false;
    }
    case WM_MOUSELEAVE:
        trackingLeave_ = false;
        pointer_.reset();
        RefreshHover();
        return false;
    case WM_LBUTTONDOWN: {
        const POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        const D2D1_POINT_2F p = PointOf(at);
        if (p.x < 0 || p.x >= width_) return false;
        // NSEvent's clickCount: presses within the double-click time and distance count up.
        const DWORD time = static_cast<DWORD>(GetMessageTime());
        const bool again = clicks_ > 0 && time - lastClickTime_ <= GetDoubleClickTime() &&
                           std::abs(at.x - lastClickAt_.x) <= GetSystemMetrics(SM_CXDOUBLECLK) / 2 &&
                           std::abs(at.y - lastClickAt_.y) <= GetSystemMetrics(SM_CYDOUBLECLK) / 2;
        clicks_ = again ? clicks_ + 1 : 1;
        lastClickTime_ = time;
        lastClickAt_ = at;
        pressed_ = HitAt(p);
        pressedClicks_ = clicks_;
        if (pressed_.target != Target::None) SetCapture(window_);
        return true;
    }
    case WM_LBUTTONUP: {
        const SidebarHit pressed = pressed_;
        pressed_ = {};
        if (pressed.target == Target::None) return false;
        if (GetCapture() == window_) ReleaseCapture();
        const D2D1_POINT_2F p = PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
        // As the Mac's mouseUp: on release, over what was pressed.
        switch (pressed.target) {
        case Target::AddressField:
            if (HitAt(p).target == Target::AddressField && actions_.editAddress) actions_.editAddress();
            break;
        case Target::PinnedChevron:
            if (HitAt(p) == pressed && pressed.row < model_.rows.size() && actions_.togglePinnedSection) {
                actions_.togglePinnedSection(model_.rows[pressed.row].id);
            }
            break;
        case Target::Row: {
            // A second click of a double-click doesn't tap again (it renames, which comes later).
            if (pressedClicks_ > 1 || pressed.row >= model_.rows.size()) break;
            if (p.x < 0 || p.x >= width_) break;
            if (SidebarRowAt(model_.rows, width_, Height(), scroll_, p.x, p.y) != pressed.row) break;
            const SidebarRow row = model_.rows[pressed.row];  // the action rebuilds the rows
            Tap(row);
            break;
        }
        case Target::None:
            break;
        }
        return true;
    }
    case WM_CAPTURECHANGED:
        pressed_ = {};
        return false;
    case WM_MOUSEWHEEL: {
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};  // screen coordinates
        ScreenToClient(window_, &at);
        const D2D1_POINT_2F p = PointOf(at);
        const float height = Height();
        if (p.x < 0 || p.x >= width_ || p.y < M::kHeaderAreaHeight || p.y >= SidebarListBottom(height)) return false;
        UINT lines = 3;
        if (!SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0)) lines = 3;
        const float notches = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        const float distance = lines == WHEEL_PAGESCROLL ? notches * (SidebarListBottom(height) - M::kHeaderAreaHeight)
                                                         : notches * static_cast<float>(lines) * kWheelLine;
        pointer_ = at;
        ScrollTo(scroll_ - distance);
        return true;
    }
    default:
        return false;
    }
}

}  // namespace kite
