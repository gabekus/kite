// Editing spaces (core/SpaceEditing.h, BrowserState's space edits, and the bar's drag in
// core/SpaceBar.h): the Mac's SpaceEditingTests (SpacesTests.swift) and the SpaceReorderTests case
// W9b left for moveSpace, case for case where Windows has what they test, then the space menu,
// Delete Space, New Space and SpaceBarView's drag, which the Mac tests only by hand.
//
// Not ported: folderLookupsAfterDeletingTheLastSpaceDontTrap and aLinkRouteToADeletedSpaceFallsBack
// (Windows has no live folders, Air Traffic Control or space(matching:) yet), and
// anImageIconIsAFileNameInTheIconsFolder's iconText and labelWithIcon (no menu shows a space's
// label yet); its icon checks are here.

#include <optional>
#include <variant>
#include <string>
#include <vector>

#include "Check.h"
#include "core/Json.h"
#include "core/SpaceBar.h"
#include "core/SpaceEditing.h"
#include "core/SpaceIcon.h"

using namespace kite;

namespace {

namespace M = space_bar_metrics;

// SpaceEditingTests.makeState: A 🅰️, B 🅱️ and C ©️.
BrowserState ThreeSpaces() {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("A", "\xF0\x9F\x85\xB0\xEF\xB8\x8F", Theme::Presets()[0]);
    state.AddSpace("B", "\xF0\x9F\x85\xB1\xEF\xB8\x8F", Theme::Presets()[0]);
    state.AddSpace("C", "\xC2\xA9\xEF\xB8\x8F", Theme::Presets()[0]);
    state.SelectSpaceAt(0);
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

std::vector<std::string> Ids(const BrowserState& state) {
    std::vector<std::string> ids;
    for (const Space& space : state.spaces) ids.push_back(space.id);
    return ids;
}

}  // namespace

// SpaceEditingTests.

TEST(deletingTheSelectedSpaceSelectsTheOneBefore) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(2);
    state.DeleteSpace(state.spaces[2].id);
    CHECK(Names(state) == (std::vector<std::string>{"A", "B"}));
    CHECK(state.SelectedSpace().name == "B");
}

TEST(theLastSpaceStays) {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("A", "a", Theme::Presets()[0]);
    state.DeleteSpace(state.spaces[0].id);
    CHECK(state.spaces.size() == 1);
}

TEST(deletingAnotherSpaceKeepsTheSelection) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(2);
    state.DeleteSpace(state.spaces[0].id);
    CHECK(state.SelectedSpace().name == "C");
}

TEST(deletingTheFirstSpaceWhileSelectedSelectsTheNextOne) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(0);
    state.DeleteSpace(state.spaces[0].id);
    CHECK(Names(state) == (std::vector<std::string>{"B", "C"}));
    CHECK(state.SelectedSpace().name == "B");
}

TEST(deletingTheLastSpaceInTheListWhileSelected) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(2);
    const std::string id = state.spaces[2].id;
    state.DeleteSpace(id);
    CHECK(!state.SpaceIndex(id));
    CHECK(state.SelectedSpaceIndex() == 1);
    state.SelectSpaceAt(0);
    CHECK(state.SelectedSpace().name == "A");
}

TEST(aSpaceWithAnImageIconDeletes) {
    BrowserState state = ThreeSpaces();
    const std::string id = state.spaces[1].id;
    state.SetSpaceIcon(id, "image:3F2A.png");
    state.DeleteSpace(id);
    CHECK(Names(state) == (std::vector<std::string>{"A", "C"}));
}

TEST(aDeletedSpaceStaysGoneAfterSavingAndLoading) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(1);
    state.DeleteSpace(state.spaces[1].id);
    const auto loaded = RoundTrip(state);
    CHECK(loaded.has_value());
    if (!loaded) return;
    CHECK(Names(*loaded) == (std::vector<std::string>{"A", "C"}));
    CHECK(loaded->SelectedSpace().name == "A");
}

TEST(anIconIsOneCharacter) {
    BrowserState state = ThreeSpaces();
    const std::string id = state.spaces[0].id;
    state.SetSpaceIcon(id, " \xF0\x9F\x9A\x80\xF0\x9F\x8C\x99 ");  // " 🚀🌙 "
    CHECK(state.spaces[0].icon == "\xF0\x9F\x9A\x80");
    state.SetSpaceIcon(id, "symbol:star.fill");
    CHECK(state.spaces[0].icon == "symbol:star.fill");
    // Arc's icon picker can remove the icon, leaving a dot.
    state.SetSpaceIcon(id, "  ");
    CHECK(state.spaces[0].icon.empty());
}

