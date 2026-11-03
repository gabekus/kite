#pragma once
// A key Windows reports (a virtual-key code and the modifiers held) as the shortcut it is
// (core/KeyBindings.h): letters and digits by name, punctuation by the character it types on the
// current keyboard layout without Shift (as the Mac matches key equivalents), and named keys.
// Kite's window and its pages both look keys up here, so they agree on what's a shortcut.

#include <windows.h>

#include <optional>

#include "core/KeyBindings.h"

namespace kite {

// None for a key that's no shortcut's: one without Ctrl or Alt (other than F1–F24), which types;
// a modifier on its own or a dead key; and a Ctrl+Alt key that types a character on the current
// layout (AltGr's, which Windows also gives Left Ctrl+Left Alt).
std::optional<KeyShortcut> ShortcutOfKey(UINT virtualKey, bool ctrl, bool alt, bool shift);

// The command a key runs, if any.
const ShortcutTarget* ShortcutForKey(const ShortcutMap& table, UINT virtualKey, bool ctrl, bool alt, bool shift);

}  // namespace kite
