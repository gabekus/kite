// See CaptionButtonsView.h.

#include "shell/CaptionButtonsView.h"

#include "shell/MainWindow.h"

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/SystemFont.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace T = title_bar;

// Segoe Fluent Icons' (and Segoe MDL2 Assets') Chrome glyphs, in glyphs_'s order.
constexpr wchar_t kGlyphs[4] = {0xE921, 0xE922, 0xE923, 0xE8BB};  // minimize, maximize, restore, close
enum Glyph { kMinimize, kMaximize, kRestore, kClose };

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

}  // namespace

std::unique_ptr<CaptionButtonsView> CaptionButtonsView::Create(HWND window, std::wstring& error) {
    std::unique_ptr<CaptionButtonsView> view(new CaptionButtonsView(window));
    ComPtr<IDWriteFactory> dwrite;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"DWriteCreateFactory", hr);
        return nullptr;
    }
    // Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets (the same code points) on Windows 10.
    ComPtr<IDWriteTextFormat> format;
    hr = system_font::CreateIconFormat(dwrite.Get(), system_font::IconFont::Symbols, DWRITE_FONT_WEIGHT_REGULAR, T::kGlyphSize, format);
    if (SUCCEEDED(hr)) hr = format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    if (SUCCEEDED(hr)) hr = format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    for (int g = 0; g < 4 && SUCCEEDED(hr); ++g) {
        hr = dwrite->CreateTextLayout(&kGlyphs[g], 1, format.Get(), T::kButtonWidth, T::kButtonHeight, view->glyphs_[g].GetAddressOf());
    }
    if (FAILED(hr)) {
        error = HResultMessage(L"laying out the caption glyphs", hr);
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
    HRESULT hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Device()->CreateVisual(visual_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Chrome()->AddVisual(visual_.Get(), TRUE, nullptr);
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"creating the caption buttons' visual", hr);
        ReleaseGpu();
        return false;
    }
    return true;
}

void CaptionButtonsView::ReleaseGpu() {
    if (visual_ && compositor_) {
        visual_->SetContent(nullptr);
        compositor_->Chrome()->RemoveVisual(visual_.Get());
    }
    visual_.Reset();
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    offsetX_ = -1;
    brush_.Reset();
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
}

void CaptionButtonsView::Refresh() {
    if (!dirty_ || !compositor_) return;
    if (std::wstring problem = Draw(); !problem.empty()) {
        OutputDebugStringW((L"Kite: the caption buttons couldn't draw: " + problem + L"\n").c_str());
        if (deviceLost_ && onDeviceLost) onDeviceLost();
    } else {
        compositor_->Commit();
    }
}

void CaptionButtonsView::SetHover(std::optional<CaptionButton> hovered) {
    if (hovered == hovered_) return;
    hovered_ = hovered;
    dirty_ = true;
}

bool CaptionButtonsView::HandleMessage(UINT message, WPARAM wParam, LPARAM, LRESULT& result) {
    switch (message) {
    case WM_NCMOUSEMOVE:
        {
            // Every move: another TrackMouseEvent (the sidebar's) can replace this one.
            TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, window_, 0};
            TrackMouseEvent(&track);
        }
        SetHover(CaptionButtonOfHit(wParam));
        Refresh();
        return false;  // DefWindowProc too: Windows 11's Snap Layouts follow the pointer
    case WM_NCMOUSELEAVE:
        SetHover(std::nullopt);
        if (pressed_) {
            pressed_.reset();
            dirty_ = true;
        }
        Refresh();
        return false;
    case WM_MOUSEMOVE:
        // Into the client area: off the buttons (WM_NCMOUSELEAVE can come after it).
        SetHover(std::nullopt);
        Refresh();
        return false;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK: {
        // Kite's own buttons: DefWindowProc would run its modal loop over the classic ones.
        const auto button = CaptionButtonOfHit(wParam);
        if (!button) return false;
        pressed_ = button;
        hovered_ = button;
        dirty_ = true;
        Refresh();
        result = 0;
        return true;
    }
    case WM_NCLBUTTONUP: {
        const auto button = CaptionButtonOfHit(wParam);
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

void CaptionButtonsView::DrawContent(ID2D1DeviceContext* context, UINT width) {
    const Tone& tone = dark_ ? kDark : kLight;
    const float ink = dark_ ? 1.0f : 0.0f;
    const CaptionButton buttons[] = {CaptionButton::Minimize, CaptionButton::Maximize, CaptionButton::Close};
    const Glyph glyphs[] = {kMinimize, maximized_ ? kRestore : kMaximize, kClose};
    // Each button's edges on whole pixels, counted from the right edge (as Windows 11's own are
    // at 125% and 175%, where 46 points isn't a whole number of pixels).
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    auto edge = [&](int fromRight) { return static_cast<float>(width) / scale - CaptionEdgeFromRight(fromRight, scale); };
    for (size_t i = 0; i < 3; ++i) {
        const CaptionButton button = buttons[i];
        const float left = edge(3 - static_cast<int>(i)), right = edge(2 - static_cast<int>(i));
        const D2D1_RECT_F box{left, 0, right, T::kButtonHeight};
        // Pressed shows only while the pointer is still on the pressed button; hover shows on
        // none other while one is pressed.
        const bool hovered = hovered_ == button && (!pressed_ || pressed_ == button);
        const bool pressed = pressed_ == button && hovered_ == button;
        D2D1_COLOR_F glyphColor{ink, ink, ink, active_ ? tone.primary : tone.disabled};
        if (button == CaptionButton::Close && hovered) {
            D2D1_COLOR_F fill = kCloseFill;
            if (pressed) fill.a = kClosePressedFill;
            brush_->SetColor(fill);
            context->FillRectangle(box, brush_.Get());
            glyphColor = D2D1_COLOR_F{1, 1, 1, pressed ? kClosePressedGlyph : 1.0f};
        } else if (hovered) {
            brush_->SetColor(D2D1_COLOR_F{ink, ink, ink, pressed ? tone.press : tone.hover});
            context->FillRectangle(box, brush_.Get());
            if (pressed) glyphColor.a = tone.secondary;
        }
        // The glyph centred in its button, its layout box on a whole pixel.
        const float glyphLeft = std::round(((left + right) / 2 - T::kButtonWidth / 2) * scale) / scale;
        brush_->SetColor(glyphColor);
        context->DrawTextLayout(D2D1::Point2F(glyphLeft, 0), glyphs_[glyphs[i]].Get(), brush_.Get());
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
    if (!visual_ && !CreateGpu(error)) return error;
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
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
    error = compositor_->DrawSurface(
        perf::View::CaptionButtons, surface_.Get(), width, height, dpi_, [&](ID2D1DeviceContext* context) { DrawContent(context, width); }, readBack, hr);
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"the caption buttons: " + error;
    }
    dirty_ = false;
    if (readBack && origin) *origin = POINT{offsetX, 0};
    return {};
}

}  // namespace kite