TEST(anImageIconIsAFileNameInTheIconsFolder) {
    BrowserState state = ThreeSpaces();
    const std::string id = state.spaces[0].id;
    state.SetSpaceIcon(id, "image:3F2A.png");
    CHECK(state.spaces[0].icon == "image:3F2A.png");
    const SpaceIconLook look = SpaceIconLookOf(state.spaces[0].icon, state.spaces[0].theme);
    CHECK(look.kind == SpaceIconLook::Kind::Picture && look.text == "3F2A.png");
    // A path is refused and leaves the icon as it was.
    for (const char* bad : {"image:../../etc/passwd", "image:a/b.png", "image:.hidden", "image:"}) {
        state.SetSpaceIcon(id, bad);
        CHECK(state.spaces[0].icon == "image:3F2A.png");
    }
    state.SetSpaceIcon(id, "\xF0\x9F\x9A\x80");
    CHECK(SpaceIconLookOf(state.spaces[0].icon, state.spaces[0].theme).kind == SpaceIconLook::Kind::Emoji);
}

TEST(aNewSpaceGoesRightAfterTheCurrentOne) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(0);
    const std::string id = state.InsertSpace("", "", Theme::Presets()[0]);
    CHECK(Names(state) == (std::vector<std::string>{"A", "", "B", "C"}));
    CHECK(state.selectedSpaceID == id);
}

TEST(movingASpace) {
    BrowserState state = ThreeSpaces();
    state.MoveSpace(state.spaces[0].id, 2);
    CHECK(Names(state) == (std::vector<std::string>{"B", "C", "A"}));
}

// KiteCoreTests.renameIgnoresBlankNames.
TEST(renameIgnoresBlankNames) {
    BrowserState state = ThreeSpaces();
    const std::string id = state.spaces[0].id;
    state.RenameSpace(id, "  Work ");
    CHECK(state.spaces[0].name == "Work");
    state.RenameSpace(id, "   ");
    CHECK(state.spaces[0].name == "Work");
}

// SpaceReorderTests.dropMovesTheSpaceKeepingTheCurrentOne (W9b's last case).
TEST(dropMovesTheSpaceKeepingTheCurrentOne) {
    BrowserState state = ThreeSpaces();
    const std::vector<std::string> ids = Ids(state);
    state.SelectSpace(ids[0]);
    // The drop's slot index is its place among the other spaces.
    state.MoveSpace(ids[0], 2);
    CHECK(Ids(state) == (std::vector<std::string>{ids[1], ids[2], ids[0]}));
    CHECK(state.selectedSpaceID == ids[0]);
}

// Edge cases the Mac doesn't test.

TEST(editingASpaceThatIsntThereDoesNothing) {
    BrowserState state = ThreeSpaces();
    const BrowserState before = state;
    state.RenameSpace("NOPE", "X");
    state.SetSpaceIcon("NOPE", "\xF0\x9F\x9A\x80");
    state.DeleteSpace("NOPE");
    state.MoveSpace("NOPE", 0);
    CHECK(state == before);
    CHECK(state.CreateFolder("New Folder", 9).empty());
    CHECK(state == before);
}

TEST(aRenameKeepsInnerSpacesAndTrimsUnicodeWhitespace) {
    BrowserState state = ThreeSpaces();
    // A no-break space and an ideographic space around it go; the one inside stays.
    state.RenameSpace(state.spaces[1].id, "\xC2\xA0Side  project\xE3\x80\x80");
    CHECK(state.spaces[1].name == "Side  project");
}

TEST(anIconKeepsAWholeCharacter) {
    BrowserState state = ThreeSpaces();
    const std::string id = state.spaces[0].id;
    // A family (four people joined by ZWJs) and a flag are one Character each.
    const std::string family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6";
    state.SetSpaceIcon(id, family + "x");
    CHECK(state.spaces[0].icon == family);
    state.SetSpaceIcon(id, "\xF0\x9F\x87\xAF\xF0\x9F\x87\xB5\xF0\x9F\x87\xAB\xF0\x9F\x87\xB7");  // 🇯🇵🇫🇷
    CHECK(state.spaces[0].icon == "\xF0\x9F\x87\xAF\xF0\x9F\x87\xB5");
    state.SetSpaceIcon(id, "abc");
    CHECK(state.spaces[0].icon == "a");
}

