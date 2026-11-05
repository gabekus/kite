// See RenameField.h.

#include "shell/RenameField.h"

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// NSColor.labelColor's alpha: the field's text (NSTextField's labelColor, not the header's 45%).
constexpr float kLabelAlpha = 0.85f;
// NSTextField's placeholder (placeholderTextColor) and the header's Done (SidebarDoneButton's 60%).
constexpr float kPlaceholderOpacity = 0.25f;
constexpr float kDoneOpacity = 0.6f;
// The Mac's text selection (NSColor.selectedTextBackgroundColor), as the command bar's; grey
// while the window doesn't have the keyboard.
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};
// While it edits, the field is AppKit's field editor: its text sits after the editor's line
// fragment padding (2pt), over the editor's background, NSColor.textBackgroundColor (sRGB #1E1E1E
// in a dark appearance, white in a light one, opaque, square-cornered). That background covers the
// field's frame (from the name's x to 2pt before Done's frame) grown to the editor's: 3pt before
// it and 1pt past its end (4pt wider: 160pt in the Mac's capture), 2pt above its line and 4pt
// below (22pt for the header's 16pt line), as the Mac's capture of the open field draws it.
constexpr float kTextInset = 2;
constexpr float kBackgroundBefore = 3, kBackgroundAfter = 1, kBackgroundAbove = 2, kBackgroundBelow = 4;
constexpr float kDarkTextBackground = 30 / 255.0f;

D2D1_COLOR_F Primary(bool dark, float alpha) {
    const float c = dark ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

bool Inside(const D2D1_RECT_F& r, float x, float y) { return x >= r.left && x < r.right && y >= r.top && y < r.bottom; }

}  // namespace

std::unique_ptr<RenameField> RenameField::Create(HWND window, IDWriteFactory* dwrite, IDWriteTextFormat* format, IDWriteTextFormat* done,
                                                 std::string id, const std::string& text, std::wstring_view placeholder,
                                                 std::wstring& error) {
    std::unique_ptr<RenameField> field(new RenameField(window, std::move(id)));
    // The field's own format: its row's without the "…" (a field scrolls instead).
    wchar_t family[64]{};
    ComPtr<IDWriteTextFormat> own;
    HRESULT hr = format->GetFontFamilyName(family, 64);
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextFormat(family, nullptr, format->GetFontWeight(), DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                      format->GetFontSize(), L"", own.GetAddressOf());
    }
    if (SUCCEEDED(hr)) hr = own->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    static constexpr wchar_t kDone[] = L"Done";
    if (SUCCEEDED(hr) && !placeholder.empty()) {
        hr = dwrite->CreateTextLayout(placeholder.data(), static_cast<UINT32>(placeholder.size()), own.Get(), 100000,
                                      format->GetFontSize() * 2, field->placeholder_.GetAddressOf());
    }
    if (SUCCEEDED(hr) && done) {
        hr = dwrite->CreateTextLayout(kDone, static_cast<UINT32>(std::size(kDone) - 1), done, 100000, done->GetFontSize() * 2,
                                      field->done_.GetAddressOf());
    }
    DWRITE_TEXT_METRICS metrics{};
    if (SUCCEEDED(hr) && done) hr = field->done_->GetMetrics(&metrics);
    if (FAILED(hr)) {
        error = HResultMessage(L"the rename field's text", hr);
        return nullptr;
    }
    if (done) {
        // SidebarLabel.naturalWidth: the text's width rounded up to a whole point, so Done's label sits
        // up to a point short of the cell's end, as the Mac's does.
        field->doneWidth_ = std::ceil(metrics.widthIncludingTrailingWhitespace);
        DWRITE_LINE_METRICS line{};
        UINT32 count = 0;
        if (SUCCEEDED(field->done_->GetLineMetrics(&line, 1, &count)) && count == 1) field->doneLayoutBaseline_ = line.baseline;
    }
    // The text, all selected, as begin(with:)'s selectAll.
    std::wstring wide = Widen(text);
    const size_t end = wide.size();
    field->line_.Edit().SetText(std::move(wide), end, 0);
    field->line_.SetFormat(dwrite, own.Get(), format->GetFontSize() * 2);
    field->focused_ = GetFocus() == window;
    if (field->focused_) CreateCaret(window, nullptr, 1, 1);  // hidden: where magnifiers and IMEs look
    field->line_.RestartBlink(field->focused_);
    return field;
}

RenameField::~RenameField() {
    line_.StopBlink();
    if (focused_) DestroyCaret();
    UseCompositor(nullptr, nullptr);
}

std::string RenameField::Text() const { return Narrow(line_.Edit().Text()); }

