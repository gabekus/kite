// The + menu and Create a Space (core/SpaceCreation.h). The Mac tests what a space is for in
// AutomationTests (spaceListSaysWhatEachSpaceIsFor's Space.cleanAbout and its round trip, and the
// describe_space case's joined lines), ported case for case. BrowserStore's beginNewSpace,
// finishNewSpace and cancelNewSpace, the + menu (NewItemMenu.swift), the page's layout
// (SpaceCreationView.swift) and the theme editor's presets have no Mac tests: their cases here
// follow the Mac's code. Undo New Space (registerUndoStep) comes with W16.

#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "Check.h"
#include "core/Json.h"
#include "core/KeyBindings.h"
#include "core/Profiles.h"
#include "core/SpaceCreation.h"
#include "core/SpaceEditing.h"

using namespace kite;

namespace {

namespace M = space_creation_metrics;
namespace T = theme_swatches_metrics;

BrowserState ThreeSpaces() {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("A", "\xF0\x9F\x85\xB0\xEF\xB8\x8F", Theme::Presets()[0]);
    state.AddSpace("B", "\xF0\x9F\x85\xB1\xEF\xB8\x8F", Theme::Presets()[2]);
    state.AddSpace("C", "\xC2\xA9\xEF\xB8\x8F", Theme::Presets()[0]);
    state.SelectSpaceAt(1);
    return state;
}

std::vector<std::string> Names(const BrowserState& state) {
    std::vector<std::string> names;
    for (const Space& space : state.spaces) names.push_back(space.name);
    return names;
}

std::optional<BrowserState> RoundTrip(const BrowserState& state) {
    auto parsed = json::Parse(json::Write(Encode(state)));
    const json::Value* value = std::get_if<json::Value>(&parsed);
    return value ? DecodeBrowserState(*value) : std::nullopt;
}

bool Near(float a, float b) { return a - b < 0.001f && b - a < 0.001f; }

}  // namespace

// AutomationTests.spaceListSaysWhatEachSpaceIsFor (its Space.about part): a description round
// trips through the session, and nothing but whitespace is none.
TEST(spaceListSaysWhatEachSpaceIsFor) {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("Komado", "\xF0\x9F\xAA\x9F", Theme::Presets()[0]);
    SetSpaceAbout(state.spaces[0], std::string("Komado business"));
    const std::optional<BrowserState> decoded = RoundTrip(state);
    CHECK(decoded && SpaceAbout(decoded->spaces[0]) == std::optional<std::string>("Komado business"));
    CHECK(!CleanAbout("  \n "));
}

// AutomationTests' describe_space case: lines are joined with a space and the ends trimmed.
TEST(describeSpaceCleansItsAbout) {
    CHECK(CleanAbout("  Komado\nbusiness ") == std::optional<std::string>("Komado business"));
    CHECK(!CleanAbout(""));
}

// Edge cases of Space.cleanAbout the Mac doesn't test.
TEST(cleanAboutDropsEmptyLinesAndCountsCharacters) {
    // split(whereSeparator: \.isNewline) leaves out empty lines; CR LF is one newline.
    CHECK(CleanAbout("a\r\n\r\nb\n") == std::optional<std::string>("a b"));
    CHECK(CleanAbout("\n\tbakery\t\n") == std::optional<std::string>("bakery"));
    // A line of only spaces stays between its neighbours, as joined(separator:) keeps it.
    CHECK(CleanAbout("a\n  \nb") == std::optional<std::string>("a    b"));
    // U+2028 and U+0085 are newlines too; a no-break space is trimmed (it's in .whitespaces).
    CHECK(CleanAbout("x\xE2\x80\xA8y\xC2\x85z\xC2\xA0") == std::optional<std::string>("x y z"));
    // 500 characters: a family emoji (seven scalars) is one.
    std::string long_;
    for (int i = 0; i < 600; ++i) long_ += "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    const std::optional<std::string> cut = CleanAbout(long_);
    CHECK(cut && cut->size() == 500 * std::string("\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7").size());
}

// MARK: The + menu (NewItemMenu.swift)

