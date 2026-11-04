#pragma once
// One line of editable text, as Kite's own fields edit it (a Win32 edit control can't draw into
// DirectComposition): the text in UTF-16, the caret and the selection's other end, Windows'
// editing keys and the clipboard. The caret only ever sits between characters (grapheme
// clusters, as core counts them), and nothing typed or pasted starts a second line. The field
// that owns it draws it and places the caret (the command bar's, the space header's name).

#include <windows.h>

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kite {

class TextEditing {
public:
    // `window` owns the clipboard while it copies.
    explicit TextEditing(HWND window) : window_(window) {}

    // What an edit changed: the field draws again, and its caret moves (a new text also makes
    // a new layout).
    enum class Change { None, Selection, Text };

    const std::wstring& Text() const { return text_; }
    size_t Caret() const { return caret_; }
    bool HasSelection() const { return caret_ != anchor_; }
    size_t SelectionStart() const { return caret_ < anchor_ ? caret_ : anchor_; }
    size_t SelectionEnd() const { return caret_ < anchor_ ? anchor_ : caret_; }

    // A new text with the caret and the selection's other end (clamped to it).
    void SetText(std::wstring text, size_t caret, size_t anchor);
    // The caret at `caret`; with `extend`, the selection's other end stays where it was.
    Change Select(size_t caret, bool extend);
    void SelectAll();
    // Replaces the selection with `text`, the caret after it.
    Change Insert(std::wstring_view text);
    // The arrows, Home and End (with Ctrl, by words; with Shift, selecting), Backspace and
    // Delete (Ctrl: a word), Ctrl+A, the clipboard's Ctrl+C, X, V and Ctrl/Shift+Insert, and
    // Shift+Delete. None when `key` isn't one of them (it goes on to the field and the window).
    std::optional<Change> KeyDown(UINT key, bool ctrl, bool shift);
    // A WM_CHAR: typed text (a surrogate pair arrives in two). Control characters are keys
    // KeyDown already took; a line break becomes a space.
    Change Character(wchar_t character);
    // The character start at or before `index` (a hit test's result).
    size_t CharacterStartAtOrBefore(size_t index) const;

private:
    Change DeleteRange(size_t from, size_t to);
    size_t PreviousCharacter(size_t at) const;
    size_t NextCharacter(size_t at) const;
    size_t PreviousWord(size_t at) const;
    size_t NextWord(size_t at) const;
    void Copy() const;
    Change Paste();
    void Rescan();

    HWND window_;
    std::wstring text_;
    std::vector<bool> characterStarts_ = std::vector<bool>(1, true);  // per UTF-16 unit, and one past the end
    size_t caret_ = 0, anchor_ = 0;                                    // UTF-16 offsets
    wchar_t highSurrogate_ = 0;
};

}  // namespace kite