TEST(movingPastTheEndGoesLastAndInPlaceStays) {
    BrowserState state = ThreeSpaces();
    const std::vector<std::string> ids = Ids(state);
    state.MoveSpace(ids[0], 99);
    CHECK(Ids(state) == (std::vector<std::string>{ids[1], ids[2], ids[0]}));
    state.MoveSpace(ids[2], 1);
    CHECK(Ids(state) == (std::vector<std::string>{ids[1], ids[2], ids[0]}));
    state.MoveSpace(ids[0], 0);
    CHECK(Ids(state) == (std::vector<std::string>{ids[0], ids[1], ids[2]}));
}

TEST(aDeletedSpaceTakesItsTabsWithoutArchivingThem) {
    BrowserState state = ThreeSpaces();
    state.OpenTab("https://a.example", state.spaces[1].id);
    state.OpenTab("https://b.example", state.spaces[1].id);
    state.DeleteSpace(state.spaces[1].id);
    CHECK(state.archived.empty() && state.recentlyClosed.empty());
    for (const Space& space : state.spaces) CHECK(space.tabs.empty());
}

TEST(aTabClosedInADeletedSpaceReopensInTheCurrentOne) {
    // As the Mac's restoreFromADeletedSpaceGoesToTheCurrentOne (ArchiveTests), for Ctrl+Shift+T.
    BrowserState state = ThreeSpaces();
    const std::string tab = state.OpenTab("https://x.example", state.spaces[1].id);
    state.Close(tab);
    state.DeleteSpace(state.spaces[1].id);
    CHECK(state.ReopenLastClosed() == tab);
    CHECK(state.SelectedSpace().name == "A");
    CHECK(state.spaces[0].tabs.size() == 1 && state.spaces[0].tabs[0].id == tab);
}

TEST(aNewSpaceInheritsTheProfileAfterTheLast) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(2);
    const std::string id = state.InsertSpace("D", "", Theme::Presets()[1], "Profile 1");
    CHECK(Names(state) == (std::vector<std::string>{"A", "B", "C", "D"}));
    CHECK(state.selectedSpaceID == id);
    const auto profile = state.spaces[3].extra.find("profile");
    CHECK(profile != state.spaces[3].extra.end() && profile->second.AsString() && *profile->second.AsString() == "Profile 1");
    CHECK(state.spaces[2].extra.find("profile") == state.spaces[2].extra.end());
}

TEST(newFolderGoesAtTheEndOfThePinnedItemsOpen) {
    BrowserState state = ThreeSpaces();
    state.CreateFolder("First", 1);
    const std::string id = state.CreateFolder("New Folder", 1);
    CHECK(state.spaces[1].pinnedItems.size() == 2);
    const auto* folder = std::get_if<Folder>(&state.spaces[1].pinnedItems.back().value);
    CHECK(folder && folder->id == id && folder->name == "New Folder" && folder->isExpanded && folder->items.empty());
    // It round-trips as the Mac writes a TabFolder.
    const auto loaded = RoundTrip(state);
    CHECK(loaded && *loaded == state);
}

// The space menu (SpaceContextMenus.menu), Delete Space and New Space.

TEST(theSpaceMenuHasTheMacsItemsInItsOrder) {
    BrowserState state = ThreeSpaces();
    const std::vector<SpaceMenuItem> menu = SpaceMenu(state, state.spaces[1].id);
    CHECK(SpaceMenuLine(menu) ==
          "(Change Space Icon\xE2\x80\xA6) | Rename Space\xE2\x80\xA6 | (What's This Space For?\xE2\x80\xA6) | (Edit Theme Color\xE2\x80\xA6) | "
          "(Set Profile \xE2\x96\xB8) | --- | New Folder | (Live Folders \xE2\x96\xB8) | --- | Delete Space");
    CHECK(SpaceMenu(state, "NOPE").empty());
}

TEST(theLastSpacesMenuCantDeleteIt) {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("A", "", Theme::Presets()[0]);
    const std::vector<SpaceMenuItem> menu = SpaceMenu(state, state.spaces[0].id);
    CHECK(!menu.empty() && menu.back().command == SpaceMenuItem::Command::Delete && !menu.back().enabled);
    CHECK(DeletionOf(state, state.spaces[0].id).kind == SpaceDeletion::Kind::Refused);
}

