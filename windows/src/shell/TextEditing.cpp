// See TextEditing.h. Moved out of the command bar (W7) for the space header's name field (W9d).

#include "shell/TextEditing.h"

#include <algorithm>
#include <cstring>

#include "core/Unicode.h"

namespace kite {

namespace {

bool IsHighSurrogate(wchar_t c) { return c >= 0xD800 && c < 0xDC00; }
bool IsLowSurrogate(wchar_t c) { return c >= 0xDC00 && c < 0xE000; }
// What would start a second line in the field (DirectWrite breaks at these even without
// wrapping): control characters, NEL, and the line and paragraph separators.
bool BreaksLine(wchar_t c) { return c < 0x20 || c == 0x7F || c == 0x85 || c == 0x2028 || c == 0x2029; }

char32_t CodePointAt(const std::wstring& text, size_t at) {
    const wchar_t c = text[at];
    if (IsHighSurrogate(c) && at + 1 < text.size() && IsLowSurrogate(text[at + 1])) {
        return 0x10000 + ((static_cast<char32_t>(c) - 0xD800) << 10) + (static_cast<char32_t>(text[at + 1]) - 0xDC00);
    }
    return c;
}

// Where characters (grapheme clusters, as the core's matching and Swift count them) start,
// per UTF-16 unit, plus one past the end: the caret only ever sits between characters.
std::vector<bool> Utf16CharacterStarts(const std::wstring& text) {
    std::u32string codePoints;
    std::vector<size_t> offsets;
    for (size_t i = 0; i < text.size();) {
        const char32_t c = CodePointAt(text, i);
        codePoints.push_back(c);
        offsets.push_back(i);
        i += c > 0xFFFF ? 2 : 1;
    }
    const std::vector<bool> starts = unicode::CharacterStarts(codePoints);
    std::vector<bool> out(text.size() + 1, false);
    for (size_t k = 0; k < codePoints.size(); ++k) {
        if (starts[k]) out[offsets[k]] = true;
    }
    out[text.size()] = true;
    return out;
}

// Ctrl+Left and Ctrl+Right stop between runs of these, as in Windows' own text boxes.
enum class WordClass { Space, Word, Other };
WordClass Classify(char32_t c) {
    if (c == ' ' || c == '\t' || c == 0xA0 || c == 0x3000 || (c >= 0x2000 && c <= 0x200A)) return WordClass::Space;
    if (unicode::IsLetter(c) || unicode::IsNumber(c) || c == '_') return WordClass::Word;
    return WordClass::Other;
}

}  // namespace

void TextEditing::Rescan() { characterStarts_ = Utf16CharacterStarts(text_); }

void TextEditing::SetText(std::wstring text, size_t caret, size_t anchor) {
    text_ = std::move(text);
    caret_ = std::min(caret, text_.size());
    anchor_ = std::min(anchor, text_.size());
    highSurrogate_ = 0;
    Rescan();
}

TextEditing::Change TextEditing::Select(size_t caret, bool extend) {
    caret_ = std::min(caret, text_.size());
    if (!extend) anchor_ = caret_;
    return Change::Selection;
}

void TextEditing::SelectAll() {
    anchor_ = 0;
    caret_ = text_.size();
}

size_t TextEditing::CharacterStartAtOrBefore(size_t index) const {
    index = std::min(index, text_.size());
    while (index > 0 && !characterStarts_[index]) --index;
    return index;
}

TextEditing::Change TextEditing::Insert(std::wstring_view text) {
    const size_t start = SelectionStart();
    text_.replace(start, SelectionEnd() - start, text);
    caret_ = start + text.size();
    // What's inserted can join the character after it (a combining mark, a ZWJ, a second
    // flag letter): the caret goes to the end of that character, never inside it.
    Rescan();
    while (caret_ < text_.size() && !characterStarts_[caret_]) ++caret_;
    anchor_ = caret_;
    return Change::Text;
}

TextEditing::Change TextEditing::DeleteRange(size_t from, size_t to) {
    if (from >= to) return Change::None;
    text_.erase(from, to - from);
    caret_ = anchor_ = from;
    Rescan();
    return Change::Text;
}

size_t TextEditing::PreviousCharacter(size_t at) const {
    while (at > 0) {
        if (characterStarts_[--at]) return at;
    }
    return 0;
}

size_t TextEditing::NextCharacter(size_t at) const {
    while (at < text_.size()) {
        if (characterStarts_[++at]) return at;
    }
    return text_.size();
}

size_t TextEditing::PreviousWord(size_t at) const {
    while (at > 0 && Classify(CodePointAt(text_, PreviousCharacter(at))) == WordClass::Space) at = PreviousCharacter(at);
    if (at == 0) return 0;
    const WordClass run = Classify(CodePointAt(text_, PreviousCharacter(at)));
    while (at > 0 && Classify(CodePointAt(text_, PreviousCharacter(at))) == run) at = PreviousCharacter(at);
    return at;
}

size_t TextEditing::NextWord(size_t at) const {
    if (at < text_.size()) {
        const WordClass run = Classify(CodePointAt(text_, at));
        if (run != WordClass::Space) {
            while (at < text_.size() && Classify(CodePointAt(text_, at)) == run) at = NextCharacter(at);
        }
    }
    while (at < text_.size() && Classify(CodePointAt(text_, at)) == WordClass::Space) at = NextCharacter(at);
    return at;
}

bool CopyText(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return false;
    bool copied = false;
    if (EmptyClipboard()) {
        const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
        if (HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
            if (void* data = GlobalLock(memory)) {
                std::memcpy(data, text.c_str(), bytes);
                GlobalUnlock(memory);
                copied = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
            }
            if (!copied) GlobalFree(memory);  // the clipboard owns it only once it's set
        }
    }
    CloseClipboard();
    return copied;
}

void TextEditing::Copy() const {
    if (HasSelection()) CopyText(window_, text_.substr(SelectionStart(), SelectionEnd() - SelectionStart()));
}

TextEditing::Change TextEditing::Paste() {
    if (!OpenClipboard(window_)) return Change::None;
    std::wstring pasted;
    if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
        if (const auto* text = static_cast<const wchar_t*>(GlobalLock(data))) {
            // Up to the terminating NUL, but never past the clipboard's own memory.
            const size_t most = GlobalSize(data) / sizeof(wchar_t);
            size_t length = 0;
            while (length < most && text[length]) ++length;
            pasted.assign(text, length);
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    // One line: each line break (CR LF, CR or LF) and other control character becomes a space.
    std::wstring line;
    line.reserve(pasted.size());
    for (size_t i = 0; i < pasted.size(); ++i) {
        const wchar_t c = pasted[i];
        if (c == L'\r' && i + 1 < pasted.size() && pasted[i + 1] == L'\n') continue;
        line.push_back(BreaksLine(c) ? L' ' : c);
    }
    return line.empty() ? Change::None : Insert(line);
}

std::optional<TextEditing::Change> TextEditing::KeyDown(UINT key, bool ctrl, bool shift) {
    const size_t end = text_.size();
    switch (key) {
    case VK_LEFT:
    case VK_RIGHT:
    case VK_HOME:
    case VK_END: {
        size_t to = caret_;
        if (key == VK_HOME) to = 0;
        else if (key == VK_END) to = end;
        else if (HasSelection() && !shift && !ctrl) to = key == VK_LEFT ? SelectionStart() : SelectionEnd();
        else if (key == VK_LEFT) to = ctrl ? PreviousWord(caret_) : PreviousCharacter(caret_);
        else to = ctrl ? NextWord(caret_) : NextCharacter(caret_);
        return Select(to, shift);
    }
    case VK_BACK:
        if (HasSelection()) return DeleteRange(SelectionStart(), SelectionEnd());
        if (caret_ > 0) return DeleteRange(ctrl ? PreviousWord(caret_) : PreviousCharacter(caret_), caret_);
        return Change::None;
    case VK_DELETE:
        if (shift && !ctrl) {  // Shift+Delete: cut
            Copy();
            return DeleteRange(SelectionStart(), SelectionEnd());
        }
        if (HasSelection()) return DeleteRange(SelectionStart(), SelectionEnd());
        if (caret_ < end) return DeleteRange(caret_, ctrl ? NextWord(caret_) : NextCharacter(caret_));
        return Change::None;
    case VK_INSERT:
        if (ctrl && !shift) Copy();
        else if (shift && !ctrl) return Paste();
        return Change::None;
    default:
        break;
    }
    if (!ctrl || shift) return std::nullopt;
    switch (key) {
    case 'A':
        SelectAll();
        return Change::Selection;
    case 'C':
        Copy();
        return Change::None;
    case 'X':
        Copy();
        return DeleteRange(SelectionStart(), SelectionEnd());
    case 'V':
        return Paste();
    default:
        return std::nullopt;
    }
}

TextEditing::Change TextEditing::Character(wchar_t c) {
    if (IsHighSurrogate(c)) {
        highSurrogate_ = c;
        return Change::None;
    }
    if (IsLowSurrogate(c)) {
        if (!highSurrogate_) return Change::None;
        const wchar_t pair[2] = {highSurrogate_, c};
        highSurrogate_ = 0;
        return Insert(std::wstring_view(pair, 2));
    }
    highSurrogate_ = 0;
    // Control characters (Ctrl+A's 0x01, Backspace's 0x08, Enter's 0x0D, Ctrl+Backspace's
    // 0x7F) are the keys KeyDown already handled; a line separator would start a second line.
    if (c < 0x20 || c == 0x7F) return Change::None;
    if (BreaksLine(c)) c = L' ';
    return Insert(std::wstring_view(&c, 1));
}

}  // namespace kite
