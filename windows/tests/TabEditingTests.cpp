// Pinning, favorites, renaming, duplicating, folders and pinned URLs (core/TabEditing.cpp,
// core/PinnedURL.cpp): the Mac's FolderEditingTests (FolderTests.swift), TabRenameTests,
// PinnedURLTests, and the cases of BrowserStateTests, FavoritesTests and SplitViewTests
// (KiteCoreTests.swift, SplitViewTests.swift) that pin, favorite or duplicate, case for case,
// each named after its Swift test; then edge cases the Mac doesn't check.
//
// Ported elsewhere already: TabRenameTests.tabSearchFindsARenamedTabByItsName (CommandBarTests),
// CollapsePinnedTabsTests (SidebarTests), FolderEditingTests.newFolderGoesToTheSelectedSpaceUnlessOneIsGiven
// (SpaceEditingTests). SplitViewTests builds its splits with addSplitPane, which Windows doesn't
// have yet: the split it makes (a blank pane after the selected tab, marked splitPane) is built
// by hand here.

#include <algorithm>
#include <cctype>
#include <set>
#include <string>
#include <variant>
#include <vector>

#include "Check.h"
#include "core/Json.h"
#include "core/Models.h"
#include "core/Sidebar.h"
#include "core/Uuid.h"

using namespace kite;

namespace {

const char* const kHome = "https://mail.example.com/inbox";
const char* const kAway = "https://mail.example.com/message/42";

Tab* Find(BrowserState& state, const std::string& id) {
    auto location = state.Location(id);
    return location ? state.TabAt(*location) : nullptr;
}

// BrowserState(spaces: [Space(name: "Home", icon: "🏠", ...)]).
BrowserState OneSpace(const char* name = "Home") {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace(name, "\xF0\x9F\x8F\xA0", Theme::Presets()[0]);
    return state;
}

std::vector<std::string> Ids(const std::vector<const Tab*>& tabs) {
    std::vector<std::string> out;
    for (const Tab* tab : tabs) out.push_back(tab->id);
    return out;
}

std::vector<std::string> Ids(const std::vector<Tab>& tabs) {
    std::vector<std::string> out;
    for (const Tab& tab : tabs) out.push_back(tab.id);
    return out;
}

std::vector<std::string> FolderNames(const BrowserState& state, size_t space) {
    std::vector<std::string> out;
    for (const Folder* folder : state.Folders(space)) out.push_back(folder->name);
    return out;
}

std::optional<BrowserState> RoundTrip(const BrowserState& state) {
    auto parsed = json::Parse(json::Write(Encode(state)));
    const json::Value* value = std::get_if<json::Value>(&parsed);
    return value ? DecodeBrowserState(*value) : std::nullopt;
}

// BrowserStateTests.makeState(tabs:): one space with tabs on site0…, newest first, so the ids
// come back in sidebar order.
std::pair<BrowserState, std::vector<std::string>> MakeState(int tabs) {
    BrowserState state = OneSpace("A");
    std::vector<std::string> ids;
    for (int i = 0; i < tabs; ++i) ids.push_back(state.OpenTab("https://site" + std::to_string(i) + ".com", std::nullopt, true, i));
    std::reverse(ids.begin(), ids.end());
    return {std::move(state), ids};
}

// SplitViewTests.makeState with addSplitPane(): ids[0] selected, a blank pane after it in a split.
struct SplitState {
    BrowserState state;
    std::vector<std::string> ids;
    std::string pane;
};
SplitState MakeSplit() {
    auto [state, ids] = MakeState(3);
    state.Select(ids[0]);
    Tab pane;
    pane.id = NewUuid();
    pane.splitPane = true;
    state.spaces[0].tabs.insert(state.spaces[0].tabs.begin() + 1, pane);
    SplitView split;
    split.id = NewUuid();
    split.tabIDs = {ids[0], pane.id};
    split.widthFactors = {0.5, 0.5};
    state.spaces[0].splits.push_back(split);
    return {std::move(state), ids, pane.id};
}

// FolderEditingTests.stateWithFolder: Reading holds a and Inner, which holds b.
struct FolderState {
    BrowserState state;
    std::string space, folder;
    std::vector<std::string> tabs;
};
FolderState StateWithFolder() {
    BrowserState state = OneSpace();
    const std::string space = state.spaces[0].id;
    const std::string folder = state.CreateFolder("Reading", 0);
    const std::string inner = state.CreateFolder("Inner", 0);
    const std::string a = state.OpenTab("https://a.example", space, true);
    const std::string b = state.OpenTab("https://b.example", space, false);
    const bool movedA = state.MoveTabToFolder(a, folder), movedB = state.MoveTabToFolder(b, inner);
    CHECK(movedA && movedB);
    // Nest Inner inside Reading.
    auto& items = state.spaces[0].pinnedItems;
    auto at = std::find_if(items.begin(), items.end(), [&](const PinnedItem& item) { return item.Id() == inner; });
    PinnedItem moved = std::move(*at);
    items.erase(at);
    std::get<Folder>(items[0].value).items.push_back(std::move(moved));
    return {std::move(state), space, folder, {a, b}};
}

// PinnedURLTests.pinnedState: one tab on kHome, pinned.
std::pair<BrowserState, std::string> PinnedState() {
    BrowserState state = OneSpace();
    const std::string id = state.OpenTab(kHome);
    state.TogglePin(id);
    return {std::move(state), id};
}

// TabRenameTests.state: one tab, "Example Domain" on example.com, selected.
std::pair<BrowserState, std::string> RenameState() {
    BrowserState state = OneSpace("S");
    Tab tab;
    tab.id = NewUuid();
    tab.url = "https://example.com";
    tab.title = "Example Domain";
    state.spaces[0].tabs = {tab};
    state.spaces[0].selectedTabID = tab.id;
    return {std::move(state), tab.id};
}

}  // namespace