TEST(anEmptySpaceDeletesAtOnceAndOneWithTabsAsksFirst) {
    BrowserState state = ThreeSpaces();
    CHECK(DeletionOf(state, state.spaces[1].id).kind == SpaceDeletion::Kind::Now);
    // A pinned tab in a folder counts, as Space.allTabs does.
    const std::string folder = state.CreateFolder("F", 1);
    CHECK(DeletionOf(state, state.spaces[1].id).kind == SpaceDeletion::Kind::Now);
    Tab tab;
    tab.id = "0D0E1B5C-0000-4000-8000-000000000001";
    tab.url = "https://pinned.example";
    std::get<Folder>(state.spaces[1].pinnedItems.back().value).items.push_back(PinnedItem{tab});
    const SpaceDeletion ask = DeletionOf(state, state.spaces[1].id);
    CHECK(ask.kind == SpaceDeletion::Kind::Ask);
    CHECK(ask.title == "Delete \xE2\x80\x9C" "B\xE2\x80\x9D?");
    CHECK(ask.message == "Its pinned and unpinned tabs are closed.");
    CHECK(DeletionOf(state, "NOPE").kind == SpaceDeletion::Kind::Refused);
    (void)folder;
}

TEST(newSpaceTakesTheCurrentSpacesThemeAndProfile) {
    BrowserState state = ThreeSpaces();
    state.SelectSpaceAt(1);
    state.spaces[1].theme = Theme::Presets()[2];
    state.spaces[1].extra.emplace("profile", "Profile 2");
    const auto id = NewSpace(state, "  Reading ");
    CHECK(id.has_value());
    if (!id) return;
    CHECK(Names(state) == (std::vector<std::string>{"A", "B", "Reading", "C"}));
    CHECK(state.selectedSpaceID == *id);
    CHECK(state.spaces[2].theme == Theme::Presets()[2]);
    CHECK(state.spaces[2].icon.empty());
    CHECK(state.spaces[2].extra.at("profile").AsString() && *state.spaces[2].extra.at("profile").AsString() == "Profile 2");
    // A blank name makes nothing (Create Space stays disabled).
    const BrowserState before = state;
    CHECK(!NewSpace(state, " \t "));
    CHECK(state == before);
}

// SpaceBarView's drag (cellDragged, cellDragEnded, placeCells), on a 240pt sidebar.

namespace {
struct Strip {
    BrowserState state = ThreeSpaces();
    std::vector<SpaceCell> cells = SpaceCells(state);
    SpaceBarLayout layout = LayOutSpaceBar(240, cells.size());
    std::vector<std::string> ids = Ids(state);
    float CentreX(size_t i) const { return (layout.cells[i].left + layout.cells[i].right) / 2; }
    float midY = M::kHeight / 2;
    SpaceDrag Pick(size_t i) {
        SpaceBarPress press = *SpaceBarPressAt(layout, cells, CentreX(i), midY);
        SpaceBarMove(press, CentreX(i) + 5, midY);
        return *BeginSpaceDrag(layout, cells, press);
    }
};
}  // namespace

TEST(aDragStartsOnlyOnceThePressMovesAndWithTwoSpacesOrMore) {
    Strip s;
    SpaceBarPress press = *SpaceBarPressAt(s.layout, s.cells, s.CentreX(0), s.midY);
    SpaceBarMove(press, s.CentreX(0) + 3, s.midY);
    CHECK(!BeginSpaceDrag(s.layout, s.cells, press));
    SpaceBarMove(press, s.CentreX(0) + 4, s.midY);
    const auto drag = BeginSpaceDrag(s.layout, s.cells, press);
    CHECK(drag && drag->spaceID == s.ids[0] && drag->from == 0 && drag->target == 0 && !drag->landing);
    // Picked up where it sat: the ghost is over its cell until the pointer moves.
    CHECK(drag && SpaceDragGhost(s.layout, *drag) == s.layout.cells[0]);

    BrowserState one;
    one.spaces.clear();
    one.AddSpace("A", "", Theme::Presets()[0]);
    const std::vector<SpaceCell> cells = SpaceCells(one);
    const SpaceBarLayout layout = LayOutSpaceBar(240, 1);
    SpaceBarPress lone = *SpaceBarPressAt(layout, cells, 120, s.midY);
    SpaceBarMove(lone, 140, s.midY);
    CHECK(!BeginSpaceDrag(layout, cells, lone));
}

