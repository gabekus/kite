#pragma once
// The sidebar's row menus (a tab's, a folder's, a favorite's) and a folder's Delete question, as
// Windows' own: the Mac's are AppKit's (NSMenus from TabRowCell's, FolderRowCell's and
// FavoritePaneView's contextMenu, shown by showSidebarMenu, and deleteFolder's NSAlert sheet), so
// these are a Win32 popup menu through shell/ContextMenu, as the space's menu is, and a task
// dialog. What they hold is core's (core/SidebarContextMenu.h).

#include <windows.h>

#include <optional>
#include <vector>

#include "core/SidebarContextMenu.h"
#include "shell/Capture.h"

namespace kite {

// Shows `items` at `screen` (px) for `window`, dark or light, and waits until it closes. The
// item chosen (an enabled one, in a submenu or not), or none.
std::optional<SidebarMenuItem> ShowSidebarMenu(HWND window, const std::vector<SidebarMenuItem>& items, POINT screen, bool dark);

// For --capture: the menu as it shows, read back (RenderContextMenu). Empty on success.
std::wstring RenderSidebarMenu(HWND window, const std::vector<SidebarMenuItem>& items, POINT screen, bool dark, UINT dpi, Pixels& out);

// deleteFolder's alert: its title, message, Delete Folder (the default) and Cancel. True for Delete Folder.
bool AskToDeleteFolder(HWND window, const FolderDeletion& deletion);

}  // namespace kite
