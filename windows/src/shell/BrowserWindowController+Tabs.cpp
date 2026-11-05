// The window controller's tab commands and edits: Pin Tab, New Folder, Duplicate Tab, Rename Current
// Tab…, Reset all tabs in this Space, Reset Tab to Original URL, Replace Pin with Current Page and
// Add to Favorites (the Tabs menu's and the command bar's ids, by shortcut here), renaming a tab or
// folder in its row, and a pinned tab's Back to Pinned URL. The Mac's
// BrowserWindowController+TabCommands.swift (newFolder, resetTab, backToPinnedURL,
// replacePinWithCurrentPage, resetAllTabsInSpace, duplicateTab, renameCurrentTab, renameTab,
// renameFolder), togglePin (BrowserWindowController.swift), toggleFavoriteTab
// (+SidebarDrag.swift) and BrowserStore's beginRenaming(tab:) and beginRenaming(folder:). See
// BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>

#include "core/Sidebar.h"

namespace kite {

void BrowserWindowController::RecordEdit(const std::function<void()>& change) {
    // W16 (undo) records the step here, the session before and after `change`, as the Mac's
    // BrowserStore.mutate registers one for every change.
    change();
}

void BrowserWindowController::EditState(const std::function<void()>& change, bool selectionMoved) {
    RecordEdit(change);
    // A sidebar change, saved soon (SelectionMoved's save is Soon too); StateChanged syncs the
    // pinned URLs, as the Mac's mutate does.
    if (selectionMoved) SelectionMoved();
    else StateChanged(SessionSaveDelay::Soon);
}

void BrowserWindowController::TakeKeyboardForRename() {
    // The one seam W21 fills: GiveKeyboard(KeyboardField::Rename) first, so the find field's caret
    // goes before the rename's. Then the keyboard, when Kite is the window in front (a quiet test run
    // never activates).
    if (GetForegroundWindow() == window_.Handle()) SetFocus(window_.Handle());
}

std::optional<bool> BrowserWindowController::TabCommandEnabled(const std::string& command) const {
    // validateMenuItem's cases for the tab commands; none when `command` isn't one of them.
    const Tab* tab = state_.SelectedTab();
    if (command == "pinTab" || command == "renameCurrentTab" || command == "toggleFavorite") return tab != nullptr;
    if (command == "resetTab") return tab && state_.CanReset(tab->id);
    // Offered once the pinned tab has left its pinned page, on a web page.
    if (command == "replacePinnedTab") return tab && tab->url && state_.CanReset(tab->id) && !InternalPageOf(tab->url);
    if (command == "resetSpace") {
        const auto pinned = state_.SelectedSpace().Pinned();
        return std::any_of(pinned.begin(), pinned.end(), [](const Tab* t) { return t->HasLeftPinnedURL(); });
    }
    return std::nullopt;
}

void BrowserWindowController::MakeTabCommands() {
    commands_["pinTab"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab) return;
        const std::string id = tab->id;
        EditState([&] { state_.TogglePin(id); });
    };
    // Tabs › New Folder… in the selected space. As on the Mac it doesn't open the folder's rename
    // (only the folder menu's New Nested Folder… does, W17).
    commands_["newFolder"] = [this] { EditState([&] { state_.CreateNewFolder(); }); };
    commands_["duplicate"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab) return static_cast<void>(MessageBeep(MB_OK));
        const std::string id = tab->id;
        EditState([&] { state_.Duplicate(id); }, true);
    };
    commands_["renameCurrentTab"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab) return static_cast<void>(MessageBeep(MB_OK));
        BeginRenamingTab(tab->id, false);
    };
    commands_["resetSpace"] = [this] { ResetAllTabsInSpace(); };
    commands_["resetTab"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab || !state_.CanReset(tab->id)) return static_cast<void>(MessageBeep(MB_OK));
        BackToPinnedURL(tab->id);
    };
    commands_["replacePinnedTab"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab) return static_cast<void>(MessageBeep(MB_OK));
        const std::string id = tab->id;
        bool replaced = false;
        EditState([&] { replaced = state_.ReplacePinnedURLWithCurrent(id); });
        if (!replaced) MessageBeep(MB_OK);
    };
    commands_["toggleFavorite"] = [this] {
        const Tab* tab = state_.SelectedTab();
        if (!tab) return;
        const std::string id = tab->id;
        EditState([&] { state_.ToggleFavorite(id); });
    };
}

