#pragma once
// Kite's context menus as Windows' own popup menus (TrackPopupMenuEx), shared by the space's menu
// (shell/SpaceMenu) and the sidebar's row menus (shell/SidebarMenus): the Mac's are AppKit's
// NSMenus, so these look like Windows' and open on the right button's release, as Windows' context
// menus do. What they hold is core's; this shows a tree of entries and says which was chosen.
//
// Win32 menus draw light unless the process asks uxtheme for dark ones, which only its unnamed
// exports do (SetPreferredAppMode and FlushMenuThemes, ordinals 135 and 136, as Explorer and
// Notepad use them). They're called only on Windows 10 1903 (build 18362) and later, only while a
// menu is open (the mode is process-wide: it goes back to the default as the menu closes), and
// without them a dark space's menu is light (docs/windows-architecture.md).

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "shell/Capture.h"

namespace kite {

// One entry: a separator, an item, or a submenu of more entries.
struct ContextMenuEntry {
    bool separator = false;
    std::string title;  // UTF-8, as the Mac's
    bool enabled = true;
    bool submenu = false;
    std::vector<ContextMenuEntry> entries;  // a submenu's
};

// Each entry's index in the tree, depth first, every entry counted (separators and submenus
// too): what ShowContextMenu returns for the one chosen.
size_t ContextMenuSize(const std::vector<ContextMenuEntry>& entries);

// Shows `entries` at `screen` (px) for `window`, dark or light, and waits until it closes
// (Windows' menu loop). The chosen entry's index (an enabled item, never a submenu or a
// separator), or none.
std::optional<size_t> ShowContextMenu(HWND window, const std::vector<ContextMenuEntry>& entries, POINT screen, bool dark);

// For --capture: the menu opened at `screen` as ShowContextMenu would, read back once it shows
// (PrintWindow of its window: without the rounded corners and shadow DWM adds) and closed,
// scaled from its monitor's DPI to `dpi` (the capture's), as it would draw on a monitor at the
// capture's scale. Empty on success.
std::wstring RenderContextMenu(HWND window, const std::vector<ContextMenuEntry>& entries, POINT screen, bool dark, UINT dpi, Pixels& out);

// A question before a destructive edit, as the Mac's NSAlert sheets ask: `title` as the main
// instruction, `message`, and `confirm` (the default, as the Mac's first button) and Cancel. A
// task dialog (Common Controls 6), always light. True for `confirm`.
bool AskToConfirm(HWND window, const std::string& title, const std::string& message, const std::string& confirm);

}  // namespace kite
