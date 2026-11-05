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
    // As the Mac's present: one open already closes first. Kite's window takes the keyboard when it's
    // the one in front, so a press in the page (its own window) moves the focus and closes the
    // popover, as a press anywhere else closes a transient one.
    swatches_->Close();
    if (GetForegroundWindow() == window_.Handle() && GetFocus() != window_.Handle()) SetFocus(window_.Handle());
    if (std::wstring problem = swatches_->Open(row, window_.Dpi(), dark_.value_or(true), std::move(accents)); !problem.empty()) {
        OutputDebugStringW((L"Kite: Choose a Theme couldn't open: " + problem + L"\n").c_str());
        if (swatches_->DeviceLost()) Draw();
    }
}

void BrowserWindowController::PickSpaceTheme(size_t preset) {
    if (!creation_ || !ChooseSpaceTheme(state_, creation_, creation_->spaceID, preset)) return;
    // The backdrop crossfades to it (SyncSpace), the sidebar takes its appearance, and it's saved
    // soon. The popover stays open, in the new appearance.
    StateChanged();
    if (swatches_) swatches_->SetDark(dark_.value_or(true));
}

void BrowserWindowController::CloseThemeSwatches() {
    if (!swatches_ || !swatches_->IsOpen()) return;
    swatches_->Close();
    if (compositor_) compositor_->Commit();
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
    if (*shown) return GiveKeyboard(KeyboardField::Creation);
    // The page went (created, cancelled, another space selected), its field's keyboard with it:
    // the popover goes, and the page takes the keyboard, as when the command bar closes.
    CloseThemeSwatches();
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    if (chromium_ && KeyboardOwner() == KeyboardField::None && GetForegroundWindow() == window_.Handle()) chromium_->Focus();
#endif
}

}  // namespace kite