void BrowserWindowController::BackToPinnedURL(const std::string& tabID) {
    std::optional<std::string> url;
    EditState([&] { url = state_.ResetTab(tabID); });
    // The Mac's load(_:in:): its page goes there (one that closed itself gets a new one).
    if (url) LoadInTab(tabID, *url);
}

void BrowserWindowController::ResetAllTabsInSpace() {
    std::vector<std::pair<std::string, std::string>> reset;
    EditState([&] { reset = state_.ResetPinnedTabs(); });
    if (reset.empty()) return static_cast<void>(MessageBeep(MB_OK));
    for (const auto& [id, url] : reset) LoadInTab(id, url);
}

void BrowserWindowController::BeginRenamingTab(const std::string& tabID, bool fromDoubleClick) {
    const auto location = state_.Location(tabID);
    if (!location) return;
    // Favorites and split panes have no title row to edit in. A double-click is on a row the Mac
    // wouldn't have (its split is one SplitRowCell, with no doubleTapped): nothing. From Rename
    // Current Tab… (or with the sidebar hidden) the Mac opens Rename Tab…, which comes with
    // ArcDialog (W19): a beep until then.
    const bool favoriteOrPane = location->section == TabSection::Favorite || state_.SplitContaining(tabID);
    if (fromDoubleClick && favoriteOrPane) return;
    const bool hasRow = !favoriteOrPane && SidebarShowsRow(state_, state_.SelectedSpaceIndex(), SidebarRow::Kind::Tab, tabID);
    if (!sidebarShown_ || !hasRow) return static_cast<void>(MessageBeep(MB_OK));
    TakeKeyboardForRename();
    sidebar_->BeginRenaming(SidebarView::RenameTarget{SidebarRow::Kind::Tab, tabID}, state_.TabAt(*location)->DisplayTitle());
}

void BrowserWindowController::BeginRenamingFolder(const std::string& folderID) {
    const Folder* folder = state_.FolderByID(folderID);
    if (!folder) return;
    const std::string name = folder->name;
    // beginRenaming(folder:): the sidebar shown first; the field in its row, which the selected
    // space's page has to show.
    SetSidebarShown(true);
    if (!SidebarShowsRow(state_, state_.SelectedSpaceIndex(), SidebarRow::Kind::Folder, folderID)) return;
    TakeKeyboardForRename();
    sidebar_->BeginRenaming(SidebarView::RenameTarget{SidebarRow::Kind::Folder, folderID}, name);
}

void BrowserWindowController::RenameTab(const std::string& tabID, const std::string& name) {
    if (!state_.Location(tabID)) return;
    EditState([&] { state_.RenameTab(tabID, name); });
}

void BrowserWindowController::RenameFolder(const std::string& folderID, const std::string& name) {
    if (!state_.FolderByID(folderID)) return;
    EditState([&] { state_.RenameFolder(folderID, name); });
}

bool BrowserWindowController::RenameStillShown(const SidebarView::RenameTarget& target) const {
    if (target.kind == SidebarRow::Kind::Header) return target.id == state_.selectedSpaceID;
    return SidebarShowsRow(state_, state_.SelectedSpaceIndex(), target.kind, target.id);
}

void BrowserWindowController::ApplyRename(const SidebarView::RenameTarget& target, const std::string& text) {
    // Inside StateChanged's update (no StateChanged of its own), but still a step W16 records.
    RecordEdit([&] {
        switch (target.kind) {
        case SidebarRow::Kind::Header: state_.RenameSpace(target.id, text); break;
        case SidebarRow::Kind::Tab: state_.RenameTab(target.id, text); break;
        case SidebarRow::Kind::Folder: state_.RenameFolder(target.id, text); break;
        default: break;
        }
    });
}

}  // namespace kite