// MARK: BrowserStateTests, FavoritesTests, SplitViewTests (pin, favorite, duplicate)

TEST(pinAndUnpin) {
    auto [state, ids] = MakeState(2);
    state.TogglePin(ids[1]);
    CHECK(Ids(state.SelectedSpace().Pinned()) == std::vector<std::string>{ids[1]});
    CHECK(Ids(state.SelectedSpace().tabs) == std::vector<std::string>{ids[0]});
    state.TogglePin(ids[1]);
    CHECK(state.SelectedSpace().Pinned().empty());
    CHECK(!state.SelectedSpace().tabs.empty() && state.SelectedSpace().tabs.front().id == ids[1]);
}

TEST(tabsInsideFoldersBehaveLikePinnedTabs) {
    BrowserState state = OneSpace("A");
    Tab inner, deep;
    inner.id = NewUuid();
    inner.url = "https://inner.example";
    deep.id = NewUuid();
    deep.url = "https://deep.example";
    Folder nested;
    nested.id = NewUuid();
    nested.name = "Deep";
    nested.items = {PinnedItem{deep}};
    Folder folder;
    folder.id = NewUuid();
    folder.name = "Work";
    folder.items = {PinnedItem{inner}, PinnedItem{nested}};
    state.spaces[0].pinnedItems = {PinnedItem{folder}};
    CHECK(Ids(state.SelectedSpace().Pinned()) == (std::vector<std::string>{inner.id, deep.id}));
    state.Select(deep.id);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == deep.id);
    Find(state, deep.id)->title = "Deep page";
    CHECK(state.FindTabByID(deep.id)->title == "Deep page");
    CHECK(state.Close(deep.id) == CloseOutcome::Unloaded);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == inner.id);
    state.TogglePin(deep.id);
    CHECK(Ids(state.SelectedSpace().tabs) == std::vector<std::string>{deep.id});
    CHECK(Ids(state.SelectedSpace().Pinned()) == std::vector<std::string>{inner.id});
    state.SetFolderExpanded(folder.id, false);
    const Folder* collapsed = std::get_if<Folder>(&state.SelectedSpace().pinnedItems[0].value);
    CHECK(collapsed && !collapsed->isExpanded);
}

