#include "shell/SpaceTipView.h"

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace T = space_tip_metrics;

constexpr wchar_t kClassName[] = L"KiteSpaceTip";
// face.smiling, the profile chip's face: Fluent's and MDL2's Emoji2 (the PC's cmap check).
constexpr wchar_t kFace[] = L"";

D2D1_COLOR_F White(float alpha) { return D2D1_COLOR_F{1, 1, 1, alpha}; }
D2D1_COLOR_F Opaque(const ThemeColor& c) { return D2D1_COLOR_F{c.r, c.g, c.b, 1}; }

bool RegisterOnce(HINSTANCE instance, WNDPROC proc) {
    static const bool registered = [&] {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = proc;
        wc.hInstance = instance;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kClassName;
        return RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
    }();
    return registered;
}

}  // namespace

std::unique_ptr<SpaceTipView> SpaceTipView::Create(HWND owner, IDWriteFactory* dwrite, std::wstring& error) {
    std::unique_ptr<SpaceTipView> view(new SpaceTipView(owner, dwrite));
    // SF Pro's stand-in, as the sidebar's: Segoe UI Variable on Windows 11, Segoe UI before it.
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    const wchar_t* text = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    const wchar_t* icons = installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    auto format = [&](const wchar_t* family, DWRITE_FONT_WEIGHT weight, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = dwrite->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"",
                                                out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    HRESULT hr = S_OK;
    if (FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, T::kNameFontSize, view->nameFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, T::kChipFontSize, view->chipFormat_)) ||
        FAILED(hr = format(icons, DWRITE_FONT_WEIGHT_SEMI_BOLD, T::kChipSymbolSize, view->chipSymbolFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_BOLD, T::kKeyFontSize, view->keyFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    const HINSTANCE instance = reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(owner, GWLP_HINSTANCE));
    if (!RegisterOnce(instance, &SpaceTipView::WindowProc)) {
        error = L"registering the space tip's window class failed";
        return nullptr;
    }
    // Never activated, never in the taskbar or Alt+Tab, and transparent to the mouse
    // (ignoresMouseEvents: WindowProc). DirectComposition draws all of it.
    view->window_ = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName, L"", WS_POPUP, 0, 0, 1, 1,
                                    owner, nullptr, instance, nullptr);
    if (!view->window_) {
        error = L"creating the space tip's window failed";
        return nullptr;
    }
    return view;
}

LRESULT CALLBACK SpaceTipView::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    // The pointer goes through to the window under it (the browser window, on this thread), so
    // the cell's hover and the sidebar's rows never see the tip; a click never activates it.
    if (message == WM_NCHITTEST) return HTTRANSPARENT;
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    // Windows hides an owned window with its minimized owner and shows it again on restore
    // (SW_PARENTOPENING): the tip shows only when SidebarView says, so it stays hidden.
    if (message == WM_SHOWWINDOW && wParam && lParam == SW_PARENTOPENING) return 0;
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

SpaceTipView::~SpaceTipView() {
    if (window_) DestroyWindow(window_);
}

void SpaceTipView::UseCompositor(Compositor* compositor) {
    if (compositor == compositor_) return;
    Hide();
    target_.Reset();
    visual_.Reset();
    fade_.Reset();
    surface_.Reset();
    brush_.Reset();
    compositor_ = compositor;
    deviceLost_ = false;
}

bool SpaceTipView::MakeTree(HRESULT& hr) {
    if (target_) return true;
    IDCompositionDevice* device = compositor_->Device();
    if (FAILED(hr = device->CreateTargetForHwnd(window_, TRUE, target_.GetAddressOf())) ||
        FAILED(hr = device->CreateVisual(visual_.GetAddressOf())) || FAILED(hr = device->CreateEffectGroup(fade_.GetAddressOf())) ||
        FAILED(hr = visual_->SetEffect(fade_.Get())) || FAILED(hr = target_->SetRoot(visual_.Get()))) {
        target_.Reset();
        visual_.Reset();
        fade_.Reset();
        return false;
    }
    return true;
}

