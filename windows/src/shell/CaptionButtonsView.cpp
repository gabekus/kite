// See CaptionButtonsView.h.

#include "shell/CaptionButtonsView.h"

#include <d3d11.h>

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace T = title_bar;

// Segoe Fluent Icons' (and Segoe MDL2 Assets') Chrome glyphs.
constexpr wchar_t kMinimizeGlyph = 0xE921;
constexpr wchar_t kMaximizeGlyph = 0xE922;
constexpr wchar_t kRestoreGlyph = 0xE923;
constexpr wchar_t kCloseGlyph = 0xE8BB;

// WinUI's caption button colours (TitleBar's CaptionButton resources): the glyph in
// TextFillColorPrimary, dimmed to TextFillColorDisabled while the window is inactive and to
// TextFillColorSecondary while pressed; hover and press fills SubtleFillColorSecondary and
// Tertiary; close turns #C42B1C with a white glyph.
struct Tone {
    float primary, disabled, secondary;  // the glyph's alpha
    float hover, press;                   // the fill's alpha
};
constexpr Tone kLight{0.894f, 0.361f, 0.620f, 0.035f, 0.024f};  // black glyphs, on a light theme
constexpr Tone kDark{1.0f, 0.365f, 0.773f, 0.059f, 0.039f};     // white glyphs, on a dark one
constexpr D2D1_COLOR_F kCloseFill{0xC4 / 255.0f, 0x2B / 255.0f, 0x1C / 255.0f, 1};
constexpr float kClosePressedFill = 0.9f;
constexpr float kClosePressedGlyph = 0.7f;

bool IsDeviceLost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == static_cast<HRESULT>(D2DERR_RECREATE_TARGET);
}

std::optional<CaptionButton> ButtonOfHit(WPARAM hit) {
    switch (hit) {
    case HTMINBUTTON: return CaptionButton::Minimize;
    case HTMAXBUTTON: return CaptionButton::Maximize;
    case HTCLOSE: return CaptionButton::Close;
    default: return std::nullopt;
    }
}

}  // namespace

std::unique_ptr<CaptionButtonsView> CaptionButtonsView::Create(HWND window, std::wstring& error) {
    std::unique_ptr<CaptionButtonsView> view(new CaptionButtonsView(window));
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), nullptr,
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
    // Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets (the same code points) on Windows 10.
    ComPtr<IDWriteFontCollection> fonts;
    view->dwrite_->GetSystemFontCollection(fonts.GetAddressOf());
    UINT32 index = 0;
    BOOL fluent = FALSE;
    if (fonts) fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &fluent);
    hr = view->dwrite_->CreateTextFormat(fluent ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets", nullptr, DWRITE_FONT_WEIGHT_REGULAR,
                                         DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, T::kGlyphSize, L"",
                                         view->glyphFormat_.GetAddressOf());
    if (SUCCEEDED(hr)) hr = view->glyphFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    if (SUCCEEDED(hr)) hr = view->glyphFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    view->active_ = GetActiveWindow() == window;
    view->maximized_ = IsZoomed(window) != FALSE;
    return view;
}

CaptionButtonsView::~CaptionButtonsView() { ReleaseGpu(); }

void CaptionButtonsView::UseCompositor(Compositor* compositor) {
    ReleaseGpu();
    compositor_ = compositor;
    deviceLost_ = false;
    dirty_ = true;
}

bool CaptionButtonsView::CreateGpu(std::wstring& error) {
    ComPtr<IDXGIDevice> dxgi;
    HRESULT hr = compositor_->GetRenderer().Device()->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
    if (SUCCEEDED(hr)) hr = d2dFactory_->CreateDevice(dxgi.Get(), d2dDevice_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = d2dDevice_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, context_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = context_->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Device()->CreateVisual(visual_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Chrome()->AddVisual(visual_.Get(), TRUE, nullptr);
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"creating the caption buttons' Direct2D device", hr);
        ReleaseGpu();
        return false;
    }
    context_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    return true;
}

void CaptionButtonsView::ReleaseGpu() {
    if (context_) context_->SetTarget(nullptr);
    if (visual_ && compositor_) {
        visual_->SetContent(nullptr);
        compositor_->Chrome()->RemoveVisual(visual_.Get());
    }
    visual_.Reset();
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    offsetX_ = -1;
    brush_.Reset();
    context_.Reset();
    d2dDevice_.Reset();
}