TEST(favoritesAreSharedAndOpenInTheCurrentSpace) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const std::string mail = state.OpenTab("https://mail.example");
    state.ToggleFavorite(mail);
    CHECK(Ids(state.Favorites()) == std::vector<std::string>{mail});
    CHECK(state.SelectedSpace().tabs.empty());
    // Selecting a favorite from another space keeps you in that space.
    state.SelectSpaceAt(1);
    state.Select(mail);
    CHECK(state.SelectedSpaceIndex() == 1);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == mail);
    // Closing a favorite unloads it, like a pinned tab.
    CHECK(state.Close(mail) == CloseOutcome::Unloaded);
    CHECK(state.Favorites().size() == 1);
    CHECK(state.SelectedTab() == nullptr);
    state.ToggleFavorite(mail);
    CHECK(state.Favorites().empty());
    CHECK(!state.favoritesByProfile.contains(BrowserState::kDefaultProfile));
    CHECK(Ids(state.spaces[1].tabs) == std::vector<std::string>{mail});
}

TEST(duplicateGoesBelowTheOriginal) {
    auto [state, ids] = MakeState(2);
    const auto copy = state.Duplicate(ids[0]);
    CHECK(copy.has_value());
    CHECK(Ids(state.SelectedSpace().tabs) == (std::vector<std::string>{ids[0], *copy, ids[1]}));
    CHECK(state.FindTabByID(*copy)->url == state.FindTabByID(ids[0])->url);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == *copy);
}

TEST(pinningASplitByHandMakesItsPanesOrdinaryPinnedTabs) {
    // The selected tab pinned first; then its new pane (Add Split View next to a pinned tab) pinned
    // and unpinned, which takes the split's mark off it, so closing it only unloads it.
    auto [state, ids] = MakeState(3);
    state.Select(ids[0]);
    state.TogglePin(ids[0]);
    Tab pane;
    pane.id = NewUuid();
    pane.splitPane = true;
    state.spaces[0].pinnedItems.push_back(PinnedItem{pane});
    CHECK(state.FindTabByID(pane.id)->splitPane == true);
    state.TogglePin(pane.id);
    state.TogglePin(pane.id);
    CHECK(!state.FindTabByID(pane.id)->splitPane.has_value());
    Find(state, pane.id)->url = "https://example.com";
    CHECK(state.Close(pane.id) == CloseOutcome::Unloaded);
}

TEST(pinningMovesTheWholeSplit) {
    auto [state, ids, b] = MakeSplit();
    state.TogglePin(b);
    CHECK(Ids(state.SelectedSpace().Pinned()) == (std::vector<std::string>{ids[0], b}));
    CHECK(Ids(state.SelectedSpace().tabs) == (std::vector<std::string>{ids[1], ids[2]}));
    state.TogglePin(ids[0]);
    CHECK(state.SelectedSpace().Pinned().empty());
    CHECK(Ids(state.SelectedSpace().tabs) == (std::vector<std::string>{ids[0], b, ids[1], ids[2]}));
    CHECK(state.SelectedSpace().splits.size() == 1);
}

TEST(favoritingAPaneTakesItOutOfTheSplit) {
    auto [state, ids, b] = MakeSplit();
    state.ToggleFavorite(b);
    CHECK(state.SelectedSpace().splits.empty());
    CHECK(Ids(state.Favorites()) == std::vector<std::string>{b});
}

// MARK: FolderEditingTests

