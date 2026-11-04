// See SpaceRenameField.h.

#include "shell/SpaceRenameField.h"

#include <imm.h>

#include <algorithm>
#include <cmath>
#include <optional>

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
constexpr UINT kCaretTimeoutQuery = 0x2022;  // SPI_GETCARETTIMEOUT

D2D1_COLOR_F Primary(bool dark, float alpha) {
    const float c = dark ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

}  // namespace

std::unique_ptr<SpaceRenameField> SpaceRenameField::Create(HWND window, IDWriteFactory* dwrite, IDWriteTextFormat* format,
                                                           IDWriteTextFormat* done, std::string spaceID, const std::string& name,
                                                           std::wstring& error) {
    std::unique_ptr<SpaceRenameField> field(new SpaceRenameField(window, std::move(spaceID)));
    field->dwrite_ = dwrite;
    // The field's own format: the header's without its "…" (a field scrolls instead).
    wchar_t family[64]{};
    HRESULT hr = format->GetFontFamilyName(family, 64);
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextFormat(family, nullptr, format->GetFontWeight(), DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                      format->GetFontSize(), L"", field->format_.GetAddressOf());
    }
    if (SUCCEEDED(hr)) hr = field->format_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    static constexpr wchar_t kPlaceholder[] = L"Space Name";
    static constexpr wchar_t kDone[] = L"Done";
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextLayout(kPlaceholder, static_cast<UINT32>(std::size(kPlaceholder) - 1), field->format_.Get(), 100000,
                                      format->GetFontSize() * 2, field->placeholder_.GetAddressOf());
    }
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextLayout(kDone, static_cast<UINT32>(std::size(kDone) - 1), done, 100000, done->GetFontSize() * 2,
                                      field->done_.GetAddressOf());
    }
    DWRITE_TEXT_METRICS metrics{};
    if (SUCCEEDED(hr)) hr = field->done_->GetMetrics(&metrics);
    if (FAILED(hr)) {
        error = HResultMessage(L"the rename field's text", hr);
        return nullptr;
    }
    field->doneWidth_ = metrics.widthIncludingTrailingWhitespace;
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    if (SUCCEEDED(field->placeholder_->GetLineMetrics(&line, 1, &count)) && count == 1) field->layoutBaseline_ = line.baseline;
    if (SUCCEEDED(field->done_->GetLineMetrics(&line, 1, &count)) && count == 1) field->doneLayoutBaseline_ = line.baseline;
    // The name, all selected, as SpaceRenameField.begin's selectAll.
    std::wstring text = Widen(name);
    const size_t end = text.size();
    field->edit_.SetText(std::move(text), end, 0);
    field->Relayout();
    field->focused_ = GetFocus() == window;
    if (field->focused_) CreateCaret(window, nullptr, 1, 1);  // hidden: where magnifiers and IMEs look
    field->RestartBlink();
    return field;
}

SpaceRenameField::~SpaceRenameField() {
    KillTimer(window_, kCaretTimer);
    if (focused_) DestroyCaret();
    UseCompositor(nullptr, nullptr);
}

std::string SpaceRenameField::Text() const { return Narrow(edit_.Text()); }

void SpaceRenameField::Relayout() {
    const std::wstring& text = edit_.Text();
    layout_.Reset();
    dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format_.Get(), 100000, format_->GetFontSize() * 2,
                              layout_.GetAddressOf());
    KeepCaretVisible();
}

void SpaceRenameField::Place(float left, float right, float lineTop, float lineHeight, float baseline, D2D1_RECT_F done,
                             float doneBaseline, UINT dpi) {
    const bool moved = left != left_ || right != right_ || lineTop != lineTop_ || dpi != dpi_;
    left_ = left;
    right_ = right;
    lineTop_ = lineTop;
    lineHeight_ = lineHeight;
    baseline_ = baseline;
    doneBox_ = done;
    doneBaseline_ = doneBaseline;
    dpi_ = dpi;
    if (moved) KeepCaretVisible();
}

float SpaceRenameField::CaretX() const {
    if (!layout_) return 0;
    FLOAT x = 0, y = 0;
    DWRITE_HIT_TEST_METRICS hit{};
    layout_->HitTestTextPosition(static_cast<UINT32>(edit_.Caret()), FALSE, &x, &y, &hit);
    return x;
}

void SpaceRenameField::KeepCaretVisible() {
    const float visible = std::max(right_ - left_, 1.0f);
    DWRITE_TEXT_METRICS metrics{};
    if (layout_) layout_->GetMetrics(&metrics);
    const float x = CaretX();
    if (x - scrollX_ > visible) scrollX_ = x - visible;
    if (x - scrollX_ < 0) scrollX_ = x;
    scrollX_ = std::clamp(scrollX_, 0.0f, std::max(metrics.widthIncludingTrailingWhitespace + 1 - visible, 0.0f));
}

