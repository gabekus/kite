// The window controller's space editing: the space menu and what its items do, renaming in
// the header, Delete Space and a drop in the bar. The Mac's SpaceContextMenus.menu actions,
// BrowserStore.beginRenaming and BrowserWindowController+TabCommands.swift's renameSpace and
// deleteSpace. See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <filesystem>
#include <system_error>
#include <utility>

#include "core/SpaceIconPicker.h"
#include "shell/SpaceMenu.h"

namespace kite {

std::vector<SpaceMenuItem> BrowserWindowController::OpenSpaceMenu(const std::string& spaceID) {
    // The menu takes the keyboard and the pointer until it closes, so a rename open ends first,
    // keeping what was typed, as any other way of leaving the field does (Kite's choice: the Mac
    // doesn't say, and its field may keep editing under a context menu).
    sidebar_->EndRenaming(true);
    return SpaceMenu(state_, spaceID);
}

void BrowserWindowController::ShowSpaceMenu(const std::string& spaceID, POINT screen) {
    const std::vector<SpaceMenuItem> items = OpenSpaceMenu(spaceID);
    if (items.empty()) return;
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
        state_.CreateNewFolder(*index);
        StateChanged();
        break;
    case Command::Delete: DeleteSpace(spaceID); break;
    case Command::ChangeIcon: RequestIconPicker(spaceID, true); break;
    // Disabled on Windows until they're ported (SpaceMenu).
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
        if (!askToDelete_(deletion)) return;
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

// MARK: Change Space Icon… (SpaceIconPicker.swift, BrowserStore.requestIconPicker)

void BrowserWindowController::RequestIconPicker(const std::string& spaceID, bool fromMenu) {
    if (!state_.SpaceIndex(spaceID)) return;
    // The popover takes the keyboard: a rename ends, keeping what was typed.
    sidebar_->EndRenaming(true);
    KillTimer(window_.Handle(), kIconPickerTimer);
    pendingIconPicker_.reset();
    // The header holds its icon's slot from the request on (the Mac's pickerOpen, set as
    // openPicker is asked), before the selection closes any picker open for another space.
    sidebar_->SetIconPickerSpace(spaceID);
    // requestIconPicker: its space selected (the sidebar is always shown on Windows yet).
    if (state_.selectedSpaceID != spaceID) {
        state_.SelectSpace(spaceID);
        SelectionMoved();
    }
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    if (GetForegroundWindow() == window_.Handle()) SetFocus(window_.Handle());
    if (!fromMenu) return ShowIconPicker(spaceID);
    // From the menu, once it's gone (openPicker(after: 0.15)).
    pendingIconPicker_ = spaceID;
    SetTimer(window_.Handle(), kIconPickerTimer, 150, nullptr);
}

void BrowserWindowController::ShowIconPicker(const std::string& spaceID) {
    const auto index = state_.SpaceIndex(spaceID);
    std::optional<IconPickerState> picker = kite::OpenIconPicker(state_, spaceID);
    if (!index || !picker || !iconPicker_) return;
    sidebar_->HideTip();
    // Where the header's icon slot is (the same for an icon-less space's placeholder).
    const std::optional<D2D1_RECT_F> anchor = sidebar_->HeaderIconRect(spaceID);
    if (!anchor) {
        if (!iconPicker_->IsOpen()) sidebar_->SetIconPickerSpace(std::nullopt);
        return;
    }
    if (std::wstring problem = iconPicker_->Open(std::move(*picker), state_.spaces[*index].icon,
                                                 PickerRect{anchor->left, anchor->top, anchor->right, anchor->bottom}, window_.Dpi(),
                                                 dark_.value_or(true));
        !problem.empty()) {
        sidebar_->SetIconPickerSpace(std::nullopt);
        OutputDebugStringW((L"Kite: the icon picker couldn't open: " + problem + L"\n").c_str());
        if (iconPicker_->DeviceLost()) Draw();
        return;
    }
    // The header keeps its icon's slot while it's open (a dashed square for none): set after the
    // open, whose closing of the picker before it clears the old one's.
    sidebar_->SetIconPickerSpace(spaceID);
}

void BrowserWindowController::PickIcon(const std::string& spaceID, const std::string& icon) {
    const std::optional<IconPick> pick = PickSpaceIcon(state_, spaceID, icon);
    if (!pick) return;
    // SpaceIconImages.discard: the picture it replaced, once no space shows it. On the UI thread,
    // as the Mac's is: an exception to docs/windows-architecture.md's no-file-I/O rule, as it's
    // one DeleteFile of a name core checked (a directory entry, no data read or written), and
    // only for a picture icon, which a Windows Kite can't make yet (a Mac profile's can).
    if (pick->discard && !options_.spaceIcons.empty()) {
        std::error_code ignored;
        std::filesystem::remove(options_.spaceIcons / std::filesystem::path(std::u8string(pick->discard->begin(), pick->discard->end())), ignored);
    }
    // The bar's cell and the header show it at once, and it's saved.
    StateChanged();
    if (iconPicker_) iconPicker_->SpaceChanged(pick->icon);
}

void BrowserWindowController::CloseIconPicker() {
    KillTimer(window_.Handle(), kIconPickerTimer);
    // A request still waiting on its 0.15 s takes its placeholder with it.
    if (const std::optional<std::string> pending = std::exchange(pendingIconPicker_, std::nullopt);
        pending && sidebar_->IconPickerSpace() == pending && !(iconPicker_ && iconPicker_->IsOpen())) {
        sidebar_->SetIconPickerSpace(std::nullopt);
    }
    if (iconPicker_) iconPicker_->Close();
}

}  // namespace kite