TEST(theNewItemMenuHasTheMacsItemsInItsOrder) {
    const ShortcutMap table = ShortcutTable(KeyBindings{});
    const std::vector<NewItemMenuItem> items = NewItemMenu(table);
    CHECK(items.size() == 5);
    // New Split waits for split views (W36); its shortcut is the Mac's ⌘L, made Ctrl.
    CHECK(NewItemMenuLine(items) == "New Space | New Folder | --- | (New Split\tCtrl+L) | New Tab\tCtrl+T");
    CHECK(items[0].command == NewItemMenuItem::Command::NewSpace && items[0].shortcut.empty());
    CHECK(items[2].command == NewItemMenuItem::Command::Separator);
}

TEST(theNewItemMenuShowsNewTabsShortcutAsBound) {
    // A keybindings.json that moves New Tab: the menu shows the key that runs it, as a menu item's
    // key equivalent does.
    KeyBindings bindings;
    bindings.SetShortcut(KeyShortcut("n", {KeyShortcut::Modifier::Control, KeyShortcut::Modifier::Shift}), "newTab");
    const std::vector<NewItemMenuItem> items = NewItemMenu(ShortcutTable(bindings));
    CHECK(items[4].shortcut == "Ctrl+Shift+N");
    // New Space has no default key, and the + menu shows none for it whatever runs it.
    CHECK(items[0].shortcut.empty());
}

// MARK: Creating a space (BrowserStore's beginNewSpace, finishNewSpace, cancelNewSpace)

TEST(newSpaceOpensANamelessDraftRightAfterTheCurrentOne) {
    BrowserState state = ThreeSpaces();
    SetSpaceProfile(state.spaces[1], std::string("Profile 1"));
    state.spaces[1].theme.tint = 0.3f;
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    CHECK(creation && creation->spaceID == id && creation->returnTo == state.spaces[1].id && !creation->themeChosen);
    CHECK(state.spaces.size() == 4 && state.spaces[2].id == id && state.selectedSpaceID == id);
    // No name or icon yet; B's look and profile.
    CHECK(state.spaces[2].name.empty() && state.spaces[2].icon.empty());
    CHECK(state.spaces[2].theme == state.spaces[1].theme);
    CHECK(SpaceProfile(state.spaces[2]) == std::optional<std::string>("Profile 1"));
    CHECK(ShowsCreation(state, creation));
    // Another space selected: the page goes, the creation stays; New Space again goes back to it.
    state.SelectSpaceAt(0);
    CHECK(!ShowsCreation(state, creation) && creation);
    CHECK(BeginNewSpace(state, creation) == id);
    CHECK(state.spaces.size() == 4 && state.selectedSpaceID == id);
}

TEST(createSpaceNamesTheDraftAndSaysWhatItsFor) {
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    // Create Space is disabled for a blank name: nothing changes and the page stays.
    CHECK(!CanCreateSpace(" \t\n"));
    CHECK(!FinishNewSpace(state, creation, "  \n", "x"));
    CHECK(creation && state.spaces[2].name.empty());
    CHECK(CanCreateSpace(" R "));
    CHECK(FinishNewSpace(state, creation, "  Reading\n", " Books\nand papers "));
    CHECK(!creation);
    CHECK(Names(state) == (std::vector<std::string>{"A", "B", "Reading", "C"}));
    CHECK(state.selectedSpaceID == id);
    CHECK(SpaceAbout(state.spaces[2]) == std::optional<std::string>("Books and papers"));
    // A blank description leaves none.
    std::optional<SpaceCreation> second;
    BeginNewSpace(state, second);
    CHECK(FinishNewSpace(state, second, "Work", "   "));
    CHECK(!SpaceAbout(state.spaces[3]));
    // With nothing open, Create does nothing.
    const BrowserState before = state;
    CHECK(!FinishNewSpace(state, second, "More"));
    CHECK(state == before);
}

