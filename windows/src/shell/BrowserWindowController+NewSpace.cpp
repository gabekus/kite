// The window controller's + menu and Create a Space: the Mac's NewItemMenu (its items' actions),
// BrowserStore's beginNewSpace, finishNewSpace and cancelNewSpace, the page's keyboard
// (SpaceCreationView's onAppear and onExitCommand), ThemeEditor.present(pointing: true) for Choose
// a Theme, and ProfilePill's menu. See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include "core/OKLab.h"
#include "core/Profiles.h"

namespace kite {

void BrowserWindowController::ShowNewItemMenu(POINT screen) {
    // The menu takes the keyboard and the pointer until it closes, so a rename open ends first,
    // keeping what was typed, as for the space's menu.
    sidebar_->EndRenaming(true);
    const std::vector<NewItemMenuItem> items = NewItemMenu(shortcuts_);
    if (const std::optional<NewItemMenuItem::Command> chosen = showNewItemMenu_(items, screen)) RunNewItem(*chosen);
}

std::vector<ContextMenuEntry> BrowserWindowController::NewItemEntries(const std::vector<NewItemMenuItem>& items) {
    std::vector<ContextMenuEntry> entries;
    for (const NewItemMenuItem& item : items) {
        ContextMenuEntry entry;
        entry.separator = item.command == NewItemMenuItem::Command::Separator;
        entry.title = item.title;
        entry.shortcut = item.shortcut;
        entry.enabled = item.enabled;
        entries.push_back(std::move(entry));
    }
    return entries;
}

void BrowserWindowController::RunNewItem(NewItemMenuItem::Command command) {
    using Command = NewItemMenuItem::Command;
    switch (command) {
    case Command::NewSpace: BeginNewSpace(); break;
    // store.mutate { $0.createNewFolder() }: the Tabs menu's New Folder in the selected space.
    case Command::NewFolder: RunCommand("newFolder"); break;
    // store.showCommandBar(.newTab)
    case Command::NewTab: OpenCommandBar(CommandBarMode::NewTab); break;
    // Disabled until split views (W36).
    case Command::NewSplit:
    case Command::Separator: break;
    }
}

void BrowserWindowController::BeginNewSpace() {
    CloseThemeSwatches();
    // A page already open: its space again (the sidebar as it is, as the Mac's early return).
    if (!creation_ || !state_.SpaceIndex(creation_->spaceID)) SetSidebarShown(true);
    kite::BeginNewSpace(state_, creation_);
    // Its space is selected (and slides in): the page shows in the sidebar, and its name field
    // takes the keyboard as it appears (FollowCreation). It's saved soon, as the Mac's mutate is.
    SelectionMoved();
}

void BrowserWindowController::FinishNewSpace(const std::string& name, const std::string& about) {
    if (!kite::FinishNewSpace(state_, creation_, name, about)) return;
    // The page goes and the new space's own page shows; the keyboard goes back to the page.
    StateChanged();
}

void BrowserWindowController::CancelNewSpace() {
    if (!creation_) return;
    // A tab opened in it meanwhile (Ctrl+T) closes with it, as Delete Space closes a space's pages.
    std::vector<std::string> tabs;
    if (const auto index = state_.SpaceIndex(creation_->spaceID)) {
        for (const Tab* tab : state_.spaces[*index].AllTabs()) tabs.push_back(tab->id);
    }
    // The draft the only space left (the others deleted meanwhile): Delete Space refuses the last
    // space, so the page stays, as Delete Space beeps for it.
    if (!kite::CancelNewSpace(state_, creation_)) return static_cast<void>(MessageBeep(MB_OK));
    for (const std::string& tab : tabs) PageGone(tab);
    // The space it was opened from is selected again, and slides back in.
    SelectionMoved();
}

void BrowserWindowController::ShowThemeSwatches(const BarRect& row) {
    if (!swatches_ || !creation_) return;
    std::vector<ThemeColor> accents;
    for (const Theme& preset : Theme::Presets()) accents.push_back(Accent(preset));
    // The popover holds the keyboard while it's open (the Mac's popover is the key window), from
    // now: the page's field lets it go (remembered, for Escape to give back), the picker closes, and
    // a page can't take it meanwhile. Opened again (Choose a Theme pressed while it's open), it keeps
    // the field it remembered.
    if (!swatchesKeyboard_) swatchesReturn_ = sidebar_->Creation().KeyboardField();
    swatchesKeyboard_ = true;
    GiveKeyboard(KeyboardField::ThemeSwatches);
    // Open closes the popover before it (the Mac's present): the keyboard stays its throughout.
    openingSwatches_ = true;
    const std::wstring problem = swatches_->Open(row, window_.Dpi(), dark_.value_or(true), std::move(accents));
    openingSwatches_ = false;
    // A failure, or lost on the way (a GPU lost in its draw): nothing holds the keyboard.
    if (!problem.empty() || !swatches_->IsOpen()) {
        ReleaseSwatchesKeyboard(false);
        if (!problem.empty()) OutputDebugStringW((L"Kite: Choose a Theme couldn't open: " + problem + L"\n").c_str());
        if (swatches_->DeviceLost()) Draw();
        return;
    }
    UpdateFindHole();
    // Kite's window takes the focus when it's the one in front, so a press in the page (its own
    // window) moves it, and closes the popover.
    TakeFocusIfInFront();
}

void BrowserWindowController::PickSpaceTheme(size_t preset) {
    if (!creation_ || !ChooseSpaceTheme(state_, creation_, creation_->spaceID, preset)) return;
    // The backdrop crossfades to it (SyncSpace), the sidebar takes its appearance, and it's saved
    // soon. The popover stays open, in the new appearance.
    StateChanged();
    if (swatches_) swatches_->SetDark(dark_.value_or(true));
}

void BrowserWindowController::CloseThemeSwatches(bool handBack) {
    if (!swatches_ || !swatches_->IsOpen()) return;
    // Its closed callback lets the keyboard go, as this close says.
    swatchesHandBack_ = handBack;
    swatches_->Close();
    swatchesHandBack_ = false;
    if (compositor_) compositor_->Commit();
}

void BrowserWindowController::ReleaseSwatchesKeyboard(bool handBack) {
    if (!swatchesKeyboard_) return;
    swatchesKeyboard_ = false;
    const std::optional<SpaceCreationView::Field> back = std::exchange(swatchesReturn_, std::nullopt);
    // Another field taking the keyboard (GiveKeyboard) sets the page's hold itself as it ends.
    if (givingKeyboard_) return;
    // Escape: back to the page's field that had it, while the page still shows.
    if (handBack && back && sidebar_->CreationShown()) return TakeKeyboardForCreation(*back);
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    // Nothing of Kite's has it now: the page, only from the window in front (a close as the user
    // switches apps never brings Kite back), and never for a press, a deactivation or a move.
    if (handBack && chromium_ && KeyboardOwner() == KeyboardField::None) {
        ++pageFocusHandoffs_;
        if (!testFocus_ && GetForegroundWindow() == window_.Handle()) chromium_->Focus();
    }
#endif
}

void BrowserWindowController::TakeKeyboardForCreation(SpaceCreationView::Field field, bool selectAll) {
    // As TakeKeyboardForRename: the others' carets go first, then the field takes it, and only then
    // does the window take the focus (its onFocus must see the field's), the page holding none of
    // its own while a navigation lands (UpdateFindHole's KeepKeyboard).
    GiveKeyboard(KeyboardField::Creation, false);
    sidebar_->FocusCreation(field, selectAll);
    TakeFocusIfInFront();
    UpdateFindHole();
}

void BrowserWindowController::ShowCreationProfileMenu(POINT screen) {
    if (!creation_) return;
    // ProfilePill's Menu: every profile by name, the one picked set for the space being made.
    const std::vector<Profile> profiles = AllProfiles(state_);
    std::vector<ContextMenuEntry> entries;
    for (const Profile& profile : profiles) {
        ContextMenuEntry entry;
        entry.title = profile.name;
        entries.push_back(std::move(entry));
    }
    const std::optional<size_t> chosen = showProfileMenu_(entries, screen);
    if (!chosen || *chosen >= profiles.size() || !creation_) return;
    const Profile& profile = profiles[*chosen];
    SetProfile(state_, profile.IsDefault() ? std::nullopt : std::optional<std::string>(profile.directory), creation_->spaceID);
    StateChanged();
}

void BrowserWindowController::FollowCreation() {
    const std::optional<bool> shown = sidebar_->TakeCreationShownChange();
    if (!shown) return;
    // onAppear { nameFocused = true }: the other fields let the keyboard go first.
    if (*shown) return TakeKeyboardForCreation(SpaceCreationView::Field::Name);
    // The page went (created, cancelled, another space selected), its field's keyboard with it:
    // the popover goes, and the page takes the keyboard, as when the command bar closes.
    CloseThemeSwatches();
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    if (chromium_ && KeyboardOwner() == KeyboardField::None) {
        ++pageFocusHandoffs_;
        if (!testFocus_ && GetForegroundWindow() == window_.Handle()) chromium_->Focus();
    }
#endif
}

}  // namespace kite
