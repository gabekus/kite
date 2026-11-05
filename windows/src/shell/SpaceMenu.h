#pragma once
// The space's menu and Delete Space's question, as Windows' own: the Mac's are AppKit's (an
// NSMenu from SpaceContextMenus.menu and an NSAlert sheet), so these are a Win32 popup menu
// (TrackPopupMenuEx) and a task dialog, through shell/ContextMenu (which says how a dark space's
// menu is dark). What they hold is core's (core/SpaceEditing.h). The task dialog is always light.

#include <windows.h>

#include <optional>
#include <vector>

#include "core/SpaceEditing.h"
#include "shell/Capture.h"

namespace kite {

// Shows `items` at `screen` (px) for `window`, in the space's appearance, and waits until it
// closes (Windows' menu loop). The command chosen, or none.
std::optional<SpaceMenuItem::Command> ShowSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark);

// For --capture: the menu opened at `screen` as ShowSpaceMenu would, read back once it shows
// (PrintWindow of its window: without the rounded corners and shadow DWM adds) and closed,
// scaled from its monitor's DPI to `dpi` (the capture's), as it would draw on a monitor at
// the capture's scale. Empty on success.
std::wstring RenderSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark, UINT dpi, Pixels& out);

// The Mac's alert for a space with tabs: its title as the main instruction, its message, and
// Delete (the default, as the Mac's first button) and Cancel. True for Delete.
bool AskToDeleteSpace(HWND window, const SpaceDeletion& deletion);

}  // namespace kite
