// The window controller's row menus: a tab's, a folder's and a favorite's, shown on a right-click
// or a Ctrl+click (shell/SidebarView), and what their items do. The Mac's TabRowCell,
// FolderRowCell and FavoritePaneView menus (SidebarListCells.swift, SidebarFavorites.swift) with
// their SidebarActions: BrowserWindowController+SidebarMenus.swift (archiveTabs), +TabCommands.swift
// (separateFromPinnedTab, replacePinnedURLWithCurrent, renameFolder, deleteFolder) and the
// store's mutations they make inline. The menus themselves are core's (core/SidebarContextMenu.h).
// Then the smoke test's checks of them and the captures' held menus. See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <cmath>

#include "shell/SidebarMenus.h"
#include "shell/Text.h"
#include "shell/TextEditing.h"

namespace kite {

std::vector<SidebarMenuItem> BrowserWindowController::OpenRowMenu(SidebarMenuKind kind, const std::string& id) {
    // The menu takes the keyboard and the pointer until it closes, so a rename open ends first,
    // keeping what was typed, as for the space's menu (OpenSpaceMenu).
    sidebar_->EndRenaming(true);
    return SidebarMenu(state_, kind, id);
}

void BrowserWindowController::ShowRowMenu(SidebarMenuKind kind, const std::string& id, POINT screen) {
    const std::vector<SidebarMenuItem> items = OpenRowMenu(kind, id);
    if (items.empty() || !showRowMenu_) return;
    if (const std::optional<SidebarMenuItem> chosen = showRowMenu_(items, screen)) RunRowMenuItem(kind, id, *chosen);
}

void BrowserWindowController::RunRowMenuItem(SidebarMenuKind kind, const std::string& id, const SidebarMenuItem& item) {
    using C = SidebarMenuItem::Command;
    using R = BrowserState::ArchiveTabsRelative;
    if (!item.enabled) return;
    const bool folder = kind == SidebarMenuKind::Folder;
    // The tab or folder can have gone while the menu was up (a page closing itself).
    if (folder ? !state_.FolderByID(id) : !state_.Location(id)) return;
    switch (item.command) {
    case C::AddToFavorites:
    case C::RemoveFromFavorites: EditState([&] { state_.ToggleFavorite(id); }); break;
    case C::TogglePin: EditState([&] { state_.TogglePin(id); }); break;
    case C::BackToPinnedURL: BackToPinnedURL(id); break;
    case C::SeparateFromPinnedTab: SeparateFromPinnedTab(id); break;
    case C::ReplacePinnedURL: {
        bool replaced = false;
        EditState([&] { replaced = state_.ReplacePinnedURLWithCurrent(id); });
        if (!replaced) MessageBeep(MB_OK);
        break;
    }
    case C::CopyLink: CopyToClipboard(state_.FindTabByID(id)->url); break;
    case C::CopyLinkAsMarkdown: CopyToClipboard(MarkdownLink(*state_.FindTabByID(id))); break;
    case C::RenameTab: BeginRenamingTab(id, false); break;
    case C::DuplicateTab: EditState([&] { state_.Duplicate(id); }, true); break;
    case C::CloseTab: CloseTab(id); break;
    case C::ArchiveOthers: ArchiveTabs(R::Others, id); break;
    case C::ArchiveBelow: ArchiveTabs(R::Below, id); break;
    case C::ArchiveAbove: ArchiveTabs(R::Above, id); break;
    case C::DuplicateFolder: EditState([&] { state_.DuplicateFolder(id); }); break;
    case C::DeleteFolder: DeleteFolder(id); break;
    case C::NewNestedFolder: NewNestedFolder(id); break;
    case C::TurnFolderIntoSpace: TurnFolderIntoSpace(id); break;
    case C::CopyAllLinks:
    case C::CopyAllLinksAsMarkdown: {
        const std::vector<const Tab*> tabs = TabsIn(state_.FolderByID(id)->items);
        if (item.command == C::CopyAllLinksAsMarkdown) {
            CopyToClipboard(MarkdownLinkList(tabs));
            break;
        }
        std::string links;
        for (const Tab* tab : tabs) {
            if (!tab->url) continue;
            if (!links.empty()) links += '\n';
            links += *tab->url;
        }
        CopyToClipboard(links);
        break;
    }
    case C::RenameFolder: BeginRenamingFolder(id); break;
    // Disabled on Windows until their checkpoints (core's TabMenu and FolderMenu); the submenus'
    // parents aren't chosen.
    case C::EditPinnedPage:
    case C::EditPinnedURL:
    case C::AddSplitView:
    case C::OpenInSplitView:
    case C::MoveTo:
    case C::MoveToSpace:
    case C::RefreshLiveFolder:
    case C::DeleteLiveFolder:
    case C::Separator: break;
    }
}

void BrowserWindowController::SeparateFromPinnedTab(const std::string& tabID) {
    // separateFromPinnedTab(_:): the page it wandered to opens in Today, selected, and the pinned
    // tab's own page goes home.
    const Tab* tab = state_.FindTabByID(tabID);
    if (!tab || !tab->pinnedURL) return;
    const std::string home = *tab->pinnedURL;
    std::optional<std::string> made;
    EditState([&] { made = state_.SeparateFromPinnedTab(tabID); }, true);
    if (made) LoadInTab(tabID, home);
}

void BrowserWindowController::ArchiveTabs(BrowserState::ArchiveTabsRelative which, const std::string& tabID) {
    std::vector<Tab> archived;
    EditState([&] { archived = state_.ArchiveTabs(which, tabID); }, true);
    // The Mac beeps for none (the item is disabled then); its "Archived N tabs" toast comes with W16.
    if (archived.empty()) return static_cast<void>(MessageBeep(MB_OK));
    for (const Tab& tab : archived) PageGone(tab.id);
}

void BrowserWindowController::DeleteFolder(const std::string& folderID) {
    // deleteFolder(_:): asks first, in Arc's words, then archives the tabs inside (its "Folder
    // deleted" toast comes with W16).
    const FolderDeletion deletion = FolderDeletionOf(state_, folderID);
    if (!deletion.ask || !askToDeleteFolder_ || !askToDeleteFolder_(deletion)) return;
    if (!state_.FolderByID(folderID)) return;  // gone while the question was up
    std::vector<Tab> archived;
    EditState([&] { archived = state_.DeleteFolder(folderID); }, true);
    for (const Tab& tab : archived) PageGone(tab.id);
}

void BrowserWindowController::NewNestedFolder(const std::string& folderID) {
    // createNestedFolder, then store.beginRenaming(folder:) on it.
    std::optional<std::string> nested;
    EditState([&] { nested = state_.CreateNestedFolder(folderID); });
    if (nested) BeginRenamingFolder(*nested);
}

void BrowserWindowController::TurnFolderIntoSpace(const std::string& folderID) {
    // The new space is selected, as a new space is: the pages slide to it.
    EditState([&] { state_.TurnFolderIntoSpace(folderID); }, true);
}

void BrowserWindowController::CopyToClipboard(const std::optional<std::string>& text) {
    // copyToPasteboard; nothing to copy (a favorite with no page) copies nothing.
    if (text && !CopyText(window_.Handle(), Widen(*text))) MessageBeep(MB_OK);
}

// MARK: Captures

std::wstring BrowserWindowController::HoldRowMenu(size_t index) {
    const std::vector<SidebarRow>& rows = sidebar_->Rows();
    if (index >= rows.size() || (rows[index].kind != SidebarRow::Kind::Tab && rows[index].kind != SidebarRow::Kind::Folder)) {
        return L"that row isn't a tab or a folder (the header's menu is --space-menu's)";
    }
    const std::optional<POINT> at = sidebar_->RowCentre(index);
    if (!at) return L"that row isn't in view";
    const SidebarMenuKind kind = rows[index].kind == SidebarRow::Kind::Tab ? SidebarMenuKind::Tab : SidebarMenuKind::Folder;
    heldRowMenu_ = HeldRowMenu{kind, rows[index].id, *at};
    return {};
}

std::wstring BrowserWindowController::HoldFavoriteMenu(size_t index) {
    size_t i = 0;
    for (const FavoriteTile& tile : sidebar_->Favorites().tiles) {
        for (const FavoritePane& pane : tile.panes) {
            if (i++ != index) continue;
            const std::optional<POINT> at = sidebar_->FavoriteCentre(index);
            if (!at) return L"that favorite isn't in view";
            heldRowMenu_ = HeldRowMenu{SidebarMenuKind::Favorite, pane.tabID, *at};
            return {};
        }
    }
    return L"there's no such favorite";
}

std::wstring BrowserWindowController::RenderHeldRowMenu(Pixels& pixels) {
    if (!heldRowMenu_) return {};
    const std::vector<SidebarMenuItem> items = SidebarMenu(state_, heldRowMenu_->kind, heldRowMenu_->id);
    if (items.empty()) return L"there's nothing for the menu";
    // Its line, as the Mac's KITE_TEST_CONTEXT_MENU logs a menu (stderr; a capture shows no dialog).
    WriteUtf8(STD_ERROR_HANDLE, L"KITE_TEST_CONTEXT_MENU: " + Widen(SidebarMenuLine(items)) + L"\n");
    // Where a right-click there puts it: its top-left at the pointer.
    POINT screen = heldRowMenu_->at;
    ClientToScreen(window_.Handle(), &screen);
    Pixels menu;
    std::wstring problem = RenderSidebarMenu(window_.Handle(), items, screen, dark_.value_or(true), window_.Dpi(), menu);
    if (problem.empty()) ComposeOver(pixels, menu, heldRowMenu_->at);
    return problem;
}

// MARK: The smoke test

namespace {

// A mouse message to the window, as the pointer would send it at `at` (client px).
void Mouse(HWND window, UINT message, POINT at, WPARAM buttons) { SendMessageW(window, message, buttons, MAKELPARAM(at.x, at.y)); }

}  // namespace

std::wstring BrowserWindowController::SmokeTestRowMenus() {
    // Everything here is undone at the end: the session as it was, the pages it made closed, and
    // the menu and the question back to Windows'.
    const BrowserState before = state_;
    const auto shower = showRowMenu_;
    const auto asker = askToDeleteFolder_;
#ifdef KITE_HAS_CEF
    holdPages_ = true;
#endif
    const HWND window = window_.Handle();
    const auto done = [&](std::wstring problem) {
        Mouse(window, WM_MOUSELEAVE, POINT{}, 0);
        sidebar_->ClearHover();
        if (sidebar_->Renaming()) sidebar_->TakeRename();
        std::vector<std::string> made;
        for (const Space& space : state_.spaces) {
            for (const Tab* tab : space.AllTabs()) {
                if (!before.FindTabByID(tab->id)) made.push_back(tab->id);
            }
        }
        showRowMenu_ = shower;
        askToDeleteFolder_ = asker;
        state_ = before;
#ifdef KITE_HAS_CEF
        holdPages_ = false;
#endif
        ShowPage();
        for (const std::string& id : made) PageGone(id);
        StateChanged();
        return problem;
    };
    // The menu as the Mac's KITE_TEST_CONTEXT_MENU has it: read (its line), and `pick` chosen.
    std::vector<std::string> lines;
    std::string pick;
    showRowMenu_ = [&](const std::vector<SidebarMenuItem>& items, POINT) -> std::optional<SidebarMenuItem> {
        lines.push_back(SidebarMenuLine(items));
        const SidebarMenuItem* chosen = pick.empty() ? nullptr : PickSidebarMenuItem(items, pick);
        return chosen ? std::optional(*chosen) : std::nullopt;
    };
    std::vector<FolderDeletion> asked;
    bool answer = false;
    askToDeleteFolder_ = [&](const FolderDeletion& deletion) {
        asked.push_back(deletion);
        return answer;
    };
    const auto rowOf = [&](SidebarRow::Kind kind, const std::string& id) -> std::optional<POINT> {
        const std::vector<SidebarRow>& rows = sidebar_->Rows();
        for (size_t i = 0; i < rows.size(); ++i) {
            if (rows[i].kind == kind && rows[i].id == id) return sidebar_->RowCentre(i);
        }
        return std::nullopt;
    };
    const auto rightClick = [&](POINT at, std::string chosen) {
        pick = std::move(chosen);
        Mouse(window, WM_MOUSEMOVE, at, 0);
        Mouse(window, WM_RBUTTONDOWN, at, MK_RBUTTON);
        Mouse(window, WM_RBUTTONUP, at, 0);
    };
    const auto controlClick = [&](POINT at, std::string chosen) {
        pick = std::move(chosen);
        Mouse(window, WM_MOUSEMOVE, at, MK_CONTROL);
        Mouse(window, WM_LBUTTONDOWN, at, MK_LBUTTON | MK_CONTROL);
        Mouse(window, WM_LBUTTONUP, at, MK_CONTROL);
    };

    // A Today tab (selected) and a folder with a tab in it, in the selected space.
    const size_t space = state_.SelectedSpaceIndex();
    const std::string spaceID = state_.spaces[space].id;
    const std::string inFolder = state_.OpenTab("https://folder.example/", spaceID, false);
    const std::string other = state_.OpenTab("https://other.example/", spaceID, false);
    const std::string tab = state_.OpenTab("https://menu.example/", spaceID, true);
    const std::string folder = state_.CreateFolder("Menus", space);
    state_.MoveTabToFolder(inFolder, folder);
    StateChanged();
    if (std::wstring problem = Draw(); !problem.empty()) return done(L"the sidebar couldn't draw: " + problem);
    std::optional<POINT> tabAt = rowOf(SidebarRow::Kind::Tab, tab), folderAt = rowOf(SidebarRow::Kind::Folder, folder);
    const std::optional<POINT> newTabAt = rowOf(SidebarRow::Kind::NewTab, spaceID);
    if (!tabAt || !folderAt || !newTabAt) return done(L"the menu test's rows aren't in view");

    // A right-click on the tab's row: the tab's menu, the Mac's (core's TabMenu), and nothing chosen
    // changes nothing.
    rightClick(*tabAt, "");
    if (lines.size() != 1 || lines.back() != SidebarMenuLine(TabMenu(state_, tab))) return done(L"a right-click on a tab's row didn't open its menu");
    // On New Tab: no menu (the Mac's NewTabRowCell builds none).
    rightClick(*newTabAt, "");
    if (lines.size() != 1) return done(L"a right-click on New Tab opened a menu");
    // A Ctrl+click on the other tab's row is a right-click there: its menu, and its Pin Tab pins it;
    // the press selects nothing (the Mac's ⌃-click goes to rightMouseDown, not a tap).
    const std::optional<POINT> otherAt = rowOf(SidebarRow::Kind::Tab, other);
    if (!otherAt) return done(L"the menu test's second tab isn't in view");
    controlClick(*otherAt, "Pin Tab");
    if (lines.size() != 2 || lines.back().rfind("Add to Favorites | Pin Tab | ", 0) != 0) return done(L"a Ctrl+click on a tab's row didn't open its menu");
    const auto pinned = state_.Location(other);
    if (!pinned || pinned->section != TabSection::Pinned) return done(L"the tab menu's Pin Tab didn't pin the tab");
    if (!state_.SelectedTab() || state_.SelectedTab()->id != tab) return done(L"a Ctrl+click on a tab's row selected it");
    if (GetCapture() == window) return done(L"a Ctrl+click kept the mouse");
    // Its menu now says Unpin Tab, and offers Edit Pinned Page.
    if (std::wstring problem = Draw(); !problem.empty()) return done(L"the sidebar couldn't draw: " + problem);
    const std::optional<POINT> pinnedAt = rowOf(SidebarRow::Kind::Tab, other);
    if (!pinnedAt) return done(L"the pinned tab isn't in view");
    rightClick(*pinnedAt, "");
    if (lines.back().find("Unpin Tab | Edit Pinned Page") == std::string::npos) return done(L"a pinned tab's menu isn't the Mac's");

    // The folder's menu: the Mac's, and its Rename… opens the folder's rename field.
    folderAt = rowOf(SidebarRow::Kind::Folder, folder);
    if (!folderAt) return done(L"the menu test's folder isn't in view");
    rightClick(*folderAt, "Rename\xE2\x80\xA6");
    if (lines.back() != SidebarMenuLine(FolderMenu(state_, folder))) return done(L"a right-click on a folder's row didn't open its menu");
    if (sidebar_->Renaming() != SidebarView::RenameTarget{SidebarRow::Kind::Folder, folder}) {
        return done(L"the folder menu's Rename\x2026 didn't open the folder's rename");
    }
    // A Ctrl+click on the folder's icon mid-rename (outside the field, which takes its own presses):
    // the menu, which ends the rename keeping what was typed.
    sidebar_->TypeInRename("Menus 2");
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    controlClick(POINT{std::lround((sidebar_metrics::kPadding + sidebar_metrics::kIconInset + 4) * scale), folderAt->y}, "");
    if (lines.back() != SidebarMenuLine(FolderMenu(state_, folder))) return done(L"a Ctrl+click on a renamed folder's icon didn't open its menu");
    if (sidebar_->Renaming() || !state_.FolderByID(folder) || state_.FolderByID(folder)->name != "Menus 2") {
        return done(L"the folder menu opening didn't end its rename, keeping what was typed");
    }
    // New Nested Folder…: a folder inside it, open, renaming.
    const size_t foldersBefore = state_.Folders(space).size();
    rightClick(*folderAt, "New Nested Folder\xE2\x80\xA6");
    const Folder* parent = state_.FolderByID(folder);
    if (state_.Folders(space).size() != foldersBefore + 1 || !parent || parent->items.empty() ||
        !std::holds_alternative<Folder>(parent->items.back().value)) {
        return done(L"the folder menu's New Nested Folder\x2026 didn't make a folder inside it");
    }
    const std::string nested = parent->items.back().Id();
    if (sidebar_->Renaming() != SidebarView::RenameTarget{SidebarRow::Kind::Folder, nested}) {
        return done(L"the new nested folder didn't open its rename");
    }
    sidebar_->EndRenaming(false);
    // Delete asks first, in Arc's words: Cancel keeps it, Delete Folder removes it and archives its tab.
    if (std::wstring problem = Draw(); !problem.empty()) return done(L"the sidebar couldn't draw: " + problem);
    folderAt = rowOf(SidebarRow::Kind::Folder, folder);
    if (!folderAt) return done(L"the menu test's folder isn't in view");
    answer = false;
    rightClick(*folderAt, "Delete");
    if (asked.size() != 1 || asked.back() != FolderDeletionOf(state_, folder) || !state_.FolderByID(folder)) {
        return done(L"the folder menu's Delete didn't ask, or Cancel didn't keep the folder");
    }
    answer = true;
    rightClick(*folderAt, "Delete");
    if (asked.size() != 2 || state_.FolderByID(folder) || state_.FolderByID(nested) || state_.FindTabByID(inFolder)) {
        return done(L"the folder menu's Delete didn't remove the folder");
    }
    if (std::none_of(state_.archived.begin(), state_.archived.end(), [&](const ClosedTab& closed) { return closed.tab.id == inFolder; })) {
        return done(L"the deleted folder's tab wasn't archived");
    }

    // A favorite's pane: its menu, the Mac's (core's FavoriteMenu), on a right-click and a Ctrl+click.
    EditState([&] { state_.ToggleFavorite(tab); });
    if (std::wstring problem = Draw(); !problem.empty()) return done(L"the sidebar couldn't draw: " + problem);
    std::optional<size_t> pane;
    size_t i = 0;
    for (const FavoriteTile& tile : sidebar_->Favorites().tiles) {
        for (const FavoritePane& p : tile.panes) {
            if (p.tabID == tab) pane = i;
            ++i;
        }
    }
    const std::optional<POINT> paneAt = pane ? sidebar_->FavoriteCentre(*pane) : std::nullopt;
    if (!paneAt) return done(L"the new favorite isn't in the grid");
    const size_t shown = lines.size();
    rightClick(*paneAt, "");
    controlClick(*paneAt, "");
    const std::string favoriteLine = SidebarMenuLine(FavoriteMenu(state_, tab));
    if (lines.size() != shown + 2 || lines[shown] != favoriteLine || lines[shown + 1] != favoriteLine) {
        return done(L"a right-click or Ctrl+click on a favorite didn't open its menu");
    }
    // Remove from Favorites puts it back in Today.
    rightClick(*paneAt, "Remove from Favorites");
    const auto unfavorited = state_.Location(tab);
    if (!unfavorited || unfavorited->section != TabSection::Unpinned) return done(L"the favorite menu's Remove from Favorites didn't remove it");
    return done({});
}

}  // namespace kite