TEST(deletingAFolderArchivesItsTabsAndNestedFolders) {
    auto [state, space, folder, tabs] = StateWithFolder();
    const std::string kept = state.OpenTab("https://kept.example", space, false);
    state.spaces[0].selectedTabID = tabs[0];
    const std::vector<Tab> archived = state.DeleteFolder(folder);
    CHECK(Ids(archived) == tabs);
    CHECK(state.Folders(0).empty());
    CHECK(std::all_of(tabs.begin(), tabs.end(), [&](const std::string& id) { return !state.FindTabByID(id); }));
    CHECK(state.archived.size() >= 2 && state.archived[state.archived.size() - 2].tab.id == tabs[0] &&
          state.archived.back().tab.id == tabs[1]);
    CHECK(std::all_of(state.archived.begin(), state.archived.end(), [&](const ClosedTab& c) { return c.spaceID == space; }));
    CHECK(state.spaces[0].selectedTabID == kept);
    CHECK(state.DeleteFolder(folder).empty());
}

TEST(deletingAnEmptyFolderArchivesNothing) {
    BrowserState state = OneSpace();
    const std::string folder = state.CreateFolder("Empty", 0);
    CHECK(state.DeleteFolder(folder).empty());
    CHECK(state.Folders(0).empty() && state.archived.empty());
}

TEST(renamingAFolderIgnoresBlankNames) {
    auto [state, space, folder, tabs] = StateWithFolder();
    state.RenameFolder(folder, "  Work  ");
    auto match = state.FolderMatching(folder);
    CHECK(match && match->folder->name == "Work");
    state.RenameFolder(folder, "   ");
    match = state.FolderMatching(folder);
    CHECK(match && match->folder->name == "Work");
}

TEST(aTaskClosingItsLastTabTakesTheEmptyFolder) {
    BrowserState state = OneSpace();
    const std::string space = state.spaces[0].id;
    const std::string folder = state.CreateFolder("Task", 0);
    const std::string a = state.OpenTab("https://a.example", space, false);
    const std::string b = state.OpenTab("https://b.example", space, false);
    CHECK(state.MoveTabToFolder(a, folder) && state.MoveTabToFolder(b, folder));
    CHECK(state.RemovePinnedTab(a, true));
    CHECK(state.FolderMatching(folder).has_value());
    CHECK(state.RemovePinnedTab(b, true));
    CHECK(!state.FolderMatching(folder).has_value());
}

TEST(plainPinnedTabRemovalKeepsTheFolder) {
    BrowserState state = OneSpace();
    const std::string space = state.spaces[0].id;
    const std::string folder = state.CreateFolder("Mine", 0);
    const std::string a = state.OpenTab("https://a.example", space, false);
    CHECK(state.MoveTabToFolder(a, folder));
    CHECK(state.RemovePinnedTab(a));
    CHECK(state.FolderMatching(folder).has_value());
}

// MARK: TabRenameTests

TEST(aRenamedTabShowsItsNameAndKeepsItWhenThePageTitleChanges) {
    auto [state, id] = RenameState();
    state.RenameTab(id, "  Docs  ");
    CHECK(state.FindTabByID(id)->DisplayTitle() == "Docs");
    Find(state, id)->title = "A new page title";
    CHECK(state.FindTabByID(id)->DisplayTitle() == "Docs");
    CHECK(state.FindTabByID(id)->title == "A new page title");
}

TEST(anEmptyNameGoesBackToThePageTitle) {
    auto [state, id] = RenameState();
    state.RenameTab(id, "Docs");
    state.RenameTab(id, "   ");
    CHECK(!state.FindTabByID(id)->customTitle.has_value());
    CHECK(state.FindTabByID(id)->DisplayTitle() == "Example Domain");
}

TEST(pinnedTabsAndFavoritesRenameToo) {
    auto [state, id] = RenameState();
    state.TogglePin(id);
    state.RenameTab(id, "Pinned name");
    CHECK(!state.SelectedSpace().Pinned().empty() && state.SelectedSpace().Pinned().front()->DisplayTitle() == "Pinned name");
    Tab favorite;
    favorite.id = NewUuid();
    favorite.url = "https://mail.example.com";
    favorite.title = "Inbox (3)";
    state.SetFavorites({favorite});
    state.RenameTab(favorite.id, "Mail");
    CHECK(!state.Favorites().empty() && state.Favorites().front().DisplayTitle() == "Mail");
}