void RenameField::Place(float left, float right, float lineTop, float lineHeight, float baseline, D2D1_RECT_F done, float doneBaseline,
                        float clipTop, float clipBottom, UINT dpi, bool dark) {
    if (left == left_ && right == right_ && lineTop == lineTop_ && lineHeight == lineHeight_ && baseline == baseline_ &&
        doneBaseline == doneBaseline_ && clipTop == clipTop_ && clipBottom == clipBottom_ && dpi == dpi_ && dark == dark_ &&
        done.left == doneBox_.left && done.top == doneBox_.top && done.right == doneBox_.right && done.bottom == doneBox_.bottom) {
        return;
    }
    clipTop_ = clipTop;
    clipBottom_ = clipBottom;
    left_ = left;
    right_ = right;
    lineTop_ = lineTop;
    lineHeight_ = lineHeight;
    baseline_ = baseline;
    doneBox_ = done;
    doneBaseline_ = doneBaseline;
    dpi_ = dpi;
    dark_ = dark;
    line_.SetVisibleWidth(right_ - left_ - 2 * kTextInset);
    line_.KeepCaretVisible();
    dirty_ = true;
}

bool RenameField::InField(float x, float y) const { return x >= left_ && x < right_ && y >= lineTop_ - 4 && y < lineTop_ + lineHeight_ + 4; }

void RenameField::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    caret_.Release();
    if (visual_ && parent_) parent_->RemoveVisual(visual_.Get());
    visual_.Reset();
    surface_.Reset();
    brush_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    compositor_ = compositor;
    parent_ = compositor ? parent : nullptr;
    deviceLost_ = false;
    dirty_ = true;
    caretPlaced_ = false;
}

std::wstring RenameField::Draw(Pixels* readBack, POINT* origin) {
    if (!compositor_ || !parent_) return {};
    if (deviceLost_) return L"the GPU device was lost";
    const float scale = Scale();
    HRESULT hr = S_OK;
    auto fail = [&](const wchar_t* what) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    if (!visual_) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(visual_.GetAddressOf())) ||
            FAILED(hr = parent_->AddVisual(visual_.Get(), TRUE, nullptr)) ||
            FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(Primary(dark_, 1), brush_.GetAddressOf()))) {
            visual_.Reset();
            return fail(L"creating the rename field");
        }
        dirty_ = true;
    }
    if (dirty_ || readBack) {
        // From the editor's background before the field to Done's right, the row's height, its
        // top-left on a pixel.
        const POINT at{std::lround(std::floor((left_ - kBackgroundBefore) * scale)), std::lround(std::floor(doneBox_.top * scale))};
        const UINT width = static_cast<UINT>(std::max(1L, std::lround(std::ceil(doneBox_.right * scale)) - at.x));
        const UINT height = static_cast<UINT>(std::max(1L, std::lround(std::ceil(doneBox_.bottom * scale)) - at.y));
        if (!surface_) {
            if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                         surface_.GetAddressOf())) ||
                FAILED(hr = visual_->SetContent(surface_.Get()))) {
                surface_.Reset();
                return fail(L"creating the rename field's surface");
            }
        } else if (width != surfaceWidth_ || height != surfaceHeight_) {
            if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the rename field's surface");
        }
        surfaceWidth_ = width;
        surfaceHeight_ = height;
        surfaceAt_ = at;
        visual_->SetOffsetX(static_cast<float>(at.x));
        visual_->SetOffsetY(static_cast<float>(at.y));
        // Only over the list: a row scrolled under the favorites or the space bar hides its field
        // with it (the caret too, a visual in this one).
        visual_->SetClip(D2D_RECT_F{-static_cast<float>(at.x), std::floor(clipTop_ * scale) - static_cast<float>(at.y),
                                    static_cast<float>(width), std::ceil(clipBottom_ * scale) - static_cast<float>(at.y)});
        const D2D1_POINT_2F shift{-static_cast<float>(at.x) / scale, -static_cast<float>(at.y) / scale};
        const std::wstring error = compositor_->DrawSurface(
            surface_.Get(), width, height, dpi_,
            [&](ID2D1DeviceContext* context) {
                D2D1_MATRIX_3X2_F base{};
                context->GetTransform(&base);
                // In page points from here on.
                context->SetTransform(D2D1::Matrix3x2F::Translation(shift.x, shift.y) * base);
                const float shade = dark_ ? kDarkTextBackground : 1.0f;
                brush_->SetColor(D2D1_COLOR_F{shade, shade, shade, 1});
                context->FillRectangle(
                    D2D1::RectF(left_ - kBackgroundBefore, lineTop_ - kBackgroundAbove, right_ + kBackgroundAfter,
                                lineTop_ + lineHeight_ + kBackgroundBelow),
                    brush_.Get());
                const D2D1_POINT_2F text{left_ + kTextInset - line_.ScrollX(), baseline_ - line_.Baseline()};
                context->PushAxisAlignedClip(D2D1::RectF(left_, doneBox_.top, right_, doneBox_.bottom), D2D1_ANTIALIAS_MODE_ALIASED);
                if (line_.Edit().Text().empty()) {
                    if (placeholder_) {
                        brush_->SetColor(Primary(dark_, kLabelAlpha * kPlaceholderOpacity));
                        context->DrawTextLayout(text, placeholder_.Get(), brush_.Get());
                    }
                } else if (IDWriteTextLayout* layout = line_.Layout()) {
                    // The line's height, as NSTextView fills a selection.
                    line_.DrawSelection(context, brush_.Get(), text, lineTop_, lineTop_ + lineHeight_,
                                        focused_ ? (dark_ ? kDarkSelection : kLightSelection) : Primary(dark_, 0.15f));
                    brush_->SetColor(Primary(dark_, kLabelAlpha));
                    context->DrawTextLayout(text, layout, brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                }
                context->PopAxisAlignedClip();
                if (done_) {
                    brush_->SetColor(Primary(dark_, kLabelAlpha * kDoneOpacity));
                    context->DrawTextLayout(D2D1::Point2F(doneBox_.left, doneBaseline_ - doneLayoutBaseline_), done_.Get(), brush_.Get());
                }
                context->SetTransform(base);
            },
            readBack, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"the rename field: " + error;
        }
        if (origin) *origin = at;
        dirty_ = false;
        caretPlaced_ = false;
    }
    if (!caretPlaced_) UpdateCaret();
    return {};
}