TEST(cancelDeletesTheDraftAndGoesBack) {
    BrowserState state = ThreeSpaces();
    const BrowserState before = state;
    std::optional<SpaceCreation> creation;
    BeginNewSpace(state, creation);
    CHECK(CancelNewSpace(state, creation));
    CHECK(!creation);
    CHECK(state == before);
    CHECK(!CancelNewSpace(state, creation));
    // Opened, then another space selected: Cancel still goes back to where it was opened.
    BeginNewSpace(state, creation);
    state.SelectSpaceAt(3);
    CHECK(CancelNewSpace(state, creation));
    CHECK(state.selectedSpaceID == before.spaces[1].id && state.spaces.size() == 3);
}

TEST(cancelWithTheSpaceToGoBackToGoneLeavesTheOneBefore) {
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    state.DeleteSpace(state.spaces[1].id);  // B, the one it came from
    CreationFollowsState(state, creation);
    CHECK(creation && creation->spaceID == id);
    state.SelectSpace(id);
    CHECK(CancelNewSpace(state, creation));
    // deleteSpace selects the one before the draft; selectSpace(B) finds nothing.
    CHECK(Names(state) == (std::vector<std::string>{"A", "C"}));
    CHECK(state.selectedSpaceID == state.spaces[0].id);
}

TEST(cancelLeavesTheOnlySpaceAndItsPage) {
    // The others deleted while the page was open: Delete Space refuses the last space, so Cancel
    // keeps the page (and the space) rather than leave a nameless space behind.
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    while (state.spaces.size() > 1) state.DeleteSpace(state.spaces[0].id == id ? state.spaces[1].id : state.spaces[0].id);
    const BrowserState before = state;
    CHECK(!CancelNewSpace(state, creation));
    CHECK(creation && state == before);
    CHECK(FinishNewSpace(state, creation, "Only"));
}

// BrowserStore's load and SessionStore.restoringSidebar: dropUnnamedEmptySpaces.
TEST(aDraftLeftAtQuitIsDroppedOnLoad) {
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string draft = BeginNewSpace(state, creation);
    // Saved with the page open, then read back at the next launch: the draft goes, and the one
    // before it (B) is selected, as Delete Space selects.
    std::optional<BrowserState> loaded = RoundTrip(state);
    CHECK(loaded.has_value());
    if (!loaded) return;
    CHECK(DropUnnamedEmptySpaces(*loaded));
    CHECK(Names(*loaded) == (std::vector<std::string>{"A", "B", "C"}));
    CHECK(loaded->selectedSpaceID == state.spaces[1].id && !loaded->SpaceIndex(draft));
    CHECK(!DropUnnamedEmptySpaces(*loaded));
    // A nameless space with a tab, or a pinned one, stays; so does a named empty one.
    BrowserState kept = ThreeSpaces();
    kept.spaces[0].name.clear();
    kept.OpenTab("https://example.com", kept.spaces[0].id, false);
    kept.spaces[2].name.clear();
    Tab pinned;
    pinned.id = "PINNED";
    pinned.url = "https://example.org";
    kept.spaces[2].pinnedItems.push_back(PinnedItem{pinned});
    CHECK(!DropUnnamedEmptySpaces(kept));
    // Every space nameless and empty: the last one stays (Delete Space refuses it).
    BrowserState all = ThreeSpaces();
    for (Space& space : all.spaces) space.name.clear();
    CHECK(DropUnnamedEmptySpaces(all));
    CHECK(all.spaces.size() == 1 && all.selectedSpaceID == all.spaces[0].id);
}

TEST(theDraftsMenuCantChangeItsIcon) {
    // Its header, where Change Space Icon…'s picker hangs, is under the page; the other spaces'
    // menus are as ever.
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string draft = BeginNewSpace(state, creation);
    const auto changeIcon = [](const std::vector<SpaceMenuItem>& items) {
        for (const SpaceMenuItem& item : items) {
            if (item.command == SpaceMenuItem::Command::ChangeIcon) return item.enabled;
        }
        return true;
    };
    CHECK(!changeIcon(SpaceMenu(state, draft, creation)));
    CHECK(changeIcon(SpaceMenu(state, state.spaces[0].id, creation)) == changeIcon(SpaceMenu(state, state.spaces[0].id)));
    CHECK(SpaceMenu(state, draft, std::nullopt) == SpaceMenu(state, draft));
}