TEST(theNameSurvivesASaveAndOlderSessionsLoadWithout) {
    auto [state, id] = RenameState();
    state.RenameTab(id, "Docs");
    const auto decoded = RoundTrip(state);
    CHECK(decoded && decoded->FindTabByID(id) && decoded->FindTabByID(id)->customTitle == "Docs");
    auto parsed = json::Parse("{\"id\":\"" + NewUuid() + "\",\"title\":\"Old\",\"lastActiveAt\":0}");
    const auto tab = DecodeTab(std::get<json::Value>(parsed));
    CHECK(tab && !tab->customTitle && tab->DisplayTitle() == "Old");
}

TEST(duplicateKeepsTheName) {
    auto [state, id] = RenameState();
    state.RenameTab(id, "Docs");
    const auto copy = state.Duplicate(id);
    CHECK(copy && state.FindTabByID(*copy) && state.FindTabByID(*copy)->DisplayTitle() == "Docs");
}

// MARK: PinnedURLTests

TEST(pinningRemembersThePageAndUnpinningForgetsIt) {
    auto [state, id] = PinnedState();
    CHECK(state.FindTabByID(id)->pinnedURL == kHome);
    Find(state, id)->url = kAway;
    CHECK(state.FindTabByID(id)->pinnedURL == kHome);
    state.TogglePin(id);
    CHECK(!state.FindTabByID(id)->pinnedURL);
    // Pinning again pins the page it's on now.
    state.TogglePin(id);
    CHECK(state.FindTabByID(id)->pinnedURL == kAway);
}

TEST(favoritesKeepTheirPinnedURL) {
    auto [state, id] = PinnedState();
    state.ToggleFavorite(id);
    CHECK(!state.Favorites().empty() && state.Favorites().front().pinnedURL == kHome);
    state.ToggleFavorite(id);
    CHECK(!state.FindTabByID(id)->pinnedURL);
}

TEST(resetGoesBackToThePinnedPage) {
    auto [state, id] = PinnedState();
    CHECK(!state.CanReset(id));
    CHECK(!state.ResetTab(id));
    Find(state, id)->url = kAway;
    CHECK(state.CanReset(id));
    CHECK(state.ResetTab(id) == kHome);
    CHECK(state.FindTabByID(id)->url == kHome);
    CHECK(!state.CanReset(id));
}

TEST(redirectsAndAnchorsDontCountAsLeaving) {
    auto [state, id] = PinnedState();
    for (const char* url : {"http://www.mail.example.com/inbox/", "https://mail.example.com/inbox#unread", "HTTPS://Mail.Example.com/inbox"}) {
        Find(state, id)->url = url;
        if (state.CanReset(id)) std::fprintf(stderr, "  %s\n", url);
        CHECK(!state.CanReset(id));
    }
    Find(state, id)->url = "https://mail.example.com/inbox?q=x";
    CHECK(state.CanReset(id));
}

TEST(unpinnedTabsCantReset) {
    BrowserState state = OneSpace();
    const std::string id = state.OpenTab(kHome);
    Find(state, id)->url = kAway;
    CHECK(!state.CanReset(id));
    CHECK(!state.ResetTab(id));
}

