// See SidebarMenus.h.

#include "shell/SidebarMenus.h"

#include "shell/ContextMenu.h"

namespace kite {

namespace {

std::vector<ContextMenuEntry> Entries(const std::vector<SidebarMenuItem>& items) {
    std::vector<ContextMenuEntry> entries;
    for (const SidebarMenuItem& item : items) {
        ContextMenuEntry entry;
        entry.separator = item.command == SidebarMenuItem::Command::Separator;
        entry.title = item.title;
        entry.enabled = item.enabled;
        entry.submenu = item.submenu;
        entry.entries = Entries(item.items);
        entries.push_back(std::move(entry));
    }
    return entries;
}

// The item at depth-first `index`, as ContextMenu numbers its entries.
const SidebarMenuItem* ItemAt(const std::vector<SidebarMenuItem>& items, size_t index, size_t& next) {
    for (const SidebarMenuItem& item : items) {
        if (next++ == index) return &item;
        if (item.submenu) {
            if (const SidebarMenuItem* found = ItemAt(item.items, index, next)) return found;
        }
    }
    return nullptr;
}

}  // namespace

std::optional<SidebarMenuItem> ShowSidebarMenu(HWND window, const std::vector<SidebarMenuItem>& items, POINT screen, bool dark) {
    const std::optional<size_t> chosen = ShowContextMenu(window, Entries(items), screen, dark);
    if (!chosen) return std::nullopt;
    size_t next = 0;
    const SidebarMenuItem* item = ItemAt(items, *chosen, next);
    if (!item) return std::nullopt;
    return *item;
}

std::wstring RenderSidebarMenu(HWND window, const std::vector<SidebarMenuItem>& items, POINT screen, bool dark, UINT dpi, Pixels& out) {
    return RenderContextMenu(window, Entries(items), screen, dark, dpi, out);
}

bool AskToDeleteFolder(HWND window, const FolderDeletion& deletion) {
    return deletion.ask && AskToConfirm(window, deletion.title, deletion.message, deletion.confirm);
}

}  // namespace kite