TEST(theGhostFollowsThePointerAndTheOthersSlideAside) {
    Strip s;
    SpaceDrag drag = s.Pick(0);
    // Half a pitch along stays in its own slot.
    CHECK(!MoveSpaceDrag(drag, s.layout, 3, s.CentreX(0) + 16, s.midY + 3));
    CHECK(drag.target == 0);
    const BarRect ghost = SpaceDragGhost(s.layout, drag);
    CHECK(ghost.left == s.layout.cells[0].left + 16 && ghost.top == s.layout.cells[0].top + 3);
    // Over B's place: B slides into slot 0 and the gap opens at 1.
    CHECK(MoveSpaceDrag(drag, s.layout, 3, s.CentreX(1), s.midY));
    CHECK(drag.target == 1);
    const std::vector<BarRect> placed = SpaceDragCells(s.layout, s.ids, drag);
    CHECK(placed[1] == s.layout.cells[0]);
    CHECK(placed[0] == s.layout.cells[1]);  // the dragged one, hidden, in the gap
    CHECK(placed[2] == s.layout.cells[2]);
    // Off the strip (above the bar, or over an end button) the gap closes.
    CHECK(MoveSpaceDrag(drag, s.layout, 3, s.CentreX(1), -10));
    CHECK(!drag.target);
    const std::vector<BarRect> closed = SpaceDragCells(s.layout, s.ids, drag);
    CHECK(closed[1] == s.layout.cells[0] && closed[2] == s.layout.cells[1]);
    CHECK(MoveSpaceDrag(drag, s.layout, 3, s.CentreX(1), s.midY));
    CHECK(MoveSpaceDrag(drag, s.layout, 3, (s.layout.plus.left + s.layout.plus.right) / 2, s.midY));
    CHECK(!drag.target);
}

TEST(aDropLandsInItsSlotAndTheSpaceMovesThere) {
    Strip s;
    s.state.SelectSpaceAt(0);
    SpaceDrag drag = s.Pick(0);
    MoveSpaceDrag(drag, s.layout, 3, s.CentreX(2) + 10, s.midY);
    const size_t slot = DropSpaceDrag(drag, s.layout, 3, s.CentreX(2) + 10, s.midY);
    CHECK(slot == 2 && drag.landing && drag.target == 2);
    // It settles into its slot, and no longer follows the pointer.
    CHECK(SpaceDragGhost(s.layout, drag) == s.layout.cells[2]);
    CHECK(!MoveSpaceDrag(drag, s.layout, 3, s.CentreX(0), s.midY));
    s.state.MoveSpace(drag.spaceID, slot);
    CHECK(Names(s.state) == (std::vector<std::string>{"B", "C", "A"}));
    CHECK(s.state.SelectedSpace().name == "A");
}

TEST(aDropOffTheStripGoesBackWhereItCameFrom) {
    Strip s;
    SpaceDrag drag = s.Pick(1);
    MoveSpaceDrag(drag, s.layout, 3, s.CentreX(2), s.midY);
    CHECK(DropSpaceDrag(drag, s.layout, 3, s.CentreX(2), s.midY + 200) == 1);
    CHECK(SpaceDragGhost(s.layout, drag) == s.layout.cells[1]);
    CHECK(SpaceDragCells(s.layout, s.ids, drag) == s.layout.cells);
}

// FolderTests.newFolderGoesToTheSelectedSpaceUnlessOneIsGiven.
TEST(newFolderGoesToTheSelectedSpaceUnlessOneIsGiven) {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("Home", "\xF0\x9F\x8F\xA0", Theme::Presets()[0]);
    state.AddSpace("Work", "\xF0\x9F\x92\xBC", Theme::Presets()[0]);
    state.SelectSpaceAt(1);
    state.CreateNewFolder();
    state.CreateNewFolder(0);
    state.CreateNewFolder(0);
    const auto names = [&](size_t space) {
        std::vector<std::string> out;
        for (const PinnedItem& item : state.spaces[space].pinnedItems) {
            if (const auto* folder = std::get_if<Folder>(&item.value)) out.push_back(folder->name);
        }
        return out;
    };
    CHECK(names(1) == (std::vector<std::string>{"New Folder"}));
    CHECK(names(0) == (std::vector<std::string>{"New Folder", "New Folder"}));
}