size_t SpaceRenameField::IndexAt(float x) const {
    if (!layout_ || edit_.Text().empty()) return 0;
    BOOL trailing = FALSE, inside = FALSE;
    DWRITE_HIT_TEST_METRICS hit{};
    layout_->HitTestPoint(x - left_ + scrollX_, 0, &trailing, &inside, &hit);
    return edit_.CharacterStartAtOrBefore(hit.textPosition + (trailing ? hit.length : 0));
}

bool SpaceRenameField::InField(float x, float y) const {
    return x >= left_ && x < right_ && y >= lineTop_ - 4 && y < lineTop_ + lineHeight_ + 4;
}

void SpaceRenameField::Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, bool dark) {
    dark_ = dark;
    const D2D1_POINT_2F origin{left_ - scrollX_, baseline_ - layoutBaseline_};
    context->PushAxisAlignedClip(D2D1::RectF(left_ - 1, lineTop_ - 4, right_, lineTop_ + lineHeight_ + 4), D2D1_ANTIALIAS_MODE_ALIASED);
    if (edit_.Text().empty()) {
        brush->SetColor(Primary(dark, kLabelAlpha * kPlaceholderOpacity));
        context->DrawTextLayout(origin, placeholder_.Get(), brush);
    } else if (layout_) {
        if (edit_.HasSelection()) {
            UINT32 count = 0;
            const auto start = static_cast<UINT32>(edit_.SelectionStart());
            const auto length = static_cast<UINT32>(edit_.SelectionEnd() - edit_.SelectionStart());
            layout_->HitTestTextRange(start, length, 0, 0, nullptr, 0, &count);
            std::vector<DWRITE_HIT_TEST_METRICS> ranges(count);
            if (count && SUCCEEDED(layout_->HitTestTextRange(start, length, 0, 0, ranges.data(), count, &count))) {
                D2D1_COLOR_F selection = focused_ ? (dark ? kDarkSelection : kLightSelection) : Primary(dark, 0.15f);
                brush->SetColor(selection);
                // The line's height, as NSTextView fills a selection.
                for (const auto& r : ranges) {
                    context->FillRectangle(D2D1::RectF(origin.x + r.left, lineTop_, origin.x + r.left + r.width, lineTop_ + lineHeight_), brush);
                }
            }
        }
        brush->SetColor(Primary(dark, kLabelAlpha));
        context->DrawTextLayout(origin, layout_.Get(), brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    }
    context->PopAxisAlignedClip();
    // Done, in its box.
    brush->SetColor(Primary(dark, kLabelAlpha * kDoneOpacity));
    context->DrawTextLayout(D2D1::Point2F(doneBox_.left, doneBaseline_ - doneLayoutBaseline_), done_.Get(), brush);
}

SpaceRenameField::Outcome SpaceRenameField::Apply(TextEditing::Change change) {
    if (change == TextEditing::Change::None) return Outcome::None;
    if (change == TextEditing::Change::Text) Relayout();
    else KeepCaretVisible();
    RestartBlink();
    return Outcome::Changed;
}

std::optional<SpaceRenameField::Outcome> SpaceRenameField::KeyDown(UINT key, bool ctrl, bool shift) {
    if (key == VK_RETURN) return Outcome::Commit;
    if (key == VK_ESCAPE) return Outcome::Cancel;
    const std::optional<TextEditing::Change> change = edit_.KeyDown(key, ctrl, shift);
    if (!change) return std::nullopt;
    return Apply(*change);
}

SpaceRenameField::Outcome SpaceRenameField::Character(wchar_t character) { return Apply(edit_.Character(character)); }

bool SpaceRenameField::Press(float x, float y, bool shift) {
    pressedDone_ = x >= doneBox_.left && x < doneBox_.right && y >= doneBox_.top && y < doneBox_.bottom;
    if (pressedDone_) return true;
    if (!InField(x, y)) return false;
    selecting_ = true;
    Apply(edit_.Select(IndexAt(x), shift));
    return true;
}

SpaceRenameField::Outcome SpaceRenameField::Move(float x, float) {
    if (!selecting_) return Outcome::None;
    const size_t at = IndexAt(x);
    if (at == edit_.Caret()) return Outcome::None;
    return Apply(edit_.Select(at, true));
}

SpaceRenameField::Outcome SpaceRenameField::Release(float x, float y) {
    selecting_ = false;
    // Done's mouseUp: let go over it.
    const bool done = pressedDone_ && x >= doneBox_.left && x < doneBox_.right && y >= doneBox_.top && y < doneBox_.bottom;
    pressedDone_ = false;
    return done ? Outcome::Commit : Outcome::None;
}

void SpaceRenameField::SetFocused(bool focused) {
    if (focused == focused_) return;
    focused_ = focused;
    if (focused) CreateCaret(window_, nullptr, 1, 1);
    else DestroyCaret();
    selecting_ = false;
    RestartBlink();
}

void SpaceRenameField::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    if (caretVisual_ && parent_ && caretShown_) parent_->RemoveVisual(caretVisual_.Get());
    caretVisual_.Reset();
    caretSurface_.Reset();
    caretShown_ = false;
    compositor_ = compositor;
    parent_ = parent;
}