TEST(resetAllTabsResetsPinnedTabsInTheCurrentSpaceOnly) {
    auto [state, id] = PinnedState();
    const std::string folder = state.CreateFolder("F", 0);
    const std::string inFolder = state.OpenTab("https://docs.example");
    state.TogglePin(inFolder);
    state.MoveTabToFolder(inFolder, folder);
    const std::string unpinned = state.OpenTab(kHome);
    const std::string other = state.AddSpace("Other", "x", Theme::Presets()[1]);
    const std::string elsewhere = state.OpenTab(kHome, other);
    state.TogglePin(elsewhere);
    for (const std::string& tab : {id, inFolder, unpinned, elsewhere}) Find(state, tab)->url = kAway;
    state.SelectSpace(state.spaces[0].id);
    const auto reset = state.ResetPinnedTabs();
    std::set<std::string> ids;
    for (const auto& [tab, url] : reset) ids.insert(tab);
    CHECK(ids == (std::set<std::string>{id, inFolder}));
    CHECK(state.FindTabByID(inFolder)->url == "https://docs.example");
    CHECK(state.FindTabByID(unpinned)->url == kAway);
    CHECK(state.FindTabByID(elsewhere)->url == kAway);
}

TEST(separateOpensTheAwayPageAsANewTab) {
    auto [state, id] = PinnedState();
    Find(state, id)->url = kAway;
    const auto separated = state.SeparateFromPinnedTab(id);
    CHECK(separated.has_value());
    CHECK(state.FindTabByID(id)->url == kHome);
    CHECK(separated && state.FindTabByID(*separated)->url == kAway);
    CHECK(separated && state.Location(*separated)->section == TabSection::Unpinned);
    CHECK(separated && state.SelectedSpace().selectedTabID == *separated);
}

TEST(oldSessionsAdoptTheCurrentPage) {
    BrowserState state = OneSpace();
    Tab tab;
    tab.id = NewUuid();
    tab.url = kHome;
    state.spaces[0].pinnedItems = {PinnedItem{tab}};
    const std::string data = json::Write(Encode(state));
    CHECK(data.find("pinnedURL") == std::string::npos);
    auto parsed = json::Parse(data);
    const auto decoded = DecodeBrowserState(std::get<json::Value>(parsed));
    CHECK(decoded && !decoded->spaces[0].Pinned().empty() && decoded->spaces[0].Pinned().front()->pinnedURL == kHome);
}

TEST(revealOpensEnclosingFoldersAndNamesTheRow) {
    BrowserState state = OneSpace();
    const std::string outer = state.CreateFolder("Outer", 0);
    const std::string inner = state.CreateFolder("Inner", 0);
    const std::string id = state.OpenTab(kHome);
    state.MoveTabToFolder(id, inner);
    auto& items = state.spaces[0].pinnedItems;
    PinnedItem taken = std::move(items[1]);
    items.erase(items.begin() + 1);
    std::get<Folder>(items[0].value).items.push_back(std::move(taken));
    state.SetFolderExpanded(outer, false);
    state.SetFolderExpanded(inner, false);
    CHECK(state.RevealTab(id) == outer);
    const auto folders = state.Folders(0);
    CHECK(std::all_of(folders.begin(), folders.end(), [](const Folder* f) { return f->isExpanded; }));
    const std::string loose = state.OpenTab(kAway);
    CHECK(state.RevealTab(loose) == loose);
}

TEST(editPinnedURLTakesAURLButNotASearch) {
    auto [state, id] = PinnedState();
    CHECK(state.HasPinnedURL(id));
    CHECK(!state.EditPinnedURL(id, "not a url"));
    CHECK(!state.EditPinnedURL(id, "  "));
    CHECK(state.FindTabByID(id)->pinnedURL == kHome);
    CHECK(state.EditPinnedURL(id, " calendar.example.com/week "));
    CHECK(state.FindTabByID(id)->pinnedURL == "https://calendar.example.com/week");
    // The page stays where it is, now away from its pinned URL.
    CHECK(state.FindTabByID(id)->url == kHome);
    CHECK(state.CanReset(id));
    CHECK(state.EditPinnedURL(id, "https://mail.example.com/inbox"));
    CHECK(!state.CanReset(id));
}

TEST(replacePinnedURLWithCurrentPinsThePageItsOn) {
    auto [state, id] = PinnedState();
    Find(state, id)->url = kAway;
    CHECK(state.ReplacePinnedURLWithCurrent(id));
    CHECK(state.FindTabByID(id)->pinnedURL == kAway);
    CHECK(!state.CanReset(id));
}

