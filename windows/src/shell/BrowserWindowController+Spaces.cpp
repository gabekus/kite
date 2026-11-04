// The window controller's space editing: the space menu and what its items do, renaming in
// the header, Delete Space and a drop in the bar. The Mac's SpaceContextMenus.menu actions,
// BrowserStore.beginRenaming and BrowserWindowController+TabCommands.swift's renameSpace and
// deleteSpace. See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include "shell/SpaceMenu.h"

namespace kite {

void BrowserWindowController::ShowSpaceMenu(const std::string& spaceID, POINT screen) {
    const std::vector<SpaceMenuItem> items = SpaceMenu(state_, spaceID);
    if (items.empty()) return;
    // The menu takes the keyboard and the pointer until it closes; a rename open goes first,
    // as AppKit's menu tracking ends a field's editing.
    sidebar_->EndRenaming(true);
    const std::optional<SpaceMenuItem::Command> chosen = kite::ShowSpaceMenu(window_.Handle(), items, screen, dark_.value_or(true));
    if (chosen) RunSpaceMenuItem(spaceID, *chosen);
}

void BrowserWindowController::RunSpaceMenuItem(const std::string& spaceID, SpaceMenuItem::Command command) {
    using Command = SpaceMenuItem::Command;
    const auto index = state_.SpaceIndex(spaceID);
    if (!index) return;
    switch (command) {
    case Command::Rename: BeginRenaming(spaceID); break;
    case Command::NewFolder:
        state_.CreateFolder("New Folder", *index);
        StateChanged();
        break;
    case Command::Delete: DeleteSpace(spaceID); break;
    // Disabled on Windows until they're ported (SpaceMenu).
    case Command::ChangeIcon:
    case Command::Describe:
    case Command::EditTheme:
    case Command::SetProfile:
    case Command::LiveFolders:
    case Command::Separator: break;
    }
}

void BrowserWindowController::BeginRenaming(const std::string& spaceID) {
    const auto index = state_.SpaceIndex(spaceID);
    if (!index) return;
    // beginRenaming(space:): its space selected, then its header's field.
    if (state_.selectedSpaceID != spaceID) {
        state_.SelectSpace(spaceID);
        SelectionMoved();
    }
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    if (GetForegroundWindow() == window_.Handle()) SetFocus(window_.Handle());
    sidebar_->BeginRenaming(spaceID, state_.spaces[*index].name);
}

void BrowserWindowController::RenameSpace(const std::string& spaceID, const std::string& name) {
    const auto index = state_.SpaceIndex(spaceID);
    if (!index) return;
    const std::string before = state_.spaces[*index].name;
    state_.RenameSpace(spaceID, name);
    if (state_.spaces[*index].name != before) StateChanged();
}

void BrowserWindowController::DeleteSpace(std::string spaceID) {
    const SpaceDeletion deletion = DeletionOf(state_, spaceID);
    switch (deletion.kind) {
    case SpaceDeletion::Kind::Refused: MessageBeep(MB_OK); return;
    case SpaceDeletion::Kind::Ask:
        // Never a dialog in a test run.
        if (options_.smokeTest || options_.capture || !AskToDeleteSpace(window_.Handle(), deletion)) return;
        break;
    case SpaceDeletion::Kind::Now: break;
    }
    const auto index = state_.SpaceIndex(spaceID);
    if (!index) return;  // gone while the question was up
    std::vector<std::string> tabs;
    for (const Tab* tab : state_.spaces[*index].AllTabs()) tabs.push_back(tab->id);
    const bool shown = state_.selectedSpaceID == spaceID;
    state_.DeleteSpace(spaceID);
    // Its pages go with it; the space before it shows, if it was this one.
    if (shown) ShowPage();
    for (const std::string& tab : tabs) PageGone(tab);
    StateChanged();
}

void BrowserWindowController::MoveSpace(const std::string& spaceID, size_t index) {
    // The completion's `spaceIndex(moving.id) != slot` check: a drop where it was moves nothing.
    if (state_.SpaceIndex(spaceID) == index) return;
    state_.MoveSpace(spaceID, index);
    StateChanged();
}

}  // namespace kite