void CaptionButtonsView::Layout(UINT dpi) {
    const bool maximized = IsZoomed(window_) != FALSE;
    if (dpi != dpi_ || maximized != maximized_) dirty_ = true;
    dpi_ = dpi;
    maximized_ = maximized;
}

void CaptionButtonsView::SetDark(bool dark) {
    if (dark == dark_) return;
    dark_ = dark;
    dirty_ = true;
    Refresh();
}

void CaptionButtonsView::Refresh() {
    if (!dirty_ || !compositor_) return;
    if (std::wstring problem = Draw(); !problem.empty()) {
        OutputDebugStringW((L"Kite: the caption buttons couldn't draw: " + problem + L"\n").c_str());
    } else {
        compositor_->Commit();
    }
}

bool CaptionButtonsView::HandleMessage(UINT message, WPARAM wParam, LPARAM, LRESULT& result) {
    auto setHover = [&](std::optional<CaptionButton> hovered) {
        if (hovered == hovered_) return;
        hovered_ = hovered;
        dirty_ = true;
    };
    switch (message) {
    case WM_NCMOUSEMOVE:
        if (!trackingLeave_) {
            TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, window_, 0};
            trackingLeave_ = TrackMouseEvent(&track) != FALSE;
        }
        setHover(ButtonOfHit(wParam));
        Refresh();
        return false;  // DefWindowProc too: Windows 11's Snap Layouts follow the pointer
    case WM_NCMOUSELEAVE:
        trackingLeave_ = false;
        setHover(std::nullopt);
        if (pressed_) {
            pressed_.reset();
            dirty_ = true;
        }
        Refresh();
        return false;
    case WM_MOUSEMOVE:
        // Into the client area: off the buttons (WM_NCMOUSELEAVE can come after it).
        setHover(std::nullopt);
        Refresh();
        return false;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK: {
        // Kite's own buttons: DefWindowProc would run its modal loop over the classic ones.
        const auto button = ButtonOfHit(wParam);
        if (!button) return false;
        pressed_ = button;
        hovered_ = button;
        dirty_ = true;
        Refresh();
        result = 0;
        return true;
    }
    case WM_NCLBUTTONUP: {
        const auto button = ButtonOfHit(wParam);
        const auto pressed = pressed_;
        if (pressed_) {
            pressed_.reset();
            dirty_ = true;
            Refresh();
        }
        if (!button) return false;
        // As a button does: released over the one pressed.
        if (pressed == button) {
            WPARAM command = SC_CLOSE;
            if (*button == CaptionButton::Minimize) command = SC_MINIMIZE;
            if (*button == CaptionButton::Maximize) command = IsZoomed(window_) ? SC_RESTORE : SC_MAXIMIZE;
            PostMessageW(window_, WM_SYSCOMMAND, command, 0);
        }
        result = 0;
        return true;
    }
    case WM_ACTIVATE: {
        const bool active = LOWORD(wParam) != WA_INACTIVE;
        if (active != active_) {
            active_ = active;
            dirty_ = true;
            Refresh();
        }
        return false;
    }
    default:
        return false;
    }
}

void CaptionButtonsView::DrawContent(ID2D1DeviceContext* context) {
    const Tone& tone = dark_ ? kDark : kLight;
    const float ink = dark_ ? 1.0f : 0.0f;
    const struct {
        CaptionButton button;
        wchar_t glyph;
    } buttons[] = {{CaptionButton::Minimize, kMinimizeGlyph},
                   {CaptionButton::Maximize, maximized_ ? kRestoreGlyph : kMaximizeGlyph},
                   {CaptionButton::Close, kCloseGlyph}};
    for (size_t i = 0; i < 3; ++i) {
        const auto& [button, glyph] = buttons[i];
        const float left = static_cast<float>(i) * T::kButtonWidth;
        const D2D1_RECT_F box{left, 0, left + T::kButtonWidth, T::kButtonHeight};
        const bool hovered = hovered_ == button && (!pressed_ || pressed_ == button);
        const bool pressed = pressed_ == button && hovered_ == button;
        D2D1_COLOR_F glyphColor{ink, ink, ink, active_ ? tone.primary : tone.disabled};
        if (button == CaptionButton::Close && (hovered || pressed)) {
            D2D1_COLOR_F fill = kCloseFill;
            if (pressed) fill.a = kClosePressedFill;
            brush_->SetColor(fill);
            context->FillRectangle(box, brush_.Get());
            glyphColor = D2D1_COLOR_F{1, 1, 1, pressed ? kClosePressedGlyph : 1.0f};
        } else if (hovered || pressed) {
            brush_->SetColor(D2D1_COLOR_F{ink, ink, ink, pressed ? tone.press : tone.hover});
            context->FillRectangle(box, brush_.Get());
            if (pressed) glyphColor.a = tone.secondary;
        }
        ComPtr<IDWriteTextLayout> layout;
        if (FAILED(dwrite_->CreateTextLayout(&glyph, 1, glyphFormat_.Get(), T::kButtonWidth, T::kButtonHeight, layout.GetAddressOf()))) {
            continue;
        }
        brush_->SetColor(glyphColor);
        context->DrawTextLayout(D2D1::Point2F(left, 0), layout.Get(), brush_.Get());
    }
}