TEST(favoritesCanEditAndReplaceButUnpinnedTabsCant) {
    auto [state, id] = PinnedState();
    state.ToggleFavorite(id);
    const std::string fav = state.Favorites()[0].id;
    CHECK(state.EditPinnedURL(fav, "example.org"));
    CHECK(state.Favorites()[0].pinnedURL == "https://example.org");
    CHECK(state.ReplacePinnedURLWithCurrent(fav));
    CHECK(state.Favorites()[0].pinnedURL == kHome);
    const std::string loose = state.OpenTab(kAway);
    CHECK(!state.HasPinnedURL(loose));
    CHECK(!state.EditPinnedURL(loose, "example.org"));
    CHECK(!state.ReplacePinnedURLWithCurrent(loose));
    CHECK(!state.FindTabByID(loose)->pinnedURL);
}

// MARK: Edge cases the Mac doesn't check

TEST(pinningAppendsAfterFoldersAndUnpinningFromAFolderGoesToTodaysTop) {
    // Pinned items end with the new pin, after any folder; a tab unpinned from inside a nested
    // folder lands on top of Today, above the tabs already there.
    auto [state, space, folder, tabs] = StateWithFolder();
    const std::string loose = state.OpenTab("https://loose.example", space, false);
    const std::string other = state.OpenTab("https://other.example", space, false);
    state.TogglePin(loose);
    CHECK(state.spaces[0].pinnedItems.back().Id() == loose);
    state.TogglePin(tabs[1]);  // b, inside Reading › Inner
    CHECK(state.spaces[0].tabs.front().id == tabs[1]);
    CHECK(state.spaces[0].tabs[1].id == other);
    CHECK(!state.FindTabByID(tabs[1])->pinnedURL);
}

TEST(togglingPinOnAFavoriteOrAnUnknownTabDoesNothing) {
    auto [state, id] = PinnedState();
    state.ToggleFavorite(id);
    const BrowserState before = state;
    state.TogglePin(id);
    state.TogglePin(NewUuid());
    CHECK(state == before);
}

TEST(syncSkipsKitePagesAndBlankPagesAndAdoptsLater) {
    // A pinned tab on kite://history or about:blank has no pinned page until it reaches a real one.
    BrowserState state = OneSpace();
    const std::string history = state.OpenTab("kite://history");
    const std::string blank = state.OpenTab("about:blank");
    state.TogglePin(history);
    state.TogglePin(blank);
    CHECK(!state.FindTabByID(history)->pinnedURL && !state.FindTabByID(blank)->pinnedURL);
    CHECK(!state.CanReset(history));
    Find(state, blank)->url = "https://example.com/";
    state.SyncPinnedURLs();
    CHECK(state.FindTabByID(blank)->pinnedURL == "https://example.com/");
    CHECK(!state.ReplacePinnedURLWithCurrent(history));
}

TEST(samePageKeepsPortsQueriesAndOtherSchemesApart) {
    CHECK(Tab::SamePage("https://example.com", "https://example.com/"));
    CHECK(Tab::SamePage("https://user@WWW.Example.com:8080/a//", "http://user@example.com:8080/a#x"));
    CHECK(!Tab::SamePage("https://example.com:8080/", "https://example.com/"));
    CHECK(!Tab::SamePage("https://example.com/a?b=1", "https://example.com/a?b=2"));
    CHECK(!Tab::SamePage("ftp://example.com/", "https://example.com/"));
    CHECK(!Tab::SamePage("https://Example.com/Path", "https://example.com/path"));
    CHECK(Tab::SamePage("about:blank", "about:blank"));
    CHECK(!Tab::SamePage("mailto:a@example.com", "mailto:b@example.com"));
}

