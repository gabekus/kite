// See TextField.h. Built on what the command bar's field and the rename field share
// (shell/TextEditing, shell/TextLine), plus undo, focus and the mouse.

#include "shell/TextField.h"

#include <algorithm>
#include <cmath>

namespace kite {

TextField::~TextField() {
    line_.StopBlink();
    if (systemCaret_) DestroyCaret();
}

void TextField::SetFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, std::wstring_view placeholder) {
    // Laid out in a box of the format's size, as much as a line needs; Place centres the line.
    const float height = format->GetFontSize() * 2;
    line_.SetFormat(dwrite, format, height);
    placeholder_.Reset();
    dwrite->CreateTextLayout(placeholder.data(), static_cast<UINT32>(placeholder.size()), format, 100000, height,
                             placeholder_.GetAddressOf());
}

void TextField::Place(float left, float width, float top, float height, POINT surfaceOrigin, float scale) {
    left_ = left;
    width_ = std::max(width, 1.0f);
    top_ = top;
    height_ = height;
    surfaceOrigin_ = surfaceOrigin;
    scale_ = scale;
    line_.SetVisibleWidth(width_);
    line_.KeepCaretVisible();
}

void TextField::SetText(std::wstring text, bool selectAll) {
    const size_t end = text.size();
    line_.Edit().SetText(std::move(text), end, selectAll ? 0 : end);
    line_.Relayout();
    undo_.Reset();
    line_.RestartBlink(focused_);
}

void TextField::SelectAll() {
    line_.Edit().SelectAll();
    undo_.BreakTyping();
    line_.KeepCaretVisible();
    line_.RestartBlink(focused_);
}

TextField::Snapshot TextField::Current() const {
    const TextEditing& edit = line_.Edit();
    // The anchor is whichever end of the selection the caret isn't at.
    const size_t anchor = edit.Caret() == edit.SelectionStart() ? edit.SelectionEnd() : edit.SelectionStart();
    return Snapshot{edit.Text(), edit.Caret(), anchor};
}

void TextField::Restore(const Snapshot& snapshot) {
    line_.Edit().SetText(snapshot.text, snapshot.caret, snapshot.anchor);
    line_.Relayout();
    line_.RestartBlink(focused_);
}

TextField::Change TextField::Apply(Change change, const Snapshot& before, TextUndo<Snapshot>::Kind kind) {
    switch (change) {
    case Change::None: return change;
    case Change::Selection:
        undo_.BreakTyping();
        line_.KeepCaretVisible();
        break;
    case Change::Text:
        undo_.Record(before, kind);
        line_.Relayout();
        break;
    }
    line_.RestartBlink(focused_);
    return change;
}

std::optional<TextField::Change> TextField::KeyDown(UINT key, bool ctrl, bool shift) {
    using Kind = TextUndo<Snapshot>::Kind;
    if (ctrl && (key == 'Z' || key == 'Y')) {
        // Ctrl+Z undoes; Ctrl+Y and Ctrl+Shift+Z redo, as in Windows' text boxes and the Mac's ⇧⌘Z.
        const bool redo = key == 'Y' || shift;
        const Snapshot current = Current();
        if (std::optional<Snapshot> to = redo ? undo_.Redo(current) : undo_.Undo(current)) {
            Restore(*to);
            return Change::Text;
        }
        return Change::None;
    }
    const Snapshot before = Current();
    const std::optional<Change> change = line_.Edit().KeyDown(key, ctrl, shift);
    if (!change) return std::nullopt;
    // Backspace and Delete a character at a time are typing; a word at once, a cut or a paste
    // is an undo of its own.
    const bool typing = (key == VK_BACK || key == VK_DELETE) && !ctrl && !shift;
    return Apply(*change, before, typing ? Kind::Typing : Kind::Other);
}

TextField::Change TextField::Character(wchar_t character) {
    const Snapshot before = Current();
    return Apply(line_.Edit().Character(character), before, TextUndo<Snapshot>::Kind::Typing);
}

TextField::Change TextField::Type(std::wstring_view text) {
    const Snapshot before = Current();
    return Apply(line_.Edit().Insert(text), before, TextUndo<Snapshot>::Kind::Other);
}