SpaceTipView::Measured SpaceTipView::Measure(const SpaceTip& tip) const {
    Measured m;
    auto measure = [&](const std::wstring& text, IDWriteTextFormat* format, ComPtr<IDWriteTextLayout>& out) -> float {
        if (FAILED(dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 100000, T::kHeight, out.GetAddressOf()))) {
            return 0;
        }
        DWRITE_TEXT_METRICS metrics{};
        out->GetMetrics(&metrics);
        return metrics.width;
    };
    SpaceTipWidths widths;
    widths.name = measure(Widen(tip.name), nameFormat_.Get(), m.name);
    if (tip.profile) {
        widths.chipSymbol = measure(kFace, chipSymbolFormat_.Get(), m.chipSymbol);
        widths.chipText = measure(Widen(*tip.profile), chipFormat_.Get(), m.chipText);
    }
    for (const std::string& key : tip.keys) {
        m.keys.emplace_back();
        widths.keys.push_back(measure(Widen(key), keyFormat_.Get(), m.keys.back()));
    }
    m.layout = LayOutSpaceTip(tip, widths);
    return m;
}

void SpaceTipView::Paint(ID2D1DeviceContext* context, const SpaceTip& tip, const Measured& m) {
    const SpaceTipLayout& layout = m.layout;
    context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    // Each text's line box centred on its 28pt line (or its chip or keycap), as SwiftUI centres
    // an HStack's views.
    auto centred = [&](IDWriteTextLayout* text, float x, float top, float height, D2D1_COLOR_F color) {
        if (!text) return;
        DWRITE_TEXT_METRICS metrics{};
        text->GetMetrics(&metrics);
        brush_->SetColor(color);
        context->DrawTextLayout(D2D1::Point2F(x, top + (height - metrics.height) / 2), text, brush_.Get());
    };
    const float radius = layout.height / 2;
    // Capsule().fill(tipFill)
    brush_->SetColor(Opaque(tip.fill));
    context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, layout.width, layout.height), radius, radius), brush_.Get());
    centred(m.name.Get(), layout.nameX, 0, layout.height, White(1));
    if (layout.chip) {
        const BarRect& chip = *layout.chip;
        const float r = chip.Height() / 2;
        brush_->SetColor(White(T::kChipOpacity));
        context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(chip.left, chip.top, chip.right, chip.bottom), r, r), brush_.Get());
        centred(m.chipSymbol.Get(), layout.chipSymbolX, chip.top, chip.Height(), Opaque(tip.accent));
        centred(m.chipText.Get(), layout.chipTextX, chip.top, chip.Height(), Opaque(tip.accent));
    }
    for (size_t i = 0; i < layout.keys.size() && i < m.keys.size(); ++i) {
        const BarRect& key = layout.keys[i];
        brush_->SetColor(White(T::kKeyOpacity));
        context->FillRoundedRectangle(
            D2D1::RoundedRect(D2D1::RectF(key.left, key.top, key.right, key.bottom), T::kKeyRadius, T::kKeyRadius), brush_.Get());
        DWRITE_TEXT_METRICS metrics{};
        m.keys[i]->GetMetrics(&metrics);
        centred(m.keys[i].Get(), key.left + (key.Width() - metrics.width) / 2, key.top, key.Height(), Opaque(tip.accent));
    }
    // .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)): inside the edge.
    const float inset = T::kBorderWidth / 2;
    brush_->SetColor(White(T::kBorderOpacity));
    context->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(inset, inset, layout.width - inset, layout.height - inset), radius - inset,
                                                    radius - inset),
                                  brush_.Get(), T::kBorderWidth);
}

std::wstring SpaceTipView::DrawInto(IDCompositionVirtualSurface* surface, UINT width, UINT height, UINT dpi, const SpaceTip& tip,
                                    const Measured& measured, Pixels* readBack, HRESULT& hr) {
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(White(1), brush_.GetAddressOf()))) {
        return HResultMessage(L"creating the space tip's brush", hr);
    }
    return compositor_->DrawSurface(
        surface, width, height, dpi, [&](ID2D1DeviceContext* context) { Paint(context, tip, measured); }, readBack, hr);
}