TEST(aDraftDeletedElsewhereEndsTheCreation) {
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    state.DeleteSpace(id);
    CreationFollowsState(state, creation);
    CHECK(!creation);
    // New Space then opens a new draft.
    const std::string next = BeginNewSpace(state, creation);
    CHECK(next != id && creation && creation->spaceID == next);
}

TEST(aPresetSwatchKeepsTheIntensityAndMarksTheColourChosen) {
    BrowserState state = ThreeSpaces();
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    const size_t index = *state.SpaceIndex(id);
    state.spaces[index].theme.tint = 0.42f;
    CHECK(ChooseSpaceTheme(state, creation, id, 5));
    CHECK(state.spaces[index].theme.colors == Theme::Presets()[5].colors);
    CHECK(state.spaces[index].theme.grain == Theme::Presets()[5].grain);
    CHECK(state.spaces[index].theme.tint == 0.42f);
    CHECK(creation->themeChosen);
    CHECK(PresetOf(state.spaces[index].theme) == std::optional<size_t>(5));
    // Another space's swatch doesn't mark the creation's; no such preset changes nothing.
    std::optional<SpaceCreation> other = SpaceCreation{id, state.spaces[0].id, false};
    CHECK(ChooseSpaceTheme(state, other, state.spaces[0].id, 1));
    CHECK(!other->themeChosen);
    CHECK(!ChooseSpaceTheme(state, creation, id, Theme::Presets().size()));
    CHECK(!ChooseSpaceTheme(state, creation, "NOPE", 0));
    CHECK(!PresetOf(Theme::Make({ThemeColor::FromHex(0x123456)})));
}

TEST(newSpaceForAScriptRunsThePage) {
    BrowserState state = ThreeSpaces();
    const std::optional<std::string> id = NewSpace(state, " Komado ", "Komado\nbusiness", 3);
    CHECK(id.has_value());
    if (!id) return;
    const size_t index = *state.SpaceIndex(*id);
    CHECK(index == 2 && state.selectedSpaceID == *id && state.spaces[index].name == "Komado");
    CHECK(SpaceAbout(state.spaces[index]) == std::optional<std::string>("Komado business"));
    CHECK(PresetOf(state.spaces[index].theme) == std::optional<size_t>(3));
    // B's intensity, not the preset's.
    CHECK(state.spaces[index].theme.tint == state.spaces[1].theme.tint);
    const BrowserState before = state;
    CHECK(!NewSpace(state, "  ", "", std::nullopt));
    CHECK(!NewSpace(state, "X", "", Theme::Presets().size()));
    CHECK(state == before);
}

// MARK: The page's layout (SpaceCreationView, ArcMetrics.SpaceCreation)

TEST(thePageLaysOutAsArcs) {
    const SpaceCreationLayout l = LayOutSpaceCreation(240, 820);
    // Under the top row (7.5 + 32), the sidebar's padding in, down to the bar (820 - 50).
    CHECK(Near(l.page.top, 39.5f) && Near(l.page.left, 8) && Near(l.page.right, 232) && Near(l.page.bottom, 770));
    CHECK(Near(l.illustration.top, 86) && Near(l.illustration.bottom, 119));
    CHECK(Near(l.title.top, 140) && Near(l.subtitle.top, 171.5f));
    // The name field's top on Arc's y 237, then the rows 6pt apart and Choose a Theme 8pt down.
    CHECK(Near(l.name.top, 237) && Near(l.name.bottom, 273));
    CHECK(Near(l.about.top, 279) && Near(l.profile.top, 321) && Near(l.theme.top, 365));
    CHECK(Near(l.name.left, 14) && Near(l.name.right, 226));
    CHECK(Near(l.nameField.left, 48) && Near(l.nameField.right, 216));
    // Cancel 16.5pt over the bar, Create Space 14.5pt over Cancel.
    CHECK(Near(l.cancel.bottom, 753.5f) && Near(l.cancel.top, 738));
    CHECK(Near(l.create.bottom, 723.5f) && Near(l.create.top, 687.5f) && Near(l.create.left, 14) && Near(l.create.right, 226));
}

