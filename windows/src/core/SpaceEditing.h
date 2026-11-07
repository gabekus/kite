#pragma once
// What the space bar's cells and the space's header offer for editing a space, platform-free:
// the space's menu (the Mac's SpaceContextMenus.menu, SidebarListRows.swift), what Delete Space
// does (BrowserWindowController+TabCommands.swift's deleteSpace) and New Space's outcome
// (BrowserStore's beginNewSpace and finishNewSpace). The edits themselves are BrowserState's
// (SpaceEditing.cpp); the shell shows the menu and the alert (shell/SpaceMenu).

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Models.h"

namespace kite {

// One entry of the space's menu, in Arc's order and words (its menu on 1 Nov 2026).
struct SpaceMenuItem {
    enum class Command {
        Separator,
        ChangeIcon,   // "Change Space Icon…": the icon picker (shell/SpaceIconPickerView)
        Rename,       // "Rename Space…": the header's name field
        Describe,     // "What's This Space For?…": Kite's own, a line Claude reads (no Claude on Windows yet)
        EditTheme,    // "Edit Theme Color…": the theme editor (not yet)
        SetProfile,   // "Set Profile ▸": a submenu of the profiles (Windows can't move a space's pages yet)
        NewFolder,    // "New Folder"
        LiveFolders,  // "Live Folders ▸": a submenu of the sources (no live folders on Windows yet)
        Delete,       // "Delete Space": not the last space
    };
    Command command = Command::Separator;
    std::string title;  // empty for a separator
    bool enabled = true;
    bool submenu = false;
    bool operator==(const SpaceMenuItem&) const = default;
};
// The menu for space `spaceID`, as the Mac builds it for a window that shows profiles (every
// window but an incognito one, which Windows hasn't yet). An item whose action Windows hasn't
// ported is there, disabled, so the menu keeps the Mac's shape. Empty for no such space.
std::vector<SpaceMenuItem> SpaceMenu(const BrowserState& state, const std::string& spaceID);
// Its lines for kitecore and the smoke test, as the Mac's KITE_TEST_CONTEXT_MENU logs a menu:
// "---" for a separator, a disabled item's title in brackets, a submenu's with " ▸".
std::string SpaceMenuLine(const std::vector<SpaceMenuItem>& items);

// What Delete Space does for a space: nothing for the last one (the Mac beeps), at once for one
// with no tabs (Arc deletes an empty space straight away), else after the Mac's alert, which
// asks with `title` and `message` and its Delete and Cancel buttons.
struct SpaceDeletion {
    enum class Kind { Refused, Now, Ask };
    Kind kind = Kind::Refused;
    std::string title, message;
    bool operator==(const SpaceDeletion&) const = default;
};
SpaceDeletion DeletionOf(const BrowserState& state, const std::string& spaceID);

// + › New Space with a name, as the Create a Space page leaves it once Create Space is pressed:
// a space right after the one you're in, selected, with that space's theme and profile, no
// icon and the name trimmed. None for a blank name (Create Space stays disabled).
std::optional<std::string> NewSpace(BrowserState& state, std::string_view name);

}  // namespace kite
