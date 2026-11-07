// See ThemeSwatchesView.h. Ports ThemeEditor.swift's presets row (ThemeEditor.presets) and
// ThemeEditor.present(pointing: true)'s placement.

#include "shell/ThemeSwatchesView.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <utility>

#include "shell/Errors.h"
#include "shell/SystemFont.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace T = theme_swatches_metrics;

// chevron.left and chevron.right in Segoe Fluent Icons and Segoe MDL2 Assets.
constexpr wchar_t kChevronLeft = 0xE76B, kChevronRight = 0xE76C;
// labelColor's 85%, which the chevrons' 30% fades.
constexpr float kLabelAlpha = 0.85f;
// Room around the body for its edge, in points.
constexpr float kMargin = 1;

// NSPopover's material, as the picker's (PopoverWindow's): the Mac's theme editor is a plain popover.
D2D1_COLOR_F Fill(bool dark) { return PopoverFill(dark); }
D2D1_COLOR_F Edge(bool dark) { return PopoverEdge(dark); }

}  // namespace

std::unique_ptr<ThemeSwatchesView> ThemeSwatchesView::Create(HWND owner, IDWriteFactory* dwrite, Callbacks callbacks, bool offscreen,
                                                             std::wstring& error) {
    std::unique_ptr<ThemeSwatchesView> view(new ThemeSwatchesView(owner, std::move(callbacks), offscreen));
    if (!dwrite) {
        error = L"no text factory";
        return nullptr;
    }
    HRESULT hr = S_OK;
    hr = system_font::CreateIconFormat(dwrite, system_font::IconFont::Symbols, DWRITE_FONT_WEIGHT_MEDIUM, T::kChevronSize, view->chevronFormat_);
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    view->chevronFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    view->chevronFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    // Its window (made as it first opens): the clear corners beside the arrow and the edge's margin
    // pass the pointer to what's under.
    ThemeSwatchesView* raw = view.get();
    PopoverWindow::Callbacks window;
    window.onPopover = [raw](POINT at) { return raw->OnPopover(at); };
    window.message = [raw](UINT message, WPARAM wParam, LPARAM lParam) { return raw->Handle(message, wParam, lParam); };
    // Destroyed with its owner: closed, its surface with it.
    window.destroyed = [raw] {
        raw->visual_.Reset();
        raw->surface_.Reset();
        raw->Close();
    };
    view->popover_.SetCallbacks(std::move(window));
    return view;
}

ThemeSwatchesView::~ThemeSwatchesView() {
    callbacks_ = {};
    UseCompositor(nullptr);
}

std::optional<LRESULT> ThemeSwatchesView::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    const HWND window = popover_.Handle();
    switch (message) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
        pressed_ = SwatchAt(lParam);
        if (pressed_) SetCapture(window);
        return 0;
    case WM_LBUTTONUP: {
        const std::optional<size_t> pressed = pressed_;
        pressed_.reset();
        if (GetCapture() == window) ReleaseCapture();
        // A plain Button: on release over what was pressed.
        if (pressed && SwatchAt(lParam) == pressed && callbacks_.pick) callbacks_.pick(*pressed);
        return 0;
    }
    case WM_CAPTURECHANGED: pressed_.reset(); return 0;
    case WM_DPICHANGED:
        // Shown on a monitor of another scale (as the picker's): drawn again at its scale, its body
        // the same size in points, where Windows suggests.
        if (open_ && HIWORD(wParam) != dpi_ && lParam) Rescale(HIWORD(wParam), *reinterpret_cast<const RECT*>(lParam));
        return 0;
    default: break;
    }
    return std::nullopt;
}

void ThemeSwatchesView::Rescale(UINT dpi, const RECT& suggested) {
    dpi_ = dpi;
    const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    frame_.width = static_cast<UINT>(std::ceil((T::kArrowDepth + layout_.width + 2 * frame_.margin) * scale));
    frame_.height = static_cast<UINT>(std::ceil((layout_.height + 2 * frame_.margin) * scale));
    HRESULT hr = S_OK;
    std::wstring error;
    if (!surface_ || FAILED(hr = surface_->Resize(frame_.width, frame_.height))) {
        error = L"resizing the theme swatches' surface";
    } else {
        error = DrawInto(surface_.Get(), frame_, nullptr, hr);
    }
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        Close();
        if (deviceLost_ && onDeviceLost) onDeviceLost();
        return;
    }
    compositor_->Commit();
    popover_.Place(POINT{suggested.left, suggested.top}, frame_.width, frame_.height, !offscreen_);
}