TEST(aShortWindowKeepsCreateUnderChooseATheme) {
    // The Spacer shrinks to nothing: Create Space follows Choose a Theme, Cancel follows it.
    const SpaceCreationLayout l = LayOutSpaceCreation(240, 420);
    CHECK(Near(l.create.top, l.theme.bottom));
    CHECK(Near(l.cancel.top, l.create.bottom + M::kCancelTop));
}

TEST(pressesLandOnThePagesParts) {
    const SpaceCreationLayout l = LayOutSpaceCreation(240, 820);
    using P = SpaceCreationPart;
    const BarRect pill{120, 327, 190, 351};
    CHECK(SpaceCreationPartAt(l, 100, 255, 44, pill) == P::NameField);
    CHECK(SpaceCreationPartAt(l, 100, 297, 44, pill) == P::AboutField);
    // The name row's icon isn't the field; neither is past its trailing padding.
    CHECK(SpaceCreationPartAt(l, 30, 255, 44, pill) == P::None);
    CHECK(SpaceCreationPartAt(l, 220, 255, 44, pill) == P::None);
    CHECK(SpaceCreationPartAt(l, 150, 339, 44, pill) == P::ProfilePill);
    CHECK(SpaceCreationPartAt(l, 60, 339, 44, pill) == P::None);
    CHECK(SpaceCreationPartAt(l, 20, 383, 44, pill) == P::ChooseTheme);
    CHECK(SpaceCreationPartAt(l, 20, 700, 44, pill) == P::Create);
    // Cancel is its text's width, centred.
    CHECK(SpaceCreationPartAt(l, 120, 745, 44, pill) == P::Cancel);
    CHECK(SpaceCreationPartAt(l, 30, 745, 44, pill) == P::None);
    CHECK(SpaceCreationPartAt(l, 120, 150, 44, pill) == P::None);
    CHECK(std::string(SpaceCreationPartName(P::ChooseTheme)) == "theme");
    // kitecore's estimates: the pill sits after "Profile", inside its row.
    const BarRect estimated = EstimatedPill(l);
    CHECK(estimated.left > l.profile.left + 48 && estimated.right < l.profile.right && Near((estimated.top + estimated.bottom) / 2, 339));
    CHECK(SpaceCreationPartAt(l, (estimated.left + estimated.right) / 2, 339, kEstimatedCancelWidth, estimated) == P::ProfilePill);
}

// MARK: Choose a Theme's swatches (ThemeEditor.presets, ArcMetrics.ThemeEditor)

TEST(theSwatchesSitInTheEditorsPresetRow) {
    const ThemeSwatchesLayout l = LayOutThemeSwatches(Theme::Presets().size());
    CHECK(l.swatches.size() == 7 && Near(l.width, 356) && Near(l.height, 48));
    CHECK(Near(l.swatches[0].left, 48) && Near(l.swatches[0].top, 12) && Near(l.swatches[0].Width(), 24));
    CHECK(Near(l.swatches[1].left - l.swatches[0].left, T::kSwatchPitch));
    CHECK(Near(l.previous.left, 8) && Near(l.next.right, 348));
    // A swatch's circle takes the press, not its frame's corner.
    CHECK(ThemeSwatchAt(l, 60, 24) == std::optional<size_t>(0));
    CHECK(ThemeSwatchAt(l, 48.5f, 12.5f) == std::nullopt);
    CHECK(ThemeSwatchAt(l, 48 + 6 * T::kSwatchPitch + 12, 24) == std::optional<size_t>(6));
    CHECK(ThemeSwatchAt(l, 330, 24) == std::nullopt);
    // Off the row's trailing edge, past NSPopover's 13pt arrow (the UI gate), level with the row.
    const SwatchesPlacement at = PlaceThemeSwatches(BarRect{14, 365, 226, 401}, l);
    CHECK(Near(at.left, 239) && Near(at.top, 359) && Near(at.arrowY, 24));
}
