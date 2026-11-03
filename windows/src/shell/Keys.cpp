// See Keys.h.

#include "shell/Keys.h"

#include <string>

namespace kite {

std::optional<KeyShortcut> ShortcutOfKey(UINT vk, bool ctrl, bool alt, bool shift) {
    std::string key;
    if (vk >= 'A' && vk <= 'Z') {
        key = static_cast<char>(vk - 'A' + 'a');
    } else if (vk >= '0' && vk <= '9') {
        key = static_cast<char>(vk);
    } else if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) {
        key = static_cast<char>('0' + (vk - VK_NUMPAD0));  // Ctrl+Numpad 1 is Ctrl+1, as in Chrome
    } else if (vk >= VK_F1 && vk <= VK_F24) {
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
            const UINT typed = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR);
            if (typed & 0x80000000u) return std::nullopt;
            const UINT ch = typed & 0xFFFF;
            if (ch <= 0x20 || ch >= 0x7F) return std::nullopt;
            key = static_cast<char>(ch >= 'A' && ch <= 'Z' ? ch - 'A' + 'a' : ch);
        }
        }
    }
    std::vector<KeyShortcut::Modifier> modifiers;
    if (ctrl) modifiers.push_back(KeyShortcut::Modifier::Control);
    if (alt) modifiers.push_back(KeyShortcut::Modifier::Option);
    if (shift) modifiers.push_back(KeyShortcut::Modifier::Shift);
    return KeyShortcut(std::move(key), std::move(modifiers));
}

}  // namespace kite