std::wstring CaptionButtonsView::Draw(Pixels* readBack, POINT* origin) {
    if (!compositor_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    RECT client{};
    GetClientRect(window_, &client);
    if (client.bottom <= 0 || client.right <= 0) return {};  // minimized
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const UINT width = std::max(1u, static_cast<UINT>(std::ceil(T::kButtonsWidth * scale)));
    const UINT height = std::max(1u, static_cast<UINT>(std::ceil(T::kButtonHeight * scale)));
    // Flush with the client area's right edge.
    const int offsetX = static_cast<int>(client.right) - static_cast<int>(width);
    if (width != surfaceWidth_ || height != surfaceHeight_) dirty_ = true;
    if (!dirty_ && !readBack && offsetX == offsetX_) return {};
    std::wstring error;
    if (!context_ && !CreateGpu(error)) return error;
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        if (context_) context_->SetTarget(nullptr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    if (offsetX != offsetX_) {
        if (FAILED(hr = visual_->SetOffsetX(static_cast<float>(offsetX)))) return fail(L"placing the caption buttons", hr);
        offsetX_ = offsetX;
    }
    if (!surface_) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating the caption buttons' surface", hr);
        }
    } else if (width != surfaceWidth_ || height != surfaceHeight_) {
        if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the caption buttons' surface", hr);
    }
    surfaceWidth_ = width;
    surfaceHeight_ = height;
    if (!dirty_ && !readBack) return {};

    const float dpi = static_cast<float>(dpi_);
    const D2D1_BITMAP_PROPERTIES1 targetProps =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
    auto render = [&](IDXGISurface* surface, POINT offset) -> HRESULT {
        ComPtr<ID2D1Bitmap1> target;
        HRESULT made = context_->CreateBitmapFromDxgiSurface(surface, &targetProps, target.GetAddressOf());
        if (FAILED(made)) return made;
        context_->SetTarget(target.Get());
        context_->SetDpi(dpi, dpi);
        context_->BeginDraw();
        context_->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(offset.x) / scale, static_cast<float>(offset.y) / scale));
        // A surface's update can sit in a shared atlas: draw only inside it.
        context_->PushAxisAlignedClip(D2D1_RECT_F{0, 0, static_cast<float>(width) / scale, static_cast<float>(height) / scale},
                                      D2D1_ANTIALIAS_MODE_ALIASED);
        context_->Clear(D2D1_COLOR_F{0, 0, 0, 0});
        // Right-aligned: a surface rounded up to whole pixels puts its spare fraction on the left.
        context_->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(offset.x) / scale + static_cast<float>(width) / scale - T::kButtonsWidth,
                                                             static_cast<float>(offset.y) / scale));
        DrawContent(context_.Get());
        context_->PopAxisAlignedClip();
        made = context_->EndDraw();
        context_->SetTarget(nullptr);
        return made;
    };
    ComPtr<IDXGISurface> update;
    POINT offset{};
    if (FAILED(hr = surface_->BeginDraw(nullptr, IID_PPV_ARGS(update.GetAddressOf()), &offset))) {
        return fail(L"starting to draw the caption buttons", hr);
    }
    hr = render(update.Get(), offset);
    const HRESULT ended = surface_->EndDraw();
    if (FAILED(hr)) return fail(L"drawing the caption buttons", hr);
    if (FAILED(ended)) return fail(L"finishing the caption buttons' surface", ended);
    dirty_ = false;

    if (readBack) {
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
            return fail(L"drawing the caption buttons for the capture", hr);
        }
        auto pixels = compositor_->GetRenderer().ReadBack(texture.Get(), error);
        if (!pixels) return error;
        *readBack = std::move(*pixels);
        if (origin) *origin = POINT{offsetX, 0};
    }
    return {};
}

}  // namespace kite
