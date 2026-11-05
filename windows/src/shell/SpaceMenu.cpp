// See SpaceMenu.h. The menu itself is Windows' (shell/ContextMenu, shared with the sidebar's row
// menus).

#include "shell/SpaceMenu.h"

#include "shell/ContextMenu.h"

namespace kite {

namespace {

// One entry an item, in order (a submenu's items come with what they set: none yet), so an
// entry's index is its item's.
std::vector<ContextMenuEntry> Entries(const std::vector<SpaceMenuItem>& items) {
    std::vector<ContextMenuEntry> entries;
    for (const SpaceMenuItem& item : items) {
        ContextMenuEntry entry;
        entry.separator = item.command == SpaceMenuItem::Command::Separator;
        entry.title = item.title;
        entry.enabled = item.enabled;
        entry.submenu = item.submenu;
        entries.push_back(std::move(entry));
    }
    return entries;
}

}  // namespace

std::optional<SpaceMenuItem::Command> ShowSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark) {
    const std::optional<size_t> chosen = ShowContextMenu(window, Entries(items), screen, dark);
    if (!chosen || *chosen >= items.size()) return std::nullopt;
    return items[*chosen].command;
}

std::wstring RenderSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark, UINT dpi, Pixels& out) {
    return RenderContextMenu(window, Entries(items), screen, dark, dpi, out);
}

bool AskToDeleteSpace(HWND window, const SpaceDeletion& deletion) {
    // The Mac's first button, Delete, is its default (Return).
    return AskToConfirm(window, deletion.title, deletion.message, "Delete");
}

}  // namespace kite