void ThemeSwatchesView::UseCompositor(Compositor* compositor) {
    if (compositor == compositor_) return;
    Close();
    popover_.ReleaseTarget();
    visual_.Reset();
    surface_.Reset();
    brush_.Reset();
    compositor_ = compositor;
    deviceLost_ = false;
}

ThemeSwatchesView::Frame ThemeSwatchesView::FrameFor(const BarRect& row, float scale, bool onScreen) const {
    Frame f;
    f.placement = PlaceThemeSwatches(row, layout_);
    f.margin = kMargin;
    // The window: the arrow's room, then the body, the margin around both.
    const float left = f.placement.left - T::kArrowDepth - kMargin, top = f.placement.top - kMargin;
    f.origin = POINT{std::lround(left * scale), std::lround(top * scale)};
    f.width = static_cast<UINT>(std::ceil((T::kArrowDepth + layout_.width + 2 * kMargin) * scale));
    f.height = static_cast<UINT>(std::ceil((layout_.height + 2 * kMargin) * scale));
    if (!onScreen) return f;
    // Inside the work area of the monitor the row is on (NSPopover keeps to the screen's visible
    // frame), the arrow moving along its edge to stay level with the row.
    POINT anchor{std::lround(row.right * scale), std::lround((row.top + row.bottom) / 2 * scale)};
    ClientToScreen(popover_.Owner(), &anchor);
    POINT screen = f.origin;
    ClientToScreen(popover_.Owner(), &screen);
    const RECT work = PopoverWindow::WorkArea(anchor);
    LONG dx = 0, dy = 0;
    if (screen.x + static_cast<LONG>(f.width) > work.right) dx = work.right - (screen.x + static_cast<LONG>(f.width));
    if (screen.x + dx < work.left) dx = work.left - screen.x;
    if (screen.y + static_cast<LONG>(f.height) > work.bottom) dy = work.bottom - (screen.y + static_cast<LONG>(f.height));
    if (screen.y + dy < work.top) dy = work.top - screen.y;
    f.origin.x += dx;
    f.origin.y += dy;
    f.placement.left += static_cast<float>(dx) / scale;
    f.placement.top += static_cast<float>(dy) / scale;
    const float reach = T::kCornerRadius + T::kArrowWidth / 2;
    f.placement.arrowY = std::clamp(f.placement.arrowY - static_cast<float>(dy) / scale, reach, std::max(reach, layout_.height - reach));
    return f;
}

bool ThemeSwatchesView::OnPopover(POINT client) const {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float x = static_cast<float>(client.x) / scale - frame_.margin, y = static_cast<float>(client.y) / scale - frame_.margin;
    if (y < 0 || y >= layout_.height) return false;
    if (x >= T::kArrowDepth) return x < T::kArrowDepth + layout_.width;
    // The arrow: its tip at x 0, its base T::kArrowWidth tall at the body's edge.
    const float half = T::kArrowWidth / 2 * x / T::kArrowDepth;
    return x >= 0 && std::abs(y - frame_.placement.arrowY) <= half;
}

std::optional<size_t> ThemeSwatchesView::SwatchAt(LPARAM client) const {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float x = static_cast<float>(GET_X_LPARAM(client)) / scale - kMargin - T::kArrowDepth;
    const float y = static_cast<float>(GET_Y_LPARAM(client)) / scale - kMargin;
    return ThemeSwatchAt(layout_, x, y);
}

std::optional<POINT> ThemeSwatchesView::SwatchPoint(size_t index) const {
    if (!open_ || index >= layout_.swatches.size()) return std::nullopt;
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const BarRect& s = layout_.swatches[index];
    return POINT{std::lround(((s.left + s.right) / 2 + kMargin + T::kArrowDepth) * scale), std::lround(((s.top + s.bottom) / 2 + kMargin) * scale)};
}

