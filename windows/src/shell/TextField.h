#pragma once
// One of Kite's one-line text fields, whole: what the find bar's query field is, and what the
// command bar's field and the space header's rename field can take on instead of each wiring
// shell/TextLine themselves (their follow-up, W21b). Kite draws its fields (a Win32 edit control
// can't draw into DirectComposition), so this is the text, its editing (shell/TextEditing:
// Windows' editing keys, words, the clipboard, characters as core counts them), undo and redo as
// the Mac's field editor groups them (core/TextUndo), the mouse's caret and drag selection, the
// keyboard focus with Windows' hidden system caret (where magnifiers and IMEs look), the IME's
// composition window at the caret, and the caret's blink on a visual of its own (TextLine), so a
// blink is a commit and not a redraw.
//
// The owner places it in its surface (points), draws it into its own context with Draw, and
// passes it the window's keys, characters, presses and timer ticks while it has the keyboard.
// It never draws on its own: every input returns what changed, and the owner draws its surface
// and then calls UpdateCaret.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <optional>
#include <string>
#include <string_view>

#include "core/TextUndo.h"
#include "shell/TextLine.h"

namespace kite {

class TextField {
public:
    using Change = TextEditing::Change;

    // `window` owns the clipboard and the system caret, and gets the blink's `caretTimer`.
    TextField(HWND window, UINT_PTR caretTimer) : window_(window), line_(window, caretTimer) {}
    ~TextField();
    TextField(const TextField&) = delete;
    TextField& operator=(const TextField&) = delete;

    // The text's format (one line, no trimming) and the placeholder shown while it's empty.
    void SetFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, std::wstring_view placeholder);
    // Where it is in the owner's surface, in points: the text from `left`, `width` of it showing,
    // its line centred in `top`…`top + height`. `surfaceOrigin` is the surface's top-left in the
    // window's client area (px) and `scale` its px per point, for the IME and the system caret.
    void Place(float left, float width, float top, float height, POINT surfaceOrigin, float scale);

    const std::wstring& Text() const { return line_.Edit().Text(); }
    // A new text from outside, all selected or with the caret at its end; nothing to undo.
    void SetText(std::wstring text, bool selectAll);
    void SelectAll();
    bool HasSelection() const { return line_.Edit().HasSelection(); }
    size_t SelectionStart() const { return line_.Edit().SelectionStart(); }
    size_t SelectionEnd() const { return line_.Edit().SelectionEnd(); }
    // Editing ended (another field or the page took the keyboard): the selection collapses to the
    // caret and there's nothing to undo, as when the Mac's field editor leaves a field.
    void EndEditing();

    // A key for the field: the editing keys (TextEditing::KeyDown), and Ctrl+Z undo, Ctrl+Y and
    // Ctrl+Shift+Z redo. None for a key that isn't the field's (Return, Escape, the owner's).
    std::optional<Change> KeyDown(UINT key, bool ctrl, bool shift);
    // A WM_CHAR.
    Change Character(wchar_t character);
    // Typed as one edit (a capture's or test's text, as the keyboard would type it).
    Change Type(std::wstring_view text);

    // The pointer, in the owner's surface points. Whether a point is on the field's text box.
    bool Contains(float x, float y) const;
    // A left press: the caret there (Shift extends the selection), and a drag selecting.
    Change Press(float x, bool shift);
    Change Drag(float x);
    void Release() { selecting_ = false; }
    bool Selecting() const { return selecting_; }

    // The keyboard came or went: the caret blinks only with it (and only then does the field
    // hold the system caret), the selection greys without it, and a run of typing ends.
    void SetFocused(bool focused);
    bool Focused() const { return focused_; }
    // The blink's tick. True when `timer` was the field's; UpdateCaret shows the change.
    bool HandleTimer(WPARAM timer);
    // An IME composition began or ended (WM_IME_STARTCOMPOSITION and ENDCOMPOSITION): Windows'
    // composition window draws it at the caret in `font`, and the placeholder hides under it;
    // the result comes as WM_CHARs.
    void CompositionStarted(const LOGFONTW* font);
    void CompositionEnded() { composing_ = false; }
    bool Composing() const { return composing_; }

    // Draws the placeholder, or the selection's highlight and the text, clipped to the field's
    // box, into the owner's context (its transform at the surface's top-left, in points).
    void Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, D2D1_COLOR_F text, D2D1_COLOR_F placeholder,
              D2D1_COLOR_F selection) const;
    // Places the caret `color`, 1pt wide, in `parent` (the visual showing the owner's surface):
    // shown while focused, blinking on, with nothing selected, inside the box. Commits nothing; a
    // failed HRESULT says whether the GPU went (IsDeviceLost).
    HRESULT UpdateCaret(IDCompositionDevice* device, ID2D1DeviceContext* context, IDCompositionVisual* parent, D2D1_COLOR_F color);
    // Takes the caret out and lets its GPU objects go (the owner's compositor is going).
    void ReleaseCaret() { caret_.Release(); }

private:
    struct Snapshot {
        std::wstring text;
        size_t caret = 0, anchor = 0;
    };
    Snapshot Current() const;
    void Restore(const Snapshot& snapshot);
    // After an edit: the layout and the scroll follow, the blink starts over, and a text change
    // is recorded for undo as `kind` from `before`.
    Change Apply(Change change, const Snapshot& before, TextUndo<Snapshot>::Kind kind);
    float TextTop() const;
    float CaretXInSurface() const;

    HWND window_;
    TextLine line_;
    TextUndo<Snapshot> undo_;
    CaretVisual caret_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> placeholder_;
    float left_ = 0, width_ = 1, top_ = 0, height_ = 0;
    POINT surfaceOrigin_{};
    float scale_ = 1;
    bool focused_ = false;
    bool systemCaret_ = false;  // this field made the thread's system caret
    bool selecting_ = false;
    bool composing_ = false;
};

}  // namespace kite