RenameField::Outcome RenameField::Apply(TextEditing::Change change) {
    if (change == TextEditing::Change::None) return Outcome::None;
    if (change == TextEditing::Change::Text) line_.Relayout();
    else line_.KeepCaretVisible();
    line_.RestartBlink(focused_);
    dirty_ = true;
    return Outcome::Changed;
}

std::optional<RenameField::Outcome> RenameField::KeyDown(UINT key, bool ctrl, bool shift) {
    if (key == VK_RETURN) return Outcome::Commit;
    if (key == VK_ESCAPE) return Outcome::Cancel;
    const std::optional<TextEditing::Change> change = line_.Edit().KeyDown(key, ctrl, shift);
    if (!change) return std::nullopt;
    return Apply(*change);
}

RenameField::Outcome RenameField::Character(wchar_t character) { return Apply(line_.Edit().Character(character)); }

bool RenameField::Press(float x, float y, bool shift) {
    pressedDone_ = done_ && Inside(doneBox_, x, y);
    if (pressedDone_) return true;
    if (!InField(x, y)) return false;
    selecting_ = true;
    Apply(line_.Edit().Select(line_.IndexAt(x - left_ - kTextInset), shift));
    return true;
}

RenameField::Outcome RenameField::Move(float x, float) {
    if (!selecting_) return Outcome::None;
    const size_t at = line_.IndexAt(x - left_ - kTextInset);
    if (at == line_.Edit().Caret()) return Outcome::None;
    return Apply(line_.Edit().Select(at, true));
}

RenameField::Outcome RenameField::Release(float x, float y) {
    selecting_ = false;
    // Done's mouseUp: let go over it.
    const bool done = pressedDone_ && Inside(doneBox_, x, y);
    pressedDone_ = false;
    return done ? Outcome::Commit : Outcome::None;
}

void RenameField::SetFocused(bool focused) {
    if (focused == focused_) return;
    focused_ = focused;
    if (focused) CreateCaret(window_, nullptr, 1, 1);
    else DestroyCaret();
    selecting_ = false;
    line_.RestartBlink(focused_);
    dirty_ = true;  // the selection's colour
}

bool RenameField::HandleTimer(WPARAM timer) {
    if (!line_.HandleTimer(timer)) return false;
    UpdateCaret();
    if (compositor_) compositor_->Commit();
    return true;
}

void RenameField::UpdateCaret() {
    if (!compositor_ || !visual_) return;
    const float scale = Scale();
    const float x = left_ + kTextInset - line_.ScrollX() + line_.CaretX();
    const bool wanted = focused_ && line_.CaretOn() && !line_.Edit().HasSelection() && x >= left_ && x <= right_;
    const UINT width = static_cast<UINT>(std::max(1L, std::lround(scale)));  // 1pt
    const UINT height = static_cast<UINT>(std::max(1L, std::lround(lineHeight_ * scale)));
    // Centred on the caret's position, on a pixel, in the field's visual.
    const POINT at{std::lround(x * scale) - static_cast<LONG>(width) / 2 - surfaceAt_.x, std::lround(lineTop_ * scale) - surfaceAt_.y};
    if (const HRESULT hr =
            caret_.Update(compositor_->Device(), compositor_->D2D(), visual_.Get(), wanted, at, width, height, Primary(dark_, kLabelAlpha));
        FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        return;
    }
    if (wanted) SetCaretPos(pageOrigin_.x + std::lround(x * scale), pageOrigin_.y + std::lround(lineTop_ * scale));
    caretPlaced_ = true;
}

void RenameField::PlaceImeWindow() {
    const float scale = Scale();
    const POINT caret{pageOrigin_.x + std::lround((left_ + kTextInset - line_.ScrollX() + line_.CaretX()) * scale),
                      pageOrigin_.y + std::lround(lineTop_ * scale)};
    line_.PlaceIme(caret, std::lround(lineHeight_ * scale));
}

}  // namespace kite
