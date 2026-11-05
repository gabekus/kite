// See TextLine.h. Moved out of the command bar (W7) for it and the rename field (W9d).

#include "shell/TextLine.h"

#include <imm.h>

#include <algorithm>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {
constexpr UINT kCaretTimeoutQuery = 0x2022;  // SPI_GETCARETTIMEOUT (winuser.h, Windows 10 1709+)
}  // namespace

void TextLine::SetFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, float height) {
    dwrite_ = dwrite;
    format_ = format;
    height_ = height;
    Relayout();
}

void TextLine::Relayout() {
    layout_.Reset();
    if (!dwrite_ || !format_) return;
    const std::wstring& text = edit_.Text();
    dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format_.Get(), 100000, height_, layout_.GetAddressOf());
    KeepCaretVisible();
}

float TextLine::Baseline() const {
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    if (layout_) layout_->GetLineMetrics(&line, 1, &count);
    return line.baseline;
}

float TextLine::LineHeight() const {
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    if (layout_) layout_->GetLineMetrics(&line, 1, &count);
    return line.height;
}

float TextLine::CaretX() const {
    if (!layout_) return 0;
    FLOAT x = 0, y = 0;
    DWRITE_HIT_TEST_METRICS hit{};
    layout_->HitTestTextPosition(static_cast<UINT32>(edit_.Caret()), FALSE, &x, &y, &hit);
    return x;
}

void TextLine::KeepCaretVisible() {
    const float visible = std::max(visible_, 1.0f);
    DWRITE_TEXT_METRICS metrics{};
    if (layout_) layout_->GetMetrics(&metrics);
    const float x = CaretX();
    if (x - scrollX_ > visible) scrollX_ = x - visible;
    if (x - scrollX_ < 0) scrollX_ = x;
    // Never scrolled past the text's end, once it's shorter again.
    scrollX_ = std::clamp(scrollX_, 0.0f, std::max(metrics.widthIncludingTrailingWhitespace + 1 - visible, 0.0f));
}

size_t TextLine::IndexAt(float x) const {
    if (!layout_ || edit_.Text().empty()) return 0;
    BOOL trailing = FALSE, inside = FALSE;
    DWRITE_HIT_TEST_METRICS hit{};
    layout_->HitTestPoint(x + scrollX_, 0, &trailing, &inside, &hit);
    return edit_.CharacterStartAtOrBefore(hit.textPosition + (trailing ? hit.length : 0));
}

void TextLine::DrawSelection(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, D2D1_POINT_2F origin, float top, float bottom,
                             D2D1_COLOR_F color) const {
    if (!layout_ || !edit_.HasSelection()) return;
    UINT32 count = 0;
    const auto start = static_cast<UINT32>(edit_.SelectionStart());
    const auto length = static_cast<UINT32>(edit_.SelectionEnd() - edit_.SelectionStart());
    layout_->HitTestTextRange(start, length, 0, 0, nullptr, 0, &count);
    std::vector<DWRITE_HIT_TEST_METRICS> ranges(count);
    if (!count || FAILED(layout_->HitTestTextRange(start, length, 0, 0, ranges.data(), count, &count))) return;
    brush->SetColor(color);
    for (const auto& r : ranges) context->FillRectangle(D2D1::RectF(origin.x + r.left, top, origin.x + r.left + r.width, bottom), brush);
}

void TextLine::RestartBlink(bool blinking) {
    caretOn_ = true;
    blinkSince_ = GetTickCount64();
    const UINT blink = GetCaretBlinkTime();
    // INFINITE: the user turned blinking off.
    if (blinking && blink && blink != INFINITE) SetTimer(window_, timer_, blink, nullptr);
    else KillTimer(window_, timer_);
}

void TextLine::StopBlink() {
    KillTimer(window_, timer_);
    caretOn_ = true;
}

bool TextLine::HandleTimer(WPARAM timer) {
    if (timer != timer_) return false;
    // Windows' own text boxes stop blinking after a while, the caret left showing.
    DWORD timeout = 5000;
    if (!SystemParametersInfoW(kCaretTimeoutQuery, 0, &timeout, 0)) timeout = 5000;
    if (timeout != INFINITE && GetTickCount64() - blinkSince_ >= timeout) {
        KillTimer(window_, timer_);
        caretOn_ = true;
    } else {
        caretOn_ = !caretOn_;
    }
    return true;
}

