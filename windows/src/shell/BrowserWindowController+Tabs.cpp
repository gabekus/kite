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

void BrowserWindowController::EditState(const std::function<void()>& change, bool selectionMoved) {
    // W16 (undo) records the step here, before and after `change`, as the Mac's BrowserStore.mutate
    // registers one for every change; StateChanged syncs the pinned URLs as mutate does.
    change();
    if (selectionMoved) SelectionMoved();
    else StateChanged();
}

void BrowserWindowController::LoadInLivePage(const std::string& tabID, const std::string& url) {
#ifdef KITE_HAS_CEF
    // The Mac's load(_:in:): only a page that's there (and never one of Kite's own); an unloaded
    // tab picks the address up when it's next shown.
    if (chromium_ && !url.starts_with("kite:")) chromium_->Navigate(tabID, url);
#else
    (void)tabID;
    (void)url;
#endif
}

bool BrowserWindowController::TabCommandEnabled(const std::string& command, bool& enabled) const {
    // validateMenuItem's cases for the tab commands; false when `command` isn't one of them.
    const Tab* tab = state_.SelectedTab();
    if (command == "pinTab" || command == "renameCurrentTab" || command == "toggleFavorite") {
        enabled = tab != nullptr;
    } else if (command == "resetTab") {
        enabled = tab && state_.CanReset(tab->id);
    } else if (command == "replacePinnedTab") {
        // Offered once the pinned tab has left its pinned page, on a web page.
        enabled = tab && tab->url && state_.CanReset(tab->id) && !InternalPageOf(tab->url);
    } else if (command == "resetSpace") {
        const auto pinned = state_.SelectedSpace().Pinned();
        enabled = std::any_of(pinned.begin(), pinned.end(), [](const Tab* t) { return t->HasLeftPinnedURL(); });
    } else {
        return false;
    }
    return true;
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
        BeginRenamingTab(tab->id);
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
    if (url) LoadInLivePage(tabID, *url);
}

void BrowserWindowController::ResetAllTabsInSpace() {
    std::vector<std::pair<std::string, std::string>> reset;
    EditState([&] { reset = state_.ResetPinnedTabs(); });
    if (reset.empty()) return static_cast<void>(MessageBeep(MB_OK));
    for (const auto& [id, url] : reset) LoadInLivePage(id, url);
}

void BrowserWindowController::BeginRenamingTab(const std::string& tabID) {
    const auto location = state_.Location(tabID);
    if (!location) return;
    // Favorites and split panes have no title row to edit in (nor a tab another space lists, or
    // one inside a closed folder). The Mac's Rename Tab… dialog for those, and for a hidden sidebar,
    // comes with ArcDialog (W19): a beep until then.
    const bool hasRow = location->section != TabSection::Favorite && !state_.SplitContaining(tabID) &&
                        SidebarShowsRow(state_, state_.SelectedSpaceIndex(), SidebarRow::Kind::Tab, tabID);
    if (!sidebarShown_ || !hasRow) return static_cast<void>(MessageBeep(MB_OK));
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    if (GetForegroundWindow() == window_.Handle()) SetFocus(window_.Handle());
    sidebar_->BeginRenaming(SidebarView::RenameTarget{SidebarRow::Kind::Tab, tabID}, state_.TabAt(*location)->DisplayTitle());
}

void BrowserWindowController::BeginRenamingFolder(const std::string& folderID) {
    const auto found = state_.FolderMatching(folderID);
    if (!found || found->folder->id != folderID) return;
    const std::string name = found->folder->name;
    // beginRenaming(folder:): the sidebar shown first; the field in its row, which the selected
    // space's page has to show.
    SetSidebarShown(true);
    if (!SidebarShowsRow(state_, state_.SelectedSpaceIndex(), SidebarRow::Kind::Folder, folderID)) return;
    if (GetForegroundWindow() == window_.Handle()) SetFocus(window_.Handle());
    sidebar_->BeginRenaming(SidebarView::RenameTarget{SidebarRow::Kind::Folder, folderID}, name);
}

void BrowserWindowController::RenameTab(const std::string& tabID, const std::string& name) {
    const Tab* tab = state_.FindTabByID(tabID);
    if (!tab) return;
    const std::optional<std::string> before = tab->customTitle;
    state_.RenameTab(tabID, name);
    // A field committed unchanged redraws nothing (its row draws again as the field goes).
    if (state_.FindTabByID(tabID)->customTitle != before) EditState([] {});
}

void BrowserWindowController::RenameFolder(const std::string& folderID, const std::string& name) {
    const auto found = state_.FolderMatching(folderID);
    if (!found || found->folder->id != folderID) return;
    const std::string before = found->folder->name;
    state_.RenameFolder(folderID, name);
    if (state_.FolderMatching(folderID)->folder->name != before) EditState([] {});
}

bool BrowserWindowController::RenameStillShown(const SidebarView::RenameTarget& target) const {
    if (target.kind == SidebarRow::Kind::Header) return target.id == state_.selectedSpaceID;
    return SidebarShowsRow(state_, state_.SelectedSpaceIndex(), target.kind, target.id);
}

void BrowserWindowController::ApplyRename(const SidebarView::RenameTarget& target, const std::string& text) {
    switch (target.kind) {
    case SidebarRow::Kind::Header: state_.RenameSpace(target.id, text); break;
    case SidebarRow::Kind::Tab: state_.RenameTab(target.id, text); break;
    case SidebarRow::Kind::Folder: state_.RenameFolder(target.id, text); break;
    default: break;
    }
}

}  // namespace kite
