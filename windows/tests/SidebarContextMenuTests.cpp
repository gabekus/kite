// The sidebar's row menus and their edits (core/SidebarContextMenu.cpp): the Mac's
// SidebarContextMenuTests (SidebarContextMenuTests.swift), case for case, each named after its
// Swift test; then the menus themselves (TabRowCell's, FolderRowCell's and FavoritePaneView's
// contextMenu, which the Mac builds in its views and doesn't test), where a right-click lands, a
// folder's Delete question, and edge cases the Mac doesn't check.
//
// Not ported: undoAndRedoDuplicateFolder, undoAndRedoTurnFolderIntoSpace and undoAndRedoArchiveTabs,
// which go through SidebarUndo and restoreSidebar: they come with W16 (undo).

#include <algorithm>
#include <set>
#include <string>
#include <variant>
#include <vector>

#include "Check.h"
#include "core/Models.h"
#include "core/Sidebar.h"
#include "core/SidebarContextMenu.h"

using namespace kite;

namespace {

using R = BrowserState::ArchiveTabsRelative;

// BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])]).
BrowserState OneSpace() {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("Home", "\xF0\x9F\x8F\xA0", Theme::Presets()[0]);
    return state;
}

std::vector<std::string> Ids(const std::vector<Tab>& tabs) {
    std::vector<std::string> out;
    for (const Tab& tab : tabs) out.push_back(tab.id);
    return out;
}

std::vector<std::string> Ids(const std::vector<const Tab*>& tabs) {
    std::vector<std::string> out;
    for (const Tab* tab : tabs) out.push_back(tab->id);
    return out;
}

std::vector<std::string> Ids(const std::vector<ClosedTab>& tabs) {
    std::vector<std::string> out;
    for (const ClosedTab& closed : tabs) out.push_back(closed.tab.id);
    return out;
}

std::vector<std::string> Ids(const std::vector<PinnedItem>& items) {
    std::vector<std::string> out;
    for (const PinnedItem& item : items) out.push_back(item.Id());
    return out;
}

const Folder* FolderIn(const BrowserState& state, const std::string& id) { return state.FolderByID(id); }

// One space with Today tabs a…e, top to bottom, and `c` selected.
struct Today {
    BrowserState state;
    std::vector<std::string> t;
};
Today MakeToday() {
    Today out{OneSpace(), {}};
    const std::string space = out.state.spaces[0].id;
    // OpenTab puts each new tab at the top, so open them bottom first.
    std::vector<std::string> ids;
    for (const char* name : {"e", "d", "c", "b", "a"}) ids.push_back(out.state.OpenTab(std::string("https://") + name + ".example", space, false));
    out.state.spaces[0].selectedTabID = ids[2];
    out.t.assign(ids.rbegin(), ids.rend());
    return out;
}

// Reading (a, and Inner holding b renamed Bee), then After, in one space.
struct Folders {
    BrowserState state;
    std::string folder, inner;
    std::vector<std::string> tabs;
};
Folders MakeFolders() {
    Folders out{OneSpace(), {}, {}, {}};
    BrowserState& state = out.state;
    const std::string space = state.spaces[0].id;
    out.folder = state.CreateFolder("Reading", 0);
    state.CreateFolder("After", 0);
    const std::string a = state.OpenTab(std::string("https://a.example"), space, false);
    const std::string b = state.OpenTab(std::string("https://b.example"), space, false);
    state.MoveTabToFolder(a, out.folder);
    out.inner = *state.CreateNestedFolder(out.folder, "Inner");
    state.MoveTabToFolder(b, out.inner);
    state.RenameTab(b, "Bee");
    out.tabs = {a, b};
    return out;
}

Folder LiveFolder(const std::string& name) {
    Folder live;
    live.id = "0F0F0F0F-0000-4000-8000-000000000001";
    live.name = name;
    live.live = json::Value(json::Object{{"source", json::Value(std::string("github"))}});
    return live;
}

}  // namespace

// MARK: SidebarContextMenuTests (SidebarContextMenuTests.swift)

TEST(archiveTabsAboveBelowAndOthersAreRelativeToTheRow) {
    const Today f = MakeToday();
    const auto& t = f.t;
    CHECK(f.state.TabsToArchive(R::Above, t[2]) == (std::vector<std::string>{t[0], t[1]}));
    CHECK(f.state.TabsToArchive(R::Below, t[2]) == (std::vector<std::string>{t[3], t[4]}));
    CHECK(f.state.TabsToArchive(R::Others, t[2]) == (std::vector<std::string>{t[0], t[1], t[3], t[4]}));
    // Arc greys out Archive Tabs Above on the top row.
    CHECK(f.state.TabsToArchive(R::Above, t[0]).empty());
    CHECK(f.state.TabsToArchive(R::Below, t[4]).empty());
}