void TextLine::PlaceIme(POINT caret, LONG lineHeight, const LOGFONTW* font) const {
    HIMC context = ImmGetContext(window_);
    if (!context) return;
    COMPOSITIONFORM composition{};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos = caret;
    ImmSetCompositionWindow(context, &composition);
    CANDIDATEFORM candidates{};
    candidates.dwIndex = 0;
    candidates.dwStyle = CFS_CANDIDATEPOS;
    candidates.ptCurrentPos = {caret.x, caret.y + lineHeight};
    ImmSetCandidateWindow(context, &candidates);
    if (font) ImmSetCompositionFontW(context, const_cast<LOGFONTW*>(font));
    ImmReleaseContext(window_, context);
}

HRESULT CaretVisual::Update(IDCompositionDevice* device, ID2D1DeviceContext* context, IDCompositionVisual* parent, bool show, POINT at,
                            UINT width, UINT height, D2D1_COLOR_F color) {
    HRESULT hr = S_OK;
    if (show) {
        if (!visual_ && FAILED(hr = device->CreateVisual(visual_.GetAddressOf()))) return hr;
        if (!surface_ || width != width_ || height != height_ || color.r != color_.r || color.g != color_.g || color.b != color_.b ||
            color.a != color_.a) {
            surface_.Reset();
            ComPtr<IDXGISurface> dxgi;
            POINT offset{};
            hr = device->CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, surface_.GetAddressOf());
            if (SUCCEEDED(hr)) hr = surface_->BeginDraw(nullptr, IID_PPV_ARGS(dxgi.GetAddressOf()), &offset);
            if (SUCCEEDED(hr)) {
                ComPtr<ID2D1Bitmap1> target;
                const D2D1_BITMAP_PROPERTIES1 props =
                    D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
                hr = context->CreateBitmapFromDxgiSurface(dxgi.Get(), &props, target.GetAddressOf());
                if (SUCCEEDED(hr)) {
                    ComPtr<ID2D1Image> previous;
                    context->GetTarget(previous.GetAddressOf());
                    context->SetTarget(target.Get());
                    context->SetDpi(96, 96);
                    context->BeginDraw();
                    context->SetTransform(D2D1::Matrix3x2F::Identity());
                    // The surface may be part of a larger atlas: only its own rectangle.
                    const auto left = static_cast<float>(offset.x), top = static_cast<float>(offset.y);
                    context->PushAxisAlignedClip(D2D1::RectF(left, top, left + static_cast<float>(width), top + static_cast<float>(height)),
                                                 D2D1_ANTIALIAS_MODE_ALIASED);
                    context->Clear(color);
                    context->PopAxisAlignedClip();
                    hr = context->EndDraw();
                    context->SetTarget(previous.Get());
                }
                surface_->EndDraw();
            }
            if (SUCCEEDED(hr)) hr = visual_->SetContent(surface_.Get());
            if (FAILED(hr)) {
                surface_.Reset();
                return hr;
            }
            width_ = width;
            height_ = height;
            color_ = color;
        }
        visual_->SetOffsetX(static_cast<float>(at.x));
        visual_->SetOffsetY(static_cast<float>(at.y));
    }
    if (show && !parent) return E_POINTER;
    const bool shown = shownIn_ == parent && parent;
    if (show && !shown && visual_) {
        if (shownIn_) shownIn_->RemoveVisual(visual_.Get());
        parent->AddVisual(visual_.Get(), TRUE, nullptr);
        shownIn_ = parent;
    } else if (!show && shownIn_) {
        shownIn_->RemoveVisual(visual_.Get());
        shownIn_ = nullptr;
    }
    return hr;
}

void CaretVisual::Release() {
    if (visual_ && shownIn_) shownIn_->RemoveVisual(visual_.Get());
    shownIn_ = nullptr;
    surface_.Reset();
    visual_.Reset();
    width_ = height_ = 0;
}

}  // namespace kite