void SpaceRenameField::RestartBlink() {
    caretOn_ = true;
    blinkSince_ = GetTickCount64();
    const UINT blink = GetCaretBlinkTime();
    if (focused_ && blink && blink != INFINITE) SetTimer(window_, kCaretTimer, blink, nullptr);
    else KillTimer(window_, kCaretTimer);
}

bool SpaceRenameField::HandleTimer(WPARAM timer) {
    if (timer != kCaretTimer) return false;
    // Windows' own text boxes stop blinking after a while, the caret left showing.
    DWORD timeout = 5000;
    if (!SystemParametersInfoW(kCaretTimeoutQuery, 0, &timeout, 0)) timeout = 5000;
    if (timeout != INFINITE && GetTickCount64() - blinkSince_ >= timeout) {
        KillTimer(window_, kCaretTimer);
        caretOn_ = true;
    } else {
        caretOn_ = !caretOn_;
    }
    UpdateCaret();
    if (compositor_) compositor_->Commit();
    return true;
}

void SpaceRenameField::UpdateCaret() {
    if (!compositor_ || !parent_) return;
    const float scale = Scale();
    const float x = left_ - scrollX_ + CaretX();
    const bool wanted = focused_ && caretOn_ && !edit_.HasSelection() && x >= left_ - 1 && x <= right_;
    if (wanted) {
        const UINT width = static_cast<UINT>(std::max(1L, std::lround(scale)));  // 1pt
        const UINT height = static_cast<UINT>(std::max(1L, std::lround(lineHeight_ * scale)));
        HRESULT hr = S_OK;
        if (!caretVisual_) hr = compositor_->Device()->CreateVisual(caretVisual_.GetAddressOf());
        if (SUCCEEDED(hr) && (!caretSurface_ || width != caretWidth_ || height != caretHeight_ || dark_ != caretDark_)) {
            // A surface of the caret's colour (the text's), filled once.
            if (!caretSurface_) {
                hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                caretSurface_.GetAddressOf());
                if (SUCCEEDED(hr)) hr = caretVisual_->SetContent(caretSurface_.Get());
            } else {
                hr = caretSurface_->Resize(width, height);
            }
            if (SUCCEEDED(hr)) {
                const bool dark = dark_;
                const std::wstring problem = compositor_->DrawSurface(
                    caretSurface_.Get(), width, height, USER_DEFAULT_SCREEN_DPI,
                    [&](ID2D1DeviceContext* context) { context->Clear(Primary(dark, kLabelAlpha)); }, nullptr, hr);
                if (problem.empty()) {
                    caretWidth_ = width;
                    caretHeight_ = height;
                    caretDark_ = dark;
                }
            }
        }
        if (FAILED(hr)) {
            caretSurface_.Reset();
            return;
        }
        // Centred on the caret's position, on a pixel, in window px.
        caretVisual_->SetOffsetX(static_cast<float>(std::lround(x * scale) - static_cast<LONG>(width) / 2));
        caretVisual_->SetOffsetY(static_cast<float>(std::lround(lineTop_ * scale)));
        if (focused_) SetCaretPos(std::lround(x * scale), std::lround(lineTop_ * scale));
    }
    if (wanted != caretShown_ && caretVisual_) {
        if (wanted) parent_->AddVisual(caretVisual_.Get(), TRUE, nullptr);
        else parent_->RemoveVisual(caretVisual_.Get());
        caretShown_ = wanted;
    }
}

void SpaceRenameField::PlaceImeWindow() {
    HIMC context = ImmGetContext(window_);
    if (!context) return;
    const float scale = Scale();
    const POINT caret{std::lround((left_ - scrollX_ + CaretX()) * scale), std::lround(lineTop_ * scale)};
    COMPOSITIONFORM composition{};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos = caret;
    ImmSetCompositionWindow(context, &composition);
    CANDIDATEFORM candidates{};
    candidates.dwStyle = CFS_CANDIDATEPOS;
    candidates.ptCurrentPos = {caret.x, caret.y + std::lround(lineHeight_ * scale)};
    ImmSetCandidateWindow(context, &candidates);
    ImmReleaseContext(window_, context);
}

}  // namespace kite
