#pragma once
// A key Windows reports (a virtual-key code and the modifiers held) as the shortcut it is
// (core/KeyBindings.h): letters and digits by name, punctuation by the character it types on the
// current keyboard layout without Shift (as the Mac matches key equivalents), and named keys.

#include <windows.h>

#include <optional>

#include "core/KeyBindings.h"

namespace kite {

// None for a key that's no shortcut's (a modifier on its own, a dead key).
std::optional<KeyShortcut> ShortcutOfKey(UINT virtualKey, bool ctrl, bool alt, bool shift);

}  // namespace kite