void ThemeSwatchesView::Paint(ID2D1DeviceContext* context, const Frame& frame) {
    const float bodyLeft = frame.margin + T::kArrowDepth, bodyTop = frame.margin;
    const float w = layout_.width, h = layout_.height;
    // The body and its arrow as one shape, so the edge runs round both.
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    ComPtr<ID2D1RoundedRectangleGeometry> body;
    ComPtr<ID2D1PathGeometry> arrow, shape;
    ComPtr<ID2D1GeometrySink> sink;
    if (!factory ||
        FAILED(factory->CreateRoundedRectangleGeometry(
            D2D1::RoundedRect(D2D1::RectF(bodyLeft, bodyTop, bodyLeft + w, bodyTop + h), T::kCornerRadius, T::kCornerRadius), body.GetAddressOf())) ||
        FAILED(factory->CreatePathGeometry(arrow.GetAddressOf())) || FAILED(arrow->Open(sink.GetAddressOf()))) {
        return;
    }
    const float tipY = bodyTop + frame.placement.arrowY;
    sink->BeginFigure(D2D1::Point2F(bodyLeft + 1, tipY - T::kArrowWidth / 2), D2D1_FIGURE_BEGIN_FILLED);
    sink->AddLine(D2D1::Point2F(frame.margin, tipY));
    sink->AddLine(D2D1::Point2F(bodyLeft + 1, tipY + T::kArrowWidth / 2));
    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    sink->Close();
    sink.Reset();
    if (FAILED(factory->CreatePathGeometry(shape.GetAddressOf())) || FAILED(shape->Open(sink.GetAddressOf()))) return;
    body->CombineWithGeometry(arrow.Get(), D2D1_COMBINE_MODE_UNION, nullptr, sink.Get());
    sink->Close();
    brush_->SetColor(Fill(dark_));
    context->FillGeometry(shape.Get(), brush_.Get());
    brush_->SetColor(Edge(dark_));
    context->DrawGeometry(shape.Get(), brush_.Get(), 1.0f / (static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI));

    D2D1_MATRIX_3X2_F base{};
    context->GetTransform(&base);
    context->SetTransform(D2D1::Matrix3x2F::Translation(bodyLeft, bodyTop) * base);
    // The chevrons, both off (Kite's presets fit on one page).
    const float c = dark_ ? 1.0f : 0.0f;
    brush_->SetColor(D2D1_COLOR_F{c, c, c, kLabelAlpha * T::kChevronOpacity});
    context->DrawText(&kChevronLeft, 1, chevronFormat_.Get(),
                      D2D1::RectF(layout_.previous.left, layout_.previous.top, layout_.previous.right, layout_.previous.bottom), brush_.Get());
    context->DrawText(&kChevronRight, 1, chevronFormat_.Get(), D2D1::RectF(layout_.next.left, layout_.next.top, layout_.next.right, layout_.next.bottom),
                      brush_.Get());
    // Each preset's accent, with a white ring inside its edge.
    for (size_t i = 0; i < layout_.swatches.size() && i < accents_.size(); ++i) {
        const BarRect& s = layout_.swatches[i];
        const float r = s.Width() / 2;
        const D2D1_POINT_2F centre{s.left + r, s.top + r};
        brush_->SetColor(D2D1_COLOR_F{accents_[i].r, accents_[i].g, accents_[i].b, 1});
        context->FillEllipse(D2D1::Ellipse(centre, r, r), brush_.Get());
        brush_->SetColor(D2D1_COLOR_F{1, 1, 1, T::kSwatchRingOpacity});
        const float ring = r - T::kSwatchRing / 2;
        context->DrawEllipse(D2D1::Ellipse(centre, ring, ring), brush_.Get(), T::kSwatchRing);
    }
    context->SetTransform(base);
}

std::wstring ThemeSwatchesView::DrawInto(IDCompositionVirtualSurface* surface, const Frame& frame, Pixels* readBack, HRESULT& hr) {
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.GetAddressOf()))) {
        return HResultMessage(L"creating the theme swatches' brush", hr);
    }
    ++draws_;
    return compositor_->DrawSurface(
        perf::View::ThemeSwatches, surface, frame.width, frame.height, dpi_, [&](ID2D1DeviceContext* context) { Paint(context, frame); }, readBack, hr);
}

