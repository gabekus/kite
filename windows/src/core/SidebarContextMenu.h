#pragma once
// The sidebar's context menus for its rows, platform-free: a tab's (Today or pinned, TabRowCell's
// contextMenu(at:)), a folder's (FolderRowCell's, and a live folder's addLiveFolderItems) and a
// favorite's (FavoritePaneView's menu(for:)), in SidebarListCells.swift and SidebarFavorites.swift,
// with the Mac's items, order, words, separators and enabled states. The edits they make that
// aren't plain commands are BrowserState's (SidebarContextMenu.swift, here in
// SidebarContextMenu.cpp); LinkFormat.markdown (LinkFormat.swift) is the Copy … as Markdown items'.
// The shell shows the menus and runs their items (shell/SidebarMenus); the space's menu is
// core/SpaceEditing.h's.
//
// Windows has no rows for splits yet, so the split row's menu (SplitRowCell's) isn't here, nor
// Tidy Tabs' group header's Remove header. The empty sidebar, New Tab and the Today divider have
// no menu on the Mac (SidebarTableView's menu(for:) is nil, and those cells build none).

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Models.h"
#include "core/Sidebar.h"

namespace kite {

// LinkFormat.swift: `[title](url)`, the URL as the text when the title is blank, with `\`, `[` and
// `]` escaped in the text, newlines there as spaces, and `(`, `)` and spaces in the destination
// percent-encoded.
std::string MarkdownLink(std::string_view title, std::string_view url);
// A tab as `[title](url)` with the title its row shows (a Rename… name wins); none without a URL.
std::optional<std::string> MarkdownLink(const Tab& tab);
// Copy All Links as Markdown: one `[title](url)` a line, in sidebar order, tabs with no URL left out.
std::string MarkdownLinkList(const std::vector<const Tab*>& tabs);

// BrowserState.claudeMayCreateSpace: Kite never makes a space named Claude (any case, spaces and
// tabs around it ignored).
bool ClaudeMayCreateSpace(std::string_view name);

// One entry of a row's menu.
struct SidebarMenuItem {
    enum class Command {
        Separator,
        // A tab's and a favorite's.
        AddToFavorites,         // "Add to Favorites"
        RemoveFromFavorites,    // "Remove from Favorites" (a favorite's)
        TogglePin,              // "Pin Tab" / "Unpin Tab"
        BackToPinnedURL,        // a pinned tab off its pinned page
        SeparateFromPinnedTab,  // likewise
        EditPinnedPage,         // "Edit Pinned Page ▸", a pinned tab's or favorite's with a pinned URL
        EditPinnedURL,          //   "Edit…": Arc's Edit Pinned URL dialog (ArcDialog, W19)
        ReplacePinnedURL,       //   "Replace Pinned URL with Current"
        CopyLink,               // "Copy Link"
        CopyLinkAsMarkdown,     // "Copy link as Markdown"
        RenameTab,              // "Rename…": the row's field
        AddSplitView,           // "Add Split View" on the tab on screen (split view, W36)
        OpenInSplitView,        // "Open in Split View" on one that isn't (likewise)
        DuplicateTab,           // "Duplicate"
        MoveTo,                 // "Move to ▸": a submenu of the spaces (moving between spaces isn't ported)
        MoveToSpace,            //   one space (`target` is its id)
        CloseTab,               // "Close Tab", or "Unload Tab" for a pinned tab or favorite
        ArchiveOthers,          // "Archive Other Tabs", a Today tab's
        ArchiveBelow,           // "Archive Tabs Below"
        ArchiveAbove,           // "Archive Tabs Above"
        // A folder's.
        DuplicateFolder,         // "Duplicate"
        DeleteFolder,            // "Delete": asks first (FolderDeletionOf)
        NewNestedFolder,         // "New Nested Folder…", then its rename
        TurnFolderIntoSpace,     // "Turn “Name” into Space"
        CopyAllLinks,            // "Copy All Links"
        CopyAllLinksAsMarkdown,  // "Copy All Links as Markdown"
        RenameFolder,            // "Rename…": the row's field
        // A live folder's (live folders aren't ported: their items are there, disabled).
        RefreshLiveFolder,  // "Refresh"
        DeleteLiveFolder,   // "Delete Live Folder"
    };
    Command command = Command::Separator;
    std::string title;  // empty for a separator
    bool enabled = true;
    bool submenu = false;
    std::vector<SidebarMenuItem> items;  // a submenu's
    std::string target;                  // MoveToSpace: the space
    bool operator==(const SidebarMenuItem&) const = default;
};

// What a row's menu is for: the sidebar's rows (a tab's or a folder's) and the favorites' panes.
enum class SidebarMenuKind { Tab, Folder, Favorite };

// The menus, as the Mac builds them for this state. Empty for no such tab or folder, a favorite's
// id given as a tab's (or a space's tab as a favorite's). Windows has no Claude automation, sound
// or Peek yet, so the Mac's items for those (Stop Claude, Mute Tab, the Peek badge) never show, as
// on a Mac where nothing is playing and Claude isn't driving a tab. Items whose action Windows
// hasn't ported are there, disabled, so the menu keeps the Mac's shape.
std::vector<SidebarMenuItem> TabMenu(const BrowserState& state, const std::string& tabID);
std::vector<SidebarMenuItem> FolderMenu(const BrowserState& state, const std::string& folderID);
std::vector<SidebarMenuItem> FavoriteMenu(const BrowserState& state, const std::string& tabID);
std::vector<SidebarMenuItem> SidebarMenu(const BrowserState& state, SidebarMenuKind kind, const std::string& id);

// A menu's line, as the Mac's KITE_TEST_CONTEXT_MENU logs one (showSidebarMenu) and
// SpaceMenuLine writes the space's: items joined by " | ", "---" for a separator, a disabled
// item's title in brackets, a submenu's as "Title ▸ [a / b]" (just "Title ▸" with nothing in it).
std::string SidebarMenuLine(const std::vector<SidebarMenuItem>& items);
// The enabled item a test picks by its title, or "Submenu ▸ Item" for one in a submenu (the Mac's
// testPick). Null when there's none, or it's disabled.
const SidebarMenuItem* PickSidebarMenuItem(const std::vector<SidebarMenuItem>& items, std::string_view pick);

// Where a right-click (or a Ctrl+click, the Mac's ⌃-click) on space `space`'s page opens a menu,
// for a sidebar `width`×`height` points scrolled `scroll`, its page from `listTop`: the header's
// cell (its chevron too) is the space's menu (core/SpaceEditing.h), a tab's pill (its buttons too:
// a click on them passes the menu up to the row) the tab's, a folder's the folder's. The address
// field, New Tab, the divider and the gaps between pills have none. The space bar and the
// favorites are asked first, by the caller (SpaceBarPressAt, FavoritePressAt).
struct SidebarMenuTarget {
    enum class Kind { Space, Tab, Folder };
    Kind kind = Kind::Tab;
    std::string id;
    bool operator==(const SidebarMenuTarget&) const = default;
};
std::optional<SidebarMenuTarget> SidebarMenuTargetAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll,
                                                     float x, float y, float listTop = sidebar_metrics::kHeaderAreaHeight);

// What a folder's Delete does (BrowserWindowController+TabCommands.swift's deleteFolder): asks
// first, in Arc's words, with Delete Folder (the default) and Cancel, then archives the tabs
// inside. Nothing for no such folder.
struct FolderDeletion {
    bool ask = false;
    std::string title, message, confirm;
    bool operator==(const FolderDeletion&) const = default;
};
FolderDeletion FolderDeletionOf(const BrowserState& state, const std::string& folderID);

}  // namespace kite
