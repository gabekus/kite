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
    // Create a Space's own space can't change its icon there (core/SpaceCreation.h).
    return SpaceMenu(state_, spaceID, creation_);
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
    // The space Create a Space is making has no header to rename in (the page is over it; the
    // Mac's renames a header no one sees): its page's name field, its text all selected.
    if (creation_ && creation_->spaceID == spaceID) {
        SetSidebarShown(true);
        if (state_.selectedSpaceID != spaceID) {
            state_.SelectSpace(spaceID);
            SelectionMoved();
        }
        TakeKeyboardForCreation(SpaceCreationView::Field::Name, true);
        return;
    }
    // beginRenaming(space:): the sidebar shown, its space selected, then its header's field.
    SetSidebarShown(true);
    if (state_.selectedSpaceID != spaceID) {
        state_.SelectSpace(spaceID);
        SelectionMoved();
    }
    const std::string name = state_.spaces[*index].name;
    TakeKeyboardForRename([&] { sidebar_->BeginRenaming(spaceID, name); });
}

void BrowserWindowController::RenameSpace(const std::string& spaceID, const std::string& name) {
    const auto index = state_.SpaceIndex(spaceID);
    if (!index) return;
    const std::string before = state_.spaces[*index].name;
    RecordEdit([&] { state_.RenameSpace(spaceID, name); });
    if (state_.spaces[*index].name != before) StateChanged();
}

void BrowserWindowController::DeleteSpace(std::string spaceID) {
    // The space Create a Space is making goes as Cancel does (the Mac's deleteSpace).
    if (creation_ && creation_->spaceID == spaceID) return CancelNewSpace();
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
    // Not for the space Create a Space is making: its header is under the page.
    if (!state_.SpaceIndex(spaceID) || (creation_ && creation_->spaceID == spaceID)) return;
    KillTimer(window_.Handle(), kIconPickerTimer);
    pendingIconPicker_.reset();
    // The popover's Search takes the keyboard, from now (before the window's focus, whose onFocus
    // would otherwise hand it to the page): a rename ends, keeping what was typed, the find field
    // lets it go, and a page can't take it back.
    iconPickerKeyboard_ = true;
    GiveKeyboard(KeyboardField::IconPicker);
    // The header holds its icon's slot from the request on (the Mac's pickerOpen, set as
    // openPicker is asked), before the selection closes any picker open for another space.
    sidebar_->SetIconPickerSpace(spaceID);
    // requestIconPicker: the sidebar shown, and its space selected. A picker open for another
    // space closes with the selection, keeping the keyboard for this one.
    givingKeyboard_ = true;
    if (!sidebarShown_) SetSidebarShown(true);
    if (state_.selectedSpaceID != spaceID) {
        state_.SelectSpace(spaceID);
        SelectionMoved();
    }
    givingKeyboard_ = false;
    iconPickerKeyboard_ = true;
    UpdateFindHole();
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    TakeFocusIfInFront();
    if (!fromMenu) return ShowIconPicker(spaceID);
    // From the menu, once it's gone (openPicker(after: 0.15)).
    pendingIconPicker_ = spaceID;
    SetTimer(window_.Handle(), kIconPickerTimer, 150, nullptr);
}

void BrowserWindowController::ShowIconPicker(const std::string& spaceID) {
    const auto index = state_.SpaceIndex(spaceID);
    std::optional<IconPickerState> picker = kite::OpenIconPicker(state_, spaceID);
    if (!index || !picker || !iconPicker_) {
        if (!(iconPicker_ && iconPicker_->IsOpen())) ReleaseIconPickerKeyboard();
        return;
    }
    sidebar_->HideTip();
    // Where the header's icon slot is (the same for an icon-less space's placeholder).
    const std::optional<D2D1_RECT_F> anchor = sidebar_->HeaderIconRect(spaceID);
    if (!anchor) {
        if (!iconPicker_->IsOpen()) {
            sidebar_->SetIconPickerSpace(std::nullopt);
            ReleaseIconPickerKeyboard();
        }
        return;
    }
    // Open closes the picker before it (a reopen from its button, or the menu's for another space):
    // the keyboard stays the picker's throughout, never released in between.
    openingIconPicker_ = true;
    const std::wstring problem = iconPicker_->Open(std::move(*picker), state_.spaces[*index].icon,
                                                   PickerRect{anchor->left, anchor->top, anchor->right, anchor->bottom}, window_.Dpi(),
                                                   PopoverDark());
    openingIconPicker_ = false;
    // Lost on the way (a GPU lost in Open's own redraw rebuilds everything, which closes it) is a
    // failure too: no picker, so nothing to hold the keyboard or the header's slot.
    if (!problem.empty() || !iconPicker_->IsOpen()) {
        sidebar_->SetIconPickerSpace(std::nullopt);
        ReleaseIconPickerKeyboard();
        if (!problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't open: " + problem + L"\n").c_str());
        if (iconPicker_->DeviceLost()) Draw();
        return;
    }
    // The header keeps its icon's slot while it's open (a dashed square for none): set after the
    // open, whose closing of the picker before it clears the old one's.
    sidebar_->SetIconPickerSpace(spaceID);
    // And the keyboard is its (the old one's close let it go).
    iconPickerKeyboard_ = true;
    UpdateFindHole();
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

void BrowserWindowController::CloseIconPicker(bool focusPage) {
    KillTimer(window_.Handle(), kIconPickerTimer);
    // A request still waiting on its 0.15 s takes its placeholder with it.
    if (const std::optional<std::string> pending = std::exchange(pendingIconPicker_, std::nullopt);
        pending && sidebar_->IconPickerSpace() == pending && !(iconPicker_ && iconPicker_->IsOpen())) {
        sidebar_->SetIconPickerSpace(std::nullopt);
    }
    if (iconPicker_ && iconPicker_->IsOpen()) {
        // Its closed callback lets the keyboard go, as this close says.
        releaseFocusesPage_ = focusPage;
        iconPicker_->Close();
        releaseFocusesPage_ = true;
    } else {
        ReleaseIconPickerKeyboard(focusPage);
    }
}

void BrowserWindowController::ReleaseIconPickerKeyboard(bool focusPage) {
    if (!iconPickerKeyboard_) return;
    iconPickerKeyboard_ = false;
    ++pickerKeyboardReleases_;
    // Another field taking the keyboard (GiveKeyboard) sets the page's KeepKeyboard itself as it
    // ends: not undone here half way (Ctrl+F's "first").
    if (givingKeyboard_) return;
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    // Nothing of Kite's has it now: the page, as onFocus would give it, only from the window in
    // front (as HideFindBar and Chromium's Show do), so a close as the user switches apps never
    // brings Kite back. Counted for the smoke test, which is never in front.
    if (focusPage && chromium_ && KeyboardOwner() == KeyboardField::None) {
        ++pageFocusHandoffs_;
        if (!testFocus_ && GetForegroundWindow() == window_.Handle()) chromium_->Focus();
    }
#else
    (void)focusPage;
#endif
}

}  // namespace kite