TEST(archivingBelowKeepsTheRestAndFillsTheArchive) {
    Today f = MakeToday();
    const auto& t = f.t;
    const std::vector<Tab> archived = f.state.ArchiveTabs(R::Below, t[1]);
    CHECK(Ids(archived) == (std::vector<std::string>{t[2], t[3], t[4]}));
    CHECK(Ids(f.state.spaces[0].tabs) == (std::vector<std::string>{t[0], t[1]}));
    CHECK(Ids(f.state.archived) == (std::vector<std::string>{t[2], t[3], t[4]}));
    // The selected tab went, so the row the menu was on is selected.
    CHECK(f.state.spaces[0].selectedTabID == t[1]);
}

TEST(archivingOthersKeepsASplitRowTogether) {
    Today f = MakeToday();
    const auto& t = f.t;
    f.state.spaces[0].splits = {SplitView{"5E5E5E5E-0000-4000-8000-000000000001", {t[1], t[2]}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    CHECK(f.state.TabsToArchive(R::Others, t[1]) == (std::vector<std::string>{t[0], t[3], t[4]}));
    CHECK(f.state.TabsToArchive(R::Above, t[2]) == (std::vector<std::string>{t[0]}));
    f.state.ArchiveTabs(R::Others, t[2]);
    CHECK(Ids(f.state.spaces[0].tabs) == (std::vector<std::string>{t[1], t[2]}));
    CHECK(!f.state.spaces[0].splits.empty() && f.state.spaces[0].splits[0].tabIDs == (std::vector<std::string>{t[1], t[2]}));
    CHECK(f.state.spaces[0].selectedTabID == t[2]);
}

TEST(archiveTabsIsOnlyForTodayTabs) {
    Today f = MakeToday();
    const auto& t = f.t;
    f.state.TogglePin(t[2]);
    CHECK(f.state.TabsToArchive(R::Others, t[2]).empty());
    CHECK(f.state.ArchiveTabs(R::Others, t[2]).empty());
    CHECK(f.state.ArchiveTabs(R::Others, "00000000-0000-4000-8000-0000000000AA").empty());
}

TEST(markdownListIsOneLinkPerLine) {
    Tab a;
    a.url = "https://a.example/x";
    a.title = "A [1]";
    Tab b;
    b.url = "https://b.example";
    b.title = "Page";
    b.customTitle = "Mine";
    Tab blank;
    blank.title = "New Tab";
    CHECK(MarkdownLinkList({&a, &blank, &b}) == "[A \\[1\\]](https://a.example/x)\n[Mine](https://b.example)");
    CHECK(MarkdownLinkList({}).empty());
}

TEST(newNestedFolderGoesInsideAndOpensIt) {
    Folders f = MakeFolders();
    f.state.SetFolderExpanded(f.folder, false);
    const auto nested = f.state.CreateNestedFolder(f.inner);
    CHECK(nested.has_value());
    const Folder* found = FolderIn(f.state, f.inner);
    CHECK(found && !found->items.empty() && found->items.back().Id() == *nested);
    CHECK(FolderIn(f.state, *nested) && FolderIn(f.state, *nested)->name == "New Folder");
    CHECK(found && found->isExpanded);
    CHECK(!f.state.CreateNestedFolder("00000000-0000-4000-8000-0000000000AA"));
}

TEST(duplicateFolderCopiesTheTreeRightAfterIt) {
    Folders f = MakeFolders();
    const auto duplicated = f.state.DuplicateFolder(f.folder);
    CHECK(duplicated.has_value());
    if (!duplicated) return;
    const std::vector<std::string> top = Ids(f.state.spaces[0].pinnedItems);
    const auto at = [&](const std::string& id) { return std::find(top.begin(), top.end(), id) - top.begin(); };
    CHECK(at(*duplicated) == at(f.folder) + 1);
    const Folder* copy = FolderIn(f.state, *duplicated);
    CHECK(copy && copy->name == "Reading");
    if (!copy) return;
    const std::vector<const Tab*> copied = TabsIn(copy->items);
    CHECK(copied.size() == 2);
    if (copied.size() != 2) return;
    CHECK(copied[0]->url == f.state.FindTabByID(f.tabs[0])->url && copied[1]->url == f.state.FindTabByID(f.tabs[1])->url);
    CHECK(!copied[0]->customTitle && copied[1]->customTitle == "Bee");
    // Fresh ids all the way down.
    CHECK(copied[0]->id != f.tabs[0] && copied[0]->id != f.tabs[1] && copied[1]->id != f.tabs[0] && copied[1]->id != f.tabs[1]);
    const auto* innerCopy = std::get_if<Folder>(&copy->items.back().value);
    CHECK(innerCopy != nullptr);
    if (!innerCopy) return;
    CHECK(innerCopy->name == "Inner");
    CHECK(innerCopy->id != f.inner && *duplicated != f.folder);
    CHECK(FolderIn(f.state, innerCopy->id) != nullptr);
    CHECK(!f.state.DuplicateFolder("00000000-0000-4000-8000-0000000000AA"));
}

TEST(duplicateANestedFolderStaysInItsParent) {
    Folders f = MakeFolders();
    const auto duplicated = f.state.DuplicateFolder(f.inner);
    CHECK(duplicated.has_value());
    const Folder* parent = FolderIn(f.state, f.folder);
    CHECK(parent && parent->items.size() >= 2);
    if (!parent || parent->items.size() < 2 || !duplicated) return;
    CHECK(parent->items[parent->items.size() - 2].Id() == f.inner && parent->items.back().Id() == *duplicated);
}

TEST(turningAFolderIntoASpace) {
    Folders f = MakeFolders();
    f.state.spaces[0].extra["profile"] = json::Value(std::string("Profile 1"));
    f.state.spaces[0].selectedTabID = f.tabs[0];
    const auto turned = f.state.TurnFolderIntoSpace(f.folder);
    CHECK(turned.has_value());
    if (!turned) return;
    CHECK(f.state.spaces.size() == 2 && f.state.spaces[1].id == *turned);
    const Space& space = f.state.spaces[1];
    const auto profile = space.extra.find("profile");
    CHECK(space.name == "Reading" && profile != space.extra.end() && profile->second.AsString() &&
          *profile->second.AsString() == "Profile 1" && space.theme == f.state.spaces[0].theme);
    CHECK(Ids(space.AllTabs()) == f.tabs);
    CHECK(space.selectedTabID == f.tabs[0]);
    CHECK(f.state.selectedSpaceID == *turned);
    CHECK(FolderIn(f.state, f.folder) == nullptr);
    CHECK(f.state.spaces[0].AllTabs().empty() && !f.state.spaces[0].selectedTabID);
    CHECK(!f.state.TurnFolderIntoSpace(f.folder));
}

TEST(theClaudeFolderNeverBecomesASpaceOrIsDuplicated) {
    BrowserState state = OneSpace();
    const std::string space = state.spaces[0].id;
    // claudeSessionFolder(named: "Research"): the space's Claude folder, with the session's inside,
    // both ephemeral (Windows has no Claude automation to make them).
    Folder root;
    root.id = "C1C1C1C1-0000-4000-8000-000000000001";
    root.name = "Claude";
    root.ephemeral = true;
    Folder session;
    session.id = "C1C1C1C1-0000-4000-8000-000000000002";
    session.name = "Research";
    session.ephemeral = true;
    root.items.push_back(PinnedItem{session});
    state.spaces[0].pinnedItems.push_back(PinnedItem{root});
    const std::string tab = state.OpenTab(std::string("https://a.example"), space, false);
    state.MoveTabToFolder(tab, session.id);
    for (const std::string& id : {root.id, session.id}) {
        CHECK(!state.CanTurnFolderIntoSpace(id) && !state.CanDuplicateFolder(id));
        CHECK(!state.TurnFolderIntoSpace(id) && !state.DuplicateFolder(id));
    }
    // A plain folder holding a Claude folder doesn't go either.
    const std::string outer = state.CreateFolder("Outer", 0);
    std::vector<PinnedItem>& items = state.spaces[0].pinnedItems;
    auto it = std::find_if(items.begin(), items.end(), [&](const PinnedItem& item) { return item.Id() == root.id; });
    CHECK(it != items.end());
    if (it == items.end()) return;
    PinnedItem moved = std::move(*it);
    items.erase(it);
    for (PinnedItem& item : items) {
        if (auto* folder = std::get_if<Folder>(&item.value); folder && folder->id == outer) folder->items.push_back(std::move(moved));
    }
    CHECK(!state.TurnFolderIntoSpace(outer));
    CHECK(state.spaces.size() == 1);
}

TEST(aFolderNamedClaudeOrAnEmptyOneNeverBecomesASpace) {
    Folders f = MakeFolders();
    f.state.RenameFolder(f.folder, " claude ");
    CHECK(!f.state.CanTurnFolderIntoSpace(f.folder));
    CHECK(!f.state.TurnFolderIntoSpace(f.folder));
    const std::string empty = f.state.CreateFolder("Empty", 0);
    CHECK(!f.state.CanTurnFolderIntoSpace(empty));
    CHECK(!f.state.TurnFolderIntoSpace(empty));
    CHECK(f.state.spaces.size() == 1);
}

TEST(duplicateLeavesLiveFoldersOutAndKeepsClaudeFlags) {
    Folders f = MakeFolders();
    const Folder live = LiveFolder("GitHub");
    for (PinnedItem& item : f.state.spaces[0].pinnedItems) {
        if (auto* folder = std::get_if<Folder>(&item.value); folder && folder->id == f.folder) folder->items.push_back(PinnedItem{live});
    }
    CHECK(!f.state.CanDuplicateFolder(live.id));
    const auto duplicated = f.state.DuplicateFolder(f.folder);
    const Folder* copy = duplicated ? FolderIn(f.state, *duplicated) : nullptr;
    CHECK(copy != nullptr);
    if (!copy) return;
    CHECK(std::none_of(copy->items.begin(), copy->items.end(), [](const PinnedItem& item) {
        const auto* folder = std::get_if<Folder>(&item.value);
        return folder && folder->live;
    }));
    CHECK(copy->items.size() == 2);
}

// MARK: Edge cases the Mac doesn't check

// archiveToday: each archived tab keeps its place in Today, and goes to the archive only (not
// Recently Closed, which Ctrl+Shift+T reopens).
TEST(archivedTabsKeepTheirPlaceAndStayOutOfRecentlyClosed) {
    Today f = MakeToday();
    const size_t recently = f.state.recentlyClosed.size();
    f.state.ArchiveTabs(R::Above, f.t[2], 1000);
    CHECK(f.state.archived.size() == 2 && f.state.archived[0].index == 0 && f.state.archived[1].index == 1);
    CHECK(f.state.archived[0].archivedAt == 1000.0 && f.state.archived[0].reason == ArchiveReason::Manual);
    CHECK(f.state.archived[0].spaceID == f.state.spaces[0].id);
    CHECK(f.state.recentlyClosed.size() == recently);
    // The selected tab stayed: the selection doesn't move.
    CHECK(f.state.spaces[0].selectedTabID == f.t[2]);
}

// A split left with one pane after Archive Other Tabs on another row is no split.
TEST(archivingOthersBreaksASplitOnAnotherRow) {
    Today f = MakeToday();
    const auto& t = f.t;
    f.state.spaces[0].splits = {SplitView{"5E5E5E5E-0000-4000-8000-000000000002", {t[3], t[4]}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    // The split's row is one row: everything but d and e goes, from either pane.
    CHECK(f.state.TabsToArchive(R::Others, t[4]) == (std::vector<std::string>{t[0], t[1], t[2]}));
    CHECK(f.state.TabsToArchive(R::Below, t[3]).empty());
    f.state.ArchiveTabs(R::Below, t[2]);
    CHECK(f.state.spaces[0].splits.empty());
}

TEST(markdownLinkEscapesTheTextAndTheDestination) {
    CHECK(MarkdownLink("  ", "https://a.example") == "[https://a.example](https://a.example)");
    CHECK(MarkdownLink("a\\b", "https://a.example/(x) y") == "[a\\\\b](https://a.example/%28x%29%20y)");
    // A newline in the text is a space; one at the ends is trimmed first.
    CHECK(MarkdownLink("\nOne\r\nTwo\n", "https://a.example") == "[One Two](https://a.example)");
    // By Character: a bracket with a mark on it is another character, and isn't escaped.
    CHECK(MarkdownLink("[\xCC\x81]", "https://a.example") == "[[\xCC\x81\\]](https://a.example)");
    Tab none;
    CHECK(!MarkdownLink(none));
}

TEST(claudeMayCreateEverySpaceButClaude) {
    CHECK(!ClaudeMayCreateSpace("Claude"));
    CHECK(!ClaudeMayCreateSpace(" CLAUDE\t"));
    CHECK(!ClaudeMayCreateSpace("\xE3\x80\x80" "claude"));  // an ideographic space is Zs
    // CharacterSet.whitespaces leaves newlines, so a newline keeps it another name.
    CHECK(ClaudeMayCreateSpace("Claude\n"));
    CHECK(ClaudeMayCreateSpace("Claudes"));
    CHECK(ClaudeMayCreateSpace(""));
}

// MARK: The menus (SidebarListCells.swift, SidebarFavorites.swift)

// A Today tab in the middle of Today, selected: everything a Today row has.
TEST(aTodayTabsMenuIsTheMacs) {
    const Today f = MakeToday();
    CHECK(SidebarMenuLine(TabMenu(f.state, f.t[2])) ==
          "Add to Favorites | Pin Tab | Copy Link | Copy link as Markdown | Rename\xE2\x80\xA6 | --- | (Add Split View) | Duplicate | "
          "(Move to \xE2\x96\xB8 [(\xF0\x9F\x8F\xA0 Home)]) | --- | Close Tab | Archive Other Tabs | Archive Tabs Below | Archive Tabs Above");
    // Another row (not on screen): Open in Split View; the top row greys out Archive Tabs Above, the
    // bottom one Below.
    CHECK(SidebarMenuLine(TabMenu(f.state, f.t[0])) ==
          "Add to Favorites | Pin Tab | Copy Link | Copy link as Markdown | Rename\xE2\x80\xA6 | --- | (Open in Split View) | Duplicate | "
          "(Move to \xE2\x96\xB8 [(\xF0\x9F\x8F\xA0 Home)]) | --- | Close Tab | Archive Other Tabs | Archive Tabs Below | (Archive Tabs Above)");
    const auto bottom = TabMenu(f.state, f.t[4]);
    CHECK(bottom.size() == 14 && !bottom[12].enabled && bottom[12].command == SidebarMenuItem::Command::ArchiveBelow && bottom[13].enabled);
}

TEST(aPinnedTabsMenuOffersItsPinnedPage) {
    Today f = MakeToday();
    const std::string id = f.t[1];
    f.state.TogglePin(id);
    f.state.AddSpace("Work", "symbol:briefcase", Theme::Presets()[1]);
    // Pinned at its page: Unpin, Edit Pinned Page, Unload; no archive items.
    CHECK(SidebarMenuLine(TabMenu(f.state, id)) ==
          "Add to Favorites | Unpin Tab | Edit Pinned Page \xE2\x96\xB8 [(Edit\xE2\x80\xA6) / Replace Pinned URL with Current] | Copy Link | "
          "Copy link as Markdown | Rename\xE2\x80\xA6 | --- | (Open in Split View) | Duplicate | "
          "(Move to \xE2\x96\xB8 [(\xF0\x9F\x8F\xA0 Home) / (Work)]) | --- | Unload Tab");
    // Off its pinned page: Back to Pinned URL and Separate From Pinned Tab.
    for (Space& space : f.state.spaces) {
        if (Tab* tab = FindTab(space.pinnedItems, id)) tab->url = "https://b.example/elsewhere";
    }
    const auto menu = TabMenu(f.state, id);
    CHECK(menu.size() == 14 && menu[2].title == "Back to Pinned URL" && menu[3].title == "Separate From Pinned Tab" &&
          menu[4].submenu && menu[4].title == "Edit Pinned Page");
}

TEST(aTabWithNoPageCantCopyItsLink) {
    BrowserState state = OneSpace();
    const std::string id = state.OpenTab(std::nullopt, state.spaces[0].id, false);
    const auto menu = TabMenu(state, id);
    CHECK(menu.size() >= 4 && menu[2].title == "Copy Link" && !menu[2].enabled && !menu[3].enabled);
    // No such tab, or a favorite, has no row menu.
    CHECK(TabMenu(state, "00000000-0000-4000-8000-0000000000AA").empty());
}

TEST(aFoldersMenuIsTheMacs) {
    const Folders f = MakeFolders();
    CHECK(SidebarMenuLine(FolderMenu(f.state, f.folder)) ==
          "Duplicate | --- | Delete | --- | New Nested Folder\xE2\x80\xA6 | Turn \xE2\x80\x9CReading\xE2\x80\x9D into Space | Copy All Links | "
          "Copy All Links as Markdown | --- | Rename\xE2\x80\xA6");
    CHECK(SidebarMenu(f.state, SidebarMenuKind::Folder, f.folder) == FolderMenu(f.state, f.folder));
}

TEST(anEmptyFolderCantBecomeASpaceOrCopyLinks) {
    Folders f = MakeFolders();
    const std::string empty = f.state.CreateFolder("Empty", 0);
    CHECK(SidebarMenuLine(FolderMenu(f.state, empty)) ==
          "Duplicate | --- | Delete | --- | New Nested Folder\xE2\x80\xA6 | (Turn \xE2\x80\x9C" "Empty\xE2\x80\x9D into Space) | (Copy All Links) | "
          "(Copy All Links as Markdown) | --- | Rename\xE2\x80\xA6");
    // A folder named Claude has no Turn … into Space at all.
    f.state.RenameFolder(f.folder, "Claude");
    const auto menu = FolderMenu(f.state, f.folder);
    CHECK(std::none_of(menu.begin(), menu.end(), [](const SidebarMenuItem& item) {
        return item.command == SidebarMenuItem::Command::TurnFolderIntoSpace;
    }));
}

TEST(claudesFolderIsNeitherCopiedNorTurnedIntoASpace) {
    Folders f = MakeFolders();
    Folder claude;
    claude.id = "C1C1C1C1-0000-4000-8000-000000000003";
    claude.name = "Claude";
    claude.ephemeral = true;
    f.state.spaces[0].pinnedItems.push_back(PinnedItem{claude});
    CHECK(SidebarMenuLine(FolderMenu(f.state, claude.id)) ==
          "Delete | --- | New Nested Folder\xE2\x80\xA6 | (Copy All Links) | (Copy All Links as Markdown) | --- | Rename\xE2\x80\xA6");
}

TEST(aLiveFoldersMenuDeletesButDoesntRefresh) {
    Folders f = MakeFolders();
    const Folder live = LiveFolder("GitHub");
    f.state.spaces[0].pinnedItems.push_back(PinnedItem{live});
    CHECK(SidebarMenuLine(FolderMenu(f.state, live.id)) == "(Refresh) | --- | Delete Live Folder");
    CHECK(FolderMenu(f.state, "00000000-0000-4000-8000-0000000000AA").empty());
}

TEST(aFavoritesMenuIsTheMacs) {
    BrowserState state = OneSpace();
    const std::string id = state.OpenTab(std::string("https://a.example"), state.spaces[0].id, false);
    state.ToggleFavorite(id);
    state.SyncPinnedURLs();
    CHECK(SidebarMenuLine(FavoriteMenu(state, id)) ==
          "Remove from Favorites | Edit Pinned Page \xE2\x96\xB8 [(Edit\xE2\x80\xA6) / Replace Pinned URL with Current] | Copy Link | --- | Unload Tab");
    // Without a pinned URL (a blank favorite), no Edit Pinned Page; Copy Link stays enabled.
    const std::string blank = state.OpenTab(std::nullopt, state.spaces[0].id, false);
    state.ToggleFavorite(blank);
    CHECK(SidebarMenuLine(FavoriteMenu(state, blank)) == "Remove from Favorites | Copy Link | --- | Unload Tab");
    // A favorite has no tab row menu, and a space's tab no favorite menu.
    CHECK(TabMenu(state, id).empty());
    const std::string other = state.OpenTab(std::string("https://b.example"), state.spaces[0].id, false);
    CHECK(FavoriteMenu(state, other).empty());
}

TEST(aTestPicksAnEnabledItemByTitleOrPath) {
    Today f = MakeToday();
    f.state.TogglePin(f.t[1]);
    const auto menu = TabMenu(f.state, f.t[1]);
    const SidebarMenuItem* unpin = PickSidebarMenuItem(menu, "Unpin Tab");
    CHECK(unpin && unpin->command == SidebarMenuItem::Command::TogglePin);
    const SidebarMenuItem* replace = PickSidebarMenuItem(menu, "Edit Pinned Page \xE2\x96\xB8 Replace Pinned URL with Current");
    CHECK(replace && replace->command == SidebarMenuItem::Command::ReplacePinnedURL);
    // Disabled items, submenus themselves, and a disabled submenu's items aren't picked.
    CHECK(!PickSidebarMenuItem(menu, "Edit Pinned Page \xE2\x96\xB8 Edit\xE2\x80\xA6"));
    CHECK(!PickSidebarMenuItem(menu, "Edit Pinned Page"));
    CHECK(!PickSidebarMenuItem(menu, "Move to \xE2\x96\xB8 \xF0\x9F\x8F\xA0 Home"));
    CHECK(!PickSidebarMenuItem(menu, "Open in Split View"));
    CHECK(!PickSidebarMenuItem(menu, "Nothing"));
}

TEST(aRightClickFindsTheRowsMenu) {
    Folders f = MakeFolders();
    const std::string today = f.state.OpenTab(std::string("https://c.example"), f.state.spaces[0].id, false);
    f.state.SetFolderExpanded(f.folder, false);
    // header, Reading, After, divider, New Tab, the Today tab
    const auto rows = SidebarRows(f.state, 0);
    CHECK(rows.size() == 6);
    if (rows.size() != 6) return;
    const auto at = [&](size_t row, float x = 100) {
        return SidebarMenuTargetAt(rows, 240, 800, 0, x, sidebar_metrics::kHeaderAreaHeight + rows[row].top + rows[row].height / 2);
    };
    using K = SidebarMenuTarget::Kind;
    CHECK(at(0) == (SidebarMenuTarget{K::Space, f.state.spaces[0].id, false}));
    CHECK(at(1) == (SidebarMenuTarget{K::Folder, f.folder, false}));
    CHECK(!at(3));  // the divider takes nothing
    // New Tab is a row with no menu: a right-click opens nothing, a Ctrl+click is spent.
    CHECK(at(4) == (SidebarMenuTarget{K::None, f.state.spaces[0].id, false}));
    CHECK(at(5) == (SidebarMenuTarget{K::Tab, today, false}));
    // Its close button (202 to 226) passes a right-click's menu up to the row, but it's a button: a
    // Ctrl+click presses it (SymbolButton's controlClickShowsMenu is false).
    CHECK(at(5, 220) == (SidebarMenuTarget{K::Tab, today, true}));
    // The header's chevron (205 to 231, 5pt down; the space has pinned items) likewise.
    const float headerTop = sidebar_metrics::kHeaderAreaHeight + rows[0].top;
    CHECK(SidebarMenuTargetAt(rows, 240, 800, 0, 220, headerTop + 10) == (SidebarMenuTarget{K::Space, f.state.spaces[0].id, true}));
    // The address field and the gap between pills have none.
    CHECK(!SidebarMenuTargetAt(rows, 240, 800, 0, 100, 60));
    CHECK(!SidebarMenuTargetAt(rows, 240, 800, 0, 100, sidebar_metrics::kHeaderAreaHeight + rows[1].top + 1));
}

TEST(deletingAFolderAsksInArcsWords) {
    Folders f = MakeFolders();
    CHECK(FolderDeletionOf(f.state, f.folder) ==
          (FolderDeletion{true, false, "Delete your \xE2\x80\x9CReading\xE2\x80\x9D folder?",
                          "Deleting this folder will archive the tabs inside it.", "Delete Folder"}));
    CHECK(FolderDeletionOf(f.state, "00000000-0000-4000-8000-0000000000AA") == FolderDeletion{});
    const Folder live = LiveFolder("GitHub");
    f.state.spaces[0].pinnedItems.push_back(PinnedItem{live});
    // A live folder's is deleteLiveFolder's question.
    CHECK(FolderDeletionOf(f.state, live.id) == (FolderDeletion{true, true, "Delete your GitHub Live Folder?",
                                                                "You can restore this folder at any time by right-clicking the sidebar.", "Delete"}));
}

// LiveFolders.swift's deleteLiveFolder: the folder and its tabs go unarchived, its source is turned
// off (once), and a selected tab in it hands the selection to the space's first tab.
TEST(deletingALiveFolderTurnsItsSourceOff) {
    Folders f = MakeFolders();
    Folder live = LiveFolder("GitHub");
    Tab pull;
    pull.id = "0F0F0F0F-0000-4000-8000-0000000000A1";
    pull.url = "https://github.com/a/b/pull/1";
    pull.title = "A pull request";
    live.items.push_back(PinnedItem{pull});
    f.state.spaces[0].pinnedItems.push_back(PinnedItem{live});
    f.state.spaces[0].selectedTabID = pull.id;
    const size_t archived = f.state.archived.size();
    CHECK(f.state.DeleteLiveFolder(live.id) == std::vector<std::string>{pull.id});
    CHECK(!f.state.FolderByID(live.id) && !f.state.FindTabByID(pull.id));
    CHECK(f.state.archived.size() == archived);
    CHECK(f.state.spaces[0].selectedTabID == f.tabs[0]);
    const auto off = f.state.extra.find("liveFoldersTurnedOff");
    CHECK(off != f.state.extra.end() && off->second.AsArray() && off->second.AsArray()->size() == 1 &&
          *(*off->second.AsArray())[0].AsString() == "github");
    // Another GitHub folder deleted later doesn't list the source twice; a plain folder isn't one.
    Folder again = LiveFolder("GitHub");
    again.id = "0F0F0F0F-0000-4000-8000-000000000002";
    f.state.spaces[0].pinnedItems.push_back(PinnedItem{again});
    f.state.DeleteLiveFolder(again.id);
    CHECK(f.state.extra.find("liveFoldersTurnedOff")->second.AsArray()->size() == 1);
    CHECK(f.state.DeleteLiveFolder(f.folder).empty() && f.state.FolderByID(f.folder));
}

// showSidebarMenu logs an empty submenu as "Title ▸ []".
TEST(anEmptySubmenusLineHasEmptyBrackets) {
    SidebarMenuItem empty;
    empty.command = SidebarMenuItem::Command::MoveTo;
    empty.title = "Move to";
    empty.submenu = true;
    empty.enabled = false;
    CHECK(SidebarMenuLine({empty}) == "(Move to \xE2\x96\xB8 [])");
}

TEST(copyAllLinksIsOneAddressALine) {
    Tab a;
    a.url = "https://a.example/";
    Tab none;
    Tab b;
    b.url = "https://b.example/x";
    CHECK(LinkList({&a, &none, &b}) == "https://a.example/\nhttps://b.example/x");
    CHECK(LinkList({&none}).empty());
}

// Turn into Space with a split moving (both panes in the folder), a split staying (one pane outside),
// a nested folder going along, and the selected tab outside the folder (it stays selected there).
TEST(turningAFolderIntoASpaceTakesItsSplitsAndNestedFolders) {
    Folders f = MakeFolders();
    const std::string space = f.state.spaces[0].id;
    const std::string c = f.state.OpenTab(std::string("https://c.example"), space, false);
    const std::string outside = f.state.OpenTab(std::string("https://d.example"), space, false);
    f.state.MoveTabToFolder(c, f.inner);
    f.state.MoveTabToFolder(outside, f.state.CreateFolder("Elsewhere", 0));
    f.state.spaces[0].splits = {
        SplitView{"5E5E5E5E-0000-4000-8000-000000000011", {f.tabs[1], c}, {0.5, 0.5}, "horizontal", std::nullopt, {}},
        SplitView{"5E5E5E5E-0000-4000-8000-000000000012", {f.tabs[0], outside}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    f.state.spaces[0].selectedTabID = outside;
    const auto turned = f.state.TurnFolderIntoSpace(f.folder);
    CHECK(turned.has_value());
    if (!turned || f.state.spaces.size() != 2) return;
    const Space& made = f.state.spaces[1];
    CHECK(Ids(made.AllTabs()) == (std::vector<std::string>{f.tabs[0], f.tabs[1], c}));
    CHECK(f.state.FolderByID(f.inner) != nullptr && made.pinnedItems.size() == 2);
    CHECK(made.splits.size() == 1 && made.splits[0].tabIDs == (std::vector<std::string>{f.tabs[1], c}));
    // The split with a pane left behind is no split in either space.
    CHECK(f.state.spaces[0].splits.empty());
    // The selection outside the folder stays; the new space selects its first tab.
    CHECK(f.state.spaces[0].selectedTabID == outside && made.selectedTabID == f.tabs[0]);
}

// Titles keep a folder's or space's own `&` (the shell doubles it for Win32's mnemonics).
TEST(menuTitlesKeepAnAmpersand) {
    Folders f = MakeFolders();
    f.state.RenameFolder(f.folder, "Tom & Jerry");
    f.state.spaces[0].name = "R&D";
    const std::string tab = f.state.OpenTab(std::string("https://a.example"), f.state.spaces[0].id, false);
    const auto folder = FolderMenu(f.state, f.folder);
    CHECK(folder.size() > 5 && folder[5].title == "Turn \xE2\x80\x9CTom & Jerry\xE2\x80\x9D into Space");
    const auto menu = TabMenu(f.state, tab);
    const auto moveTo = std::find_if(menu.begin(), menu.end(), [](const SidebarMenuItem& item) { return item.command == SidebarMenuItem::Command::MoveTo; });
    CHECK(moveTo != menu.end() && moveTo->items.size() == 1 && moveTo->items[0].title == "\xF0\x9F\x8F\xA0 R&D");
}