TEST(duplicatingAFavoriteOrAPinnedTabGoesToTodaysTop) {
    auto [state, id] = PinnedState();
    const std::string today = state.OpenTab("https://today.example");
    const auto pinnedCopy = state.Duplicate(id, 5);
    CHECK(pinnedCopy && state.spaces[0].tabs.front().id == *pinnedCopy);
    CHECK(pinnedCopy && !state.FindTabByID(*pinnedCopy)->pinnedURL && state.FindTabByID(*pinnedCopy)->lastActiveAt == 5);
    state.ToggleFavorite(today);
    const std::string other = state.AddSpace("Other", "x", Theme::Presets()[1]);
    const auto favoriteCopy = state.Duplicate(today);
    CHECK(favoriteCopy && state.SelectedSpace().id == other && state.SelectedSpace().tabs.front().id == *favoriteCopy);
    CHECK(!state.Duplicate(NewUuid()));
}

TEST(movingATabToAFolderInAnotherSpaceMovesTheSelection) {
    BrowserState state = OneSpace();
    const std::string first = state.spaces[0].id;
    const std::string a = state.OpenTab("https://a.example");
    const std::string b = state.OpenTab("https://b.example");
    const std::string other = state.AddSpace("Other", "x", Theme::Presets()[1]);
    const std::string folder = state.CreateFolder("There", *state.SpaceIndex(other));
    CHECK(state.spaces[0].selectedTabID == b);
    CHECK(state.MoveTabToFolder(b, folder));
    CHECK(state.spaces[0].selectedTabID == a);
    CHECK(state.Location(b)->space == state.SpaceIndex(other) && state.Location(b)->section == TabSection::Pinned);
    CHECK(!state.MoveTabToFolder(b, NewUuid()));
    state.ToggleFavorite(a);
    CHECK(!state.MoveTabToFolder(a, folder));
    CHECK(state.SpaceIndex(first) == 0u);
}

TEST(folderMatchingTakesIdsAndNamesInAnyCaseSelectedSpaceFirst) {
    BrowserState state = OneSpace();
    const std::string here = state.CreateFolder("Reading", 0);
    const std::string other = state.AddSpace("Other", "x", Theme::Presets()[1]);
    const std::string there = state.CreateFolder("reading", *state.SpaceIndex(other));
    std::string lowered = here;
    for (char& c : lowered) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    CHECK(state.FolderMatching(lowered) && state.FolderMatching(lowered)->folder->id == here);
    // Other is selected (AddSpace selects it): its "reading" comes first.
    CHECK(state.FolderMatching(" READING ") && state.FolderMatching(" READING ")->folder->id == there);
    state.SelectSpaceAt(0);
    CHECK(state.FolderMatching("READING") && state.FolderMatching("READING")->folder->id == here);
    CHECK(!state.FolderMatching("Nothing"));
    CHECK(FolderNames(state, 0) == std::vector<std::string>{"Reading"});
}

TEST(aRenamedRowShowsItsNameInTheSidebar) {
    auto [state, id] = RenameState();
    state.RenameTab(id, "Docs");
    const auto rows = SidebarRows(state, 0);
    const auto tab = std::find_if(rows.begin(), rows.end(), [&](const SidebarRow& r) { return r.id == id; });
    CHECK(tab != rows.end() && tab->title == "Docs");
}

TEST(deletingAFolderInAnotherSpaceArchivesWithThatSpace) {
    BrowserState state = OneSpace();
    const std::string other = state.AddSpace("Other", "x", Theme::Presets()[1]);
    const std::string folder = state.CreateFolder("There", 1);
    const std::string a = state.OpenTab("https://a.example", other);
    state.MoveTabToFolder(a, folder);
    state.SelectSpaceAt(0);
    const auto archived = state.DeleteFolder(folder);
    CHECK(Ids(archived) == std::vector<std::string>{a});
    CHECK(!state.archived.empty() && state.archived.back().spaceID == other && state.archived.back().reason == ArchiveReason::Manual);
    CHECK(!state.spaces[1].selectedTabID);
}