std::wstring SpaceTipView::Show(const std::string& spaceID, const SpaceTip& tip, const BarRect& cell, UINT dpi) {
    if (!compositor_) return L"no compositor";
    const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    const Measured measured = Measure(tip);
    const UINT width = static_cast<UINT>(std::ceil(measured.layout.width * scale));
    const UINT height = static_cast<UINT>(std::ceil(measured.layout.height * scale));
    HRESULT hr = S_OK;
    auto fail = [&](const wchar_t* what) {
        deviceLost_ = IsDeviceLost(hr);
        Hide();
        return HResultMessage(what, hr);
    };
    if (!MakeTree(hr)) return fail(L"building the space tip's composition");
    if (!surface_) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating the space tip's surface");
        }
    } else if (FAILED(hr = surface_->Resize(width, height))) {
        return fail(L"resizing the space tip's surface");
    }
    if (std::wstring error = DrawInto(surface_.Get(), width, height, dpi, tip, measured, nullptr, hr); !error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        Hide();
        return error;
    }
    // Faded in from 0 over 0.15 s on the compositor: NSAnimationContext's alphaValue, on Core
    // Animation's default curve (the Mac's measured fade).
    ComPtr<IDCompositionAnimation> fade;
    if (SUCCEEDED(hr = compositor_->Device()->CreateAnimation(fade.GetAddressOf()))) {
        for (const CubicSegment& s : TimingCurveSegments(kDefaultTiming[0], kDefaultTiming[1], kDefaultTiming[2], kDefaultTiming[3], T::kFadeIn)) {
            if (FAILED(hr = fade->AddCubic(s.begin, static_cast<float>(s.constant), static_cast<float>(s.linear), static_cast<float>(s.quadratic),
                                           static_cast<float>(s.cubic)))) {
                break;
            }
        }
        if (SUCCEEDED(hr) && SUCCEEDED(hr = fade->End(T::kFadeIn, 1))) hr = fade_->SetOpacity(fade.Get());
    }
    if (FAILED(hr)) fade_->SetOpacity(1.0f);
    // At the cell, in the owner's client area, as screen pixels.
    const TipOrigin origin = SpaceTipOrigin(cell, measured.layout.width, measured.layout.height, scale);
    POINT topLeft{static_cast<LONG>(std::lround(origin.x * scale)), static_cast<LONG>(std::lround(origin.y * scale))};
    ClientToScreen(owner_, &topLeft);
    if (FAILED(hr = compositor_->Commit())) return fail(L"showing the space tip");
    SetWindowPos(window_, HWND_TOP, topLeft.x, topLeft.y, static_cast<int>(width), static_cast<int>(height),
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
    showing_ = spaceID;
    return {};
}

void SpaceTipView::Hide() {
    if (!showing_) return;
    showing_.reset();
    ShowWindow(window_, SW_HIDE);
}

void SpaceTipView::Hide(const std::string& spaceID) {
    if (showing_ == spaceID) Hide();
}

std::wstring SpaceTipView::Render(const SpaceTip& tip, const BarRect& cell, UINT dpi, Pixels& out, POINT& origin) {
    if (!compositor_) return L"no compositor";
    const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    const Measured measured = Measure(tip);
    const TipOrigin at = SpaceTipOrigin(cell, measured.layout.width, measured.layout.height, scale);
    origin = POINT{static_cast<LONG>(std::lround(at.x * scale)), static_cast<LONG>(std::lround(at.y * scale))};
    const UINT width = static_cast<UINT>(std::ceil(measured.layout.width * scale));
    const UINT height = static_cast<UINT>(std::ceil(measured.layout.height * scale));
    HRESULT hr = S_OK;
    ComPtr<IDCompositionVirtualSurface> surface;
    if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                 surface.GetAddressOf()))) {
        return HResultMessage(L"creating the space tip's surface", hr);
    }
    return DrawInto(surface.Get(), width, height, dpi, tip, measured, &out, hr);
}

}  // namespace kite