std::wstring ThemeSwatchesView::Open(const BarRect& row, UINT dpi, bool dark, std::vector<ThemeColor> accents) {
    // A popover open already (Choose a Theme again) closes first, as the Mac's present does.
    Close();
    if (!compositor_) return L"no compositor";
    if (std::wstring problem = popover_.Make(); !problem.empty()) return problem;
    dpi_ = dpi;
    dark_ = dark;
    accents_ = std::move(accents);
    layout_ = LayOutThemeSwatches(accents_.size());
    const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    frame_ = FrameFor(row, scale, !offscreen_);
    HRESULT hr = S_OK;
    auto fail = [&](const wchar_t* what) {
        deviceLost_ = IsDeviceLost(hr);
        Close();
        return HResultMessage(what, hr);
    };
    IDCompositionDevice* device = compositor_->Device();
    if (!popover_.HasTarget()) {
        if (!visual_ && FAILED(hr = device->CreateVisual(visual_.GetAddressOf()))) return fail(L"building the theme swatches' composition");
        if (FAILED(hr = popover_.MakeTarget(device, visual_.Get()))) {
            visual_.Reset();
            return fail(L"building the theme swatches' composition");
        }
    }
    if (!surface_) {
        if (FAILED(hr = device->CreateVirtualSurface(frame_.width, frame_.height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                     surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating the theme swatches' surface");
        }
    } else if (FAILED(hr = surface_->Resize(frame_.width, frame_.height))) {
        return fail(L"resizing the theme swatches' surface");
    }
    if (std::wstring error = DrawInto(surface_.Get(), frame_, nullptr, hr); !error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        Close();
        return error;
    }
    if (std::exchange(loseDeviceInOpen_, false)) {
        hr = DXGI_ERROR_DEVICE_REMOVED;
        return fail(L"the smoke test's lost GPU");
    }
    if (FAILED(hr = compositor_->Commit())) return fail(L"showing the theme swatches");
    POINT topLeft = frame_.origin;
    ClientToScreen(popover_.Owner(), &topLeft);
    // A quiet run's stays hidden, its size and place set all the same.
    popover_.Place(topLeft, frame_.width, frame_.height, !offscreen_);
    open_ = true;
    return {};
}

void ThemeSwatchesView::SetDark(bool dark) {
    if (dark == dark_) return;
    dark_ = dark;
    if (!open_ || !surface_ || !compositor_) return;
    HRESULT hr = S_OK;
    if (std::wstring error = DrawInto(surface_.Get(), frame_, nullptr, hr); !error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        Close();
        if (deviceLost_ && onDeviceLost) onDeviceLost();
        return;
    }
    compositor_->Commit();
}

void ThemeSwatchesView::Close() {
    pressed_.reset();
    if (!open_) return;
    open_ = false;
    popover_.Hide();
    // Its surface goes until it opens again (the next commit carries it).
    if (visual_) visual_->SetContent(nullptr);
    surface_.Reset();
    if (callbacks_.closed) callbacks_.closed();
}

std::wstring ThemeSwatchesView::Render(const BarRect& row, UINT dpi, bool dark, std::vector<ThemeColor> accents, Pixels& out, POINT& origin) {
    if (!compositor_) return L"no compositor";
    dpi_ = dpi;
    dark_ = dark;
    accents_ = std::move(accents);
    layout_ = LayOutThemeSwatches(accents_.size());
    // As it shows in the window (a capture keeps to the window, not the screen).
    const Frame frame = FrameFor(row, static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI, false);
    origin = frame.origin;
    HRESULT hr = S_OK;
    ComPtr<IDCompositionVirtualSurface> surface;
    if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(frame.width, frame.height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                 surface.GetAddressOf()))) {
        return HResultMessage(L"creating the theme swatches' surface", hr);
    }
    return DrawInto(surface.Get(), frame, &out, hr);
}

}  // namespace kite
