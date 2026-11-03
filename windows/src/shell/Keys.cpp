// See Keys.h.

#include "shell/Keys.h"

#include <string>

namespace kite {

namespace {

// The layout the user is typing with: the foreground window's thread's (a page's keys come on
// CEF's thread, whose own layout can lag behind a switch).
HKL CurrentLayout() { return GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), nullptr)); }

// What the key types on the layout, with Ctrl+Alt held or not (and Shift as held): a character,
// none, or a dead key (-1). Asked without changing the keyboard's dead-key state (flag 0x4).
int Typed(UINT vk, bool ctrlAlt, bool shift, HKL layout, wchar_t& typed) {
    BYTE state[256]{};
    if (ctrlAlt) state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_MENU] = state[VK_LMENU] = 0x80;
    if (shift) state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
    wchar_t buffer[8]{};
    const int count = ToUnicodeEx(vk, MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC, layout), state, buffer, 8, 0x4, layout);
    typed = buffer[0];
    return count;
}

// Whether Ctrl+Alt and this key type a character of their own on the layout (AltGr's: German
// Ctrl+Alt+Q is @), or a dead key. A layout without AltGr gives the key's own character, or a
// control character, for Ctrl+Alt: that's a shortcut.
bool TypesWithCtrlAlt(UINT vk, bool shift, HKL layout) {
    wchar_t withCtrlAlt = 0, plain = 0;
    const int count = Typed(vk, true, shift, layout, withCtrlAlt);
    if (count < 0) return true;
    if (count == 0 || withCtrlAlt < 0x20) return false;
    return Typed(vk, false, shift, layout, plain) <= 0 || plain != withCtrlAlt;
}

}  // namespace

std::optional<KeyShortcut> ShortcutOfKey(UINT vk, bool ctrl, bool alt, bool shift) {
    const bool function = vk >= VK_F1 && vk <= VK_F24;
    // Most keys typed have neither: done before anything else, as the Mac's router checks for
    // ⌘, ⌃, ⌥ or fn first.
    if (!ctrl && !alt && !function) return std::nullopt;
    std::string key;
    bool character = false;  // a key that can type, which AltGr may give a character
    if (vk >= 'A' && vk <= 'Z') {
        key = static_cast<char>(vk - 'A' + 'a');
        character = true;
    } else if (vk >= '0' && vk <= '9') {
        key = static_cast<char>(vk);
        character = true;
    } else if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) {
        // Ctrl+Numpad 1 is Ctrl+1, as in Chrome. Without Ctrl it's no shortcut: Alt and numpad
        // digits type a character by its code (Alt+0233 is é), which Alt+1's Space 1 mustn't take.
        if (!ctrl) return std::nullopt;
        key = static_cast<char>('0' + (vk - VK_NUMPAD0));
    } else if (function) {
        key = "f" + std::to_string(vk - VK_F1 + 1);
    } else {
        switch (vk) {
        case VK_LEFT: key = "left"; break;
        case VK_RIGHT: key = "right"; break;
        case VK_UP: key = "up"; break;
        case VK_DOWN: key = "down"; break;
        case VK_TAB: key = "tab"; break;
        case VK_RETURN: key = "return"; break;
        case VK_BACK: key = "delete"; break;
        case VK_ESCAPE: key = "escape"; break;
        case VK_SPACE: key = "space"; break;
        default: {
            // Punctuation: what the key types on this layout, unshifted. A dead key (the top
            // bit) or anything outside printable ASCII is no shortcut's.
            const UINT typed = MapVirtualKeyExW(vk, MAPVK_VK_TO_CHAR, CurrentLayout());
            if (typed & 0x80000000u) return std::nullopt;
            const UINT ch = typed & 0xFFFF;
            if (ch <= 0x20 || ch >= 0x7F) return std::nullopt;
            key = static_cast<char>(ch >= 'A' && ch <= 'Z' ? ch - 'A' + 'a' : ch);
            character = true;
        }
        }
    }
    if (ctrl && alt && character && TypesWithCtrlAlt(vk, shift, CurrentLayout())) return std::nullopt;
    std::vector<KeyShortcut::Modifier> modifiers;
    if (ctrl) modifiers.push_back(KeyShortcut::Modifier::Control);
    if (alt) modifiers.push_back(KeyShortcut::Modifier::Option);
    if (shift) modifiers.push_back(KeyShortcut::Modifier::Shift);
    return KeyShortcut(std::move(key), std::move(modifiers));
}

const ShortcutTarget* ShortcutForKey(const ShortcutMap& table, UINT vk, bool ctrl, bool alt, bool shift) {
    auto shortcut = ShortcutOfKey(vk, ctrl, alt, shift);
    return shortcut ? FindShortcut(table, *shortcut) : nullptr;
}

}  // namespace kite