bool TextField::Contains(float x, float y) const { return x >= left_ - 1 && x < left_ + width_ && y >= top_ && y < top_ + height_; }

TextField::Change TextField::Press(float x, bool shift) {
    selecting_ = true;
    const Snapshot before = Current();
    return Apply(line_.Edit().Select(line_.IndexAt(x - left_), shift), before, TextUndo<Snapshot>::Kind::Other);
}

TextField::Change TextField::Drag(float x) {
    if (!selecting_) return Change::None;
    const size_t at = line_.IndexAt(x - left_);
    if (at == line_.Edit().Caret()) return Change::None;
    const Snapshot before = Current();
    return Apply(line_.Edit().Select(at, true), before, TextUndo<Snapshot>::Kind::Other);
}

void TextField::SetFocused(bool focused) {
    if (focused == focused_) return;
    focused_ = focused;
    undo_.BreakTyping();
    if (!focused) {
        selecting_ = false;
        composing_ = false;
    }
    // Hidden, 1×1: where magnifiers and IMEs look for the caret (UpdateCaret moves it).
    if (focused && !systemCaret_) systemCaret_ = CreateCaret(window_, nullptr, 1, 1) != FALSE;
    if (!focused && systemCaret_) {
        DestroyCaret();
        systemCaret_ = false;
    }
    if (focused) line_.RestartBlink(true);
    else line_.StopBlink();
}

bool TextField::HandleTimer(WPARAM timer) { return line_.HandleTimer(timer); }

float TextField::TextTop() const { return top_ + (height_ - line_.LineHeight()) / 2; }

float TextField::CaretXInSurface() const { return left_ - line_.ScrollX() + line_.CaretX(); }

void TextField::CompositionStarted(const LOGFONTW* font) {
    composing_ = true;
    const POINT caret{surfaceOrigin_.x + std::lround(CaretXInSurface() * scale_), surfaceOrigin_.y + std::lround(TextTop() * scale_)};
    line_.PlaceIme(caret, std::lround(line_.LineHeight() * scale_), font);
}

void TextField::Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, D2D1_COLOR_F text, D2D1_COLOR_F placeholder,
                     D2D1_COLOR_F selection) const {
    const float top = TextTop();
    const D2D1_POINT_2F origin{left_ - line_.ScrollX(), top};
    context->PushAxisAlignedClip(D2D1::RectF(left_ - 1, top_, left_ + width_, top_ + height_), D2D1_ANTIALIAS_MODE_ALIASED);
    if (Text().empty()) {
        // Not under an IME's composition, which Windows draws over the field at the caret.
        if (placeholder_ && !composing_) {
            brush->SetColor(placeholder);
            context->DrawTextLayout(D2D1::Point2F(left_, top), placeholder_.Get(), brush);
        }
    } else if (IDWriteTextLayout* layout = line_.Layout()) {
        line_.DrawSelection(context, brush, origin, top, top + line_.LineHeight(), selection);
        brush->SetColor(text);
        context->DrawTextLayout(origin, layout, brush);
    }
    context->PopAxisAlignedClip();
}

HRESULT TextField::UpdateCaret(IDCompositionDevice* device, ID2D1DeviceContext* context, IDCompositionVisual* parent, D2D1_COLOR_F color) {
    const float x = CaretXInSurface();
    const bool wanted = focused_ && line_.CaretOn() && !HasSelection() && x >= left_ - 1 && x <= left_ + width_;
    const UINT width = static_cast<UINT>(std::max(1L, std::lround(scale_)));
    const UINT height = static_cast<UINT>(std::max(1L, std::lround(line_.LineHeight() * scale_)));
    // Centred on the caret's position, snapped to a pixel.
    const POINT at{std::lround(x * scale_) - static_cast<LONG>(width) / 2, std::lround(TextTop() * scale_)};
    // The hidden system caret follows, in client pixels.
    if (systemCaret_) SetCaretPos(surfaceOrigin_.x + at.x, surfaceOrigin_.y + at.y);
    return caret_.Update(device, context, parent, wanted, at, width, height, color);
}

}  // namespace kite
