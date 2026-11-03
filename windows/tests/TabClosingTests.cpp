// Ports of KiteCore's closing, archiving and reopening tests: KiteCoreTests.swift
// (BrowserStateTests, FolderTests, FavoritesTests), ArchiveTests.swift, UndoArchiveTests.swift
// and SplitViewTests.swift's closing cases, plus edge cases the Mac doesn't check.

#include <algorithm>
#include <cmath>

#include "Check.h"
#include "core/Models.h"
#include "core/Uuid.h"

using namespace kite;

namespace {

Tab MakeTab(std::string url, Timestamp lastActive = 0) {
    Tab tab;
    tab.id = NewUuid();
    tab.url = std::move(url);
    tab.lastActiveAt = lastActive;
    return tab;
}

Folder MakeFolder(std::string name, std::vector<PinnedItem> items, bool ephemeral = false) {
    Folder folder;
    folder.id = NewUuid();
    folder.name = std::move(name);
    folder.items = std::move(items);
    if (ephemeral) folder.ephemeral = true;
    return folder;
}

// One space, as the Mac's BrowserState(spaces: [Space(name: "A", ...)]).
BrowserState OneSpace() {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    state.spaces.resize(1);
    state.selectedSpaceID = state.spaces[0].id;
    return state;
}

// KiteCoreTests.makeState(tabs:): N unpinned tabs opened one after another; ids in sidebar
// order (openTab puts each on top), the last opened (ids[0]) selected.
std::pair<BrowserState, std::vector<std::string>> MakeState(int tabs) {
    BrowserState state = OneSpace();
    std::vector<std::string> ids;
    for (int i = 0; i < tabs; ++i) ids.push_back(state.OpenTab("https://site" + std::to_string(i) + ".com"));
    std::reverse(ids.begin(), ids.end());
    return {state, ids};
}

// Moves an unpinned tab to the end of the pinned section (togglePin for an unpinned tab).
void Pin(BrowserState& state, const std::string& id) {
    for (Space& space : state.spaces) {
        auto it = std::find_if(space.tabs.begin(), space.tabs.end(), [&](const Tab& t) { return t.id == id; });
        if (it == space.tabs.end()) continue;
        Tab tab = std::move(*it);
        tab.splitPane.reset();
        space.tabs.erase(it);
        space.pinnedItems.push_back(PinnedItem{std::move(tab)});
        return;
    }
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

std::vector<std::string> ArchivedIds(const BrowserState& state) {
    std::vector<std::string> out;
    for (const ClosedTab& closed : state.archived) out.push_back(closed.tab.id);
    return out;
}

std::string SelectedID(const BrowserState& state) {
    const Tab* tab = state.SelectedTab();
    return tab ? tab->id : std::string();
}

SplitView MakeSplit(std::vector<std::string> ids) {
    SplitView split;
    split.id = NewUuid();
    split.widthFactors.assign(ids.size(), 1.0 / static_cast<double>(ids.size()));
    split.tabIDs = std::move(ids);
    return split;
}

}  // namespace

// MARK: BrowserStateTests (KiteCoreTests.swift)

TEST(closingSelectedTabSelectsTheNextOne) {
    auto [state, ids] = MakeState(3);
    state.Select(ids[1]);
    CHECK(state.Close(ids[1]) == CloseOutcome::Removed);
    CHECK(SelectedID(state) == ids[2]);
    CHECK(state.Close(ids[2]) == CloseOutcome::Removed);
    CHECK(SelectedID(state) == ids[0]);
    CHECK(state.Close(ids[0]) == CloseOutcome::Removed);
    CHECK(state.SelectedTab() == nullptr);
    CHECK(!state.spaces[0].selectedTabID);
}

TEST(closingPinnedTabUnloadsIt) {
    auto [state, ids] = MakeState(2);
    Pin(state, ids[0]);
    state.Select(ids[0]);
    CHECK(state.Close(ids[0]) == CloseOutcome::Unloaded);
    CHECK(Ids(state.SelectedSpace().Pinned()) == std::vector<std::string>{ids[0]});
    CHECK(SelectedID(state) == ids[1]);
    // An unloaded tab is still a row: nothing to reopen or find in the archive.
    CHECK(state.recentlyClosed.empty() && state.archived.empty());
}

TEST(reopenRestoresPosition) {
    auto [state, ids] = MakeState(3);
    state.Close(ids[1]);
    const auto reopened = state.ReopenLastClosed();
    CHECK(reopened == ids[1]);
    CHECK(Ids(state.SelectedSpace().tabs) == ids);
    CHECK(state.recentlyClosed.empty());
    CHECK(SelectedID(state) == ids[1]);
}

TEST(archivesOnlyStaleUnpinnedUnselectedTabs) {
    BrowserState state = OneSpace();
    const Timestamp old = FromUnixTime(0);
    const std::string stale = state.OpenTab(std::nullopt, std::nullopt, false, old);
    const std::string pinned = state.OpenTab(std::nullopt, std::nullopt, false, old);
    Pin(state, pinned);
    const std::string selected = state.OpenTab(std::nullopt, std::nullopt, true, old);
    const std::string fresh = state.OpenTab(std::nullopt, std::nullopt, false);

    const auto archived = state.ArchiveStaleTabs(3600);
    CHECK(Ids(archived) == std::vector<std::string>{stale});
    CHECK(state.FindTabByID(pinned) && state.FindTabByID(selected) && state.FindTabByID(fresh) && !state.FindTabByID(stale));
    CHECK(ArchivedIds(state) == std::vector<std::string>{stale});
    // Auto-archived tabs aren't in Recently Closed: Ctrl+Shift+T doesn't bring them back.
    CHECK(state.recentlyClosed.empty());
}

TEST(closingArchivesUntilReopened) {
    BrowserState state = OneSpace();
    const std::string tab = state.OpenTab("https://example.com");
    state.Close(tab);
    CHECK(ArchivedIds(state) == std::vector<std::string>{tab});
    state.ReopenLastClosed();
    CHECK(state.archived.empty());
}

TEST(archiveIntervalDefaultsToTwelveHoursAndPersists) {
    BrowserState state = OneSpace();
    CHECK(state.archiveAfter == "twelveHours");
    CHECK(state.ArchiveAfterSeconds() == 12 * 3600.0);
    state.archiveAfter = "sevenDays";
    auto decoded = DecodeBrowserState(Encode(state));
    CHECK(decoded && decoded->archiveAfter == "sevenDays");
    CHECK(decoded->ArchiveAfterSeconds() == 7 * 24 * 3600.0);
    // ArchiveInterval's decoder: the first version's names, and twelve hours for anything else.
    auto withAfter = [&](const char* raw) {
        json::Value encoded = Encode(state);
        encoded.AsObject()->insert_or_assign("archiveAfter", json::Value(std::string(raw)));
        auto again = DecodeBrowserState(encoded);
        return again ? again->archiveAfter : std::string("(failed)");
    };
    CHECK(withAfter("day") == "twentyFourHours");
    CHECK(withAfter("week") == "sevenDays");
    CHECK(withAfter("month") == "thirtyDays");
    CHECK(withAfter("fortnight") == "twelveHours");
    CHECK(withAfter("never") == "never");
    state.archiveAfter = "never";
    CHECK(!state.ArchiveAfterSeconds());
}

// MARK: FolderTests, FavoritesTests (KiteCoreTests.swift)

TEST(tabsInsideFoldersCloseLikePinnedTabs) {
    BrowserState state = OneSpace();
    Tab inner = MakeTab("https://inner.example"), deep = MakeTab("https://deep.example");
    state.spaces[0].pinnedItems = {PinnedItem{MakeFolder("Work", {PinnedItem{inner}, PinnedItem{MakeFolder("Deep", {PinnedItem{deep}})}})}};
    state.Select(deep.id);
    CHECK(state.Close(deep.id) == CloseOutcome::Unloaded);
    CHECK(SelectedID(state) == inner.id);
    CHECK(Ids(state.SelectedSpace().Pinned()) == (std::vector<std::string>{inner.id, deep.id}));
}

TEST(closingAFavoriteUnloadsIt) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    Tab mail = MakeTab("https://mail.example");
    state.SetFavorites({mail});
    state.SelectSpace(state.spaces[1].id);
    state.Select(mail.id);
    CHECK(SelectedID(state) == mail.id);
    CHECK(state.Close(mail.id) == CloseOutcome::Unloaded);
    CHECK(state.Favorites().size() == 1);
    CHECK(state.SelectedTab() == nullptr);
}

// MARK: ArchiveTests.swift

TEST(closingAndAutoArchivingStampDateAndReason) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const Timestamp now = FromUnixTime(1'799'995'200);
    const std::string space = state.spaces[0].id;
    const std::string closed = state.OpenTab("https://a.example", space, false);
    state.Close(closed);
    const std::string stale = state.OpenTab("https://b.example", space, false, now - 7200);
    state.ArchiveStaleTabs(3600, now);
    CHECK(state.archived.size() == 2);
    CHECK(state.archived[0].reason == ArchiveReason::Manual && state.archived[1].reason == ArchiveReason::Auto);
    CHECK(state.archived[1].tab.id == stale && state.archived[1].archivedAt == now);
    CHECK(std::all_of(state.archived.begin(), state.archived.end(), [](const ClosedTab& c) { return c.archivedAt.has_value(); }));
}

TEST(claudeFolderArchivesStaleTabsAndGoesWhenEmpty) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const Timestamp now = FromUnixTime(1'799'995'200);
    Tab stale = MakeTab("https://jlcpcb.example", now - 7200), fresh = MakeTab("https://eink.example", now);
    Tab old = MakeTab("https://kept.example", now - 7200);
    Folder claude = MakeFolder("Claude", {PinnedItem{stale}, PinnedItem{fresh}}, true);
    Folder kept = MakeFolder("Parts", {PinnedItem{old}});
    Space& work = state.spaces[1];
    work.pinnedItems = {PinnedItem{claude}, PinnedItem{kept}};

    state.ArchiveStaleTabs(3600, now);
    CHECK(ArchivedIds(state) == std::vector<std::string>{stale.id});
    CHECK(state.archived.back().spaceID == state.spaces[1].id);
    CHECK(Ids(TabsIn(std::get<Folder>(state.spaces[1].pinnedItems[0].value).items)) == std::vector<std::string>{fresh.id});
    CHECK(state.FindTabByID(old.id));

    state.spaces[1].pinnedItems[0] = PinnedItem{[&] {
        Folder f = std::get<Folder>(state.spaces[1].pinnedItems[0].value);
        std::get<Tab>(f.items[0].value).lastActiveAt = now - 7200;
        return f;
    }()};
    state.ArchiveStaleTabs(3600, now);
    // The Claude folder went with its last tab; the ordinary folder stayed.
    CHECK(state.spaces[1].pinnedItems.size() == 1);
    CHECK(std::get<Folder>(state.spaces[1].pinnedItems[0].value).id == kept.id);
}

// MARK: UndoArchiveTests.swift

TEST(reopensTheTabUndoNamesNotJustTheLast) {
    BrowserState state = BrowserState::MakeDefault();
    const std::string a = state.OpenTab("https://a.com");
    const std::string b = state.OpenTab("https://b.com");
    const auto& tabs = state.SelectedSpace().tabs;
    const size_t indexOfA = static_cast<size_t>(std::find_if(tabs.begin(), tabs.end(), [&](const Tab& t) { return t.id == a; }) - tabs.begin());
    state.Close(a);
    state.Close(b);
    CHECK(state.ReopenClosed(a) == a);
    // Back where it was (b is still closed), selected, and out of the archive.
    const auto& after = state.SelectedSpace().tabs;
    const size_t now = static_cast<size_t>(std::find_if(after.begin(), after.end(), [&](const Tab& t) { return t.id == a; }) - after.begin());
    CHECK(now == std::min(indexOfA, after.size() - 1));
    CHECK(SelectedID(state) == a);
    CHECK(std::none_of(state.archived.begin(), state.archived.end(), [&](const ClosedTab& c) { return c.tab.id == a; }));
    CHECK(state.recentlyClosed.size() == 1 && state.recentlyClosed[0].tab.id == b);
    // Already open: nothing to undo.
    CHECK(!state.ReopenClosed(a));
    CHECK(state.ReopenLastClosed() == b);
}

// MARK: SplitViewTests.swift, closing

TEST(closingAPaneFocusesItsNeighbourAndALastPaneEndsTheSplit) {
    auto [state, ids] = MakeState(3);
    // addSplitPane: an empty pane right under the selected tab, selected, in a split with it.
    Tab pane;
    pane.id = NewUuid();
    auto& tabs = state.spaces[0].tabs;
    tabs.insert(tabs.begin() + 1, pane);
    state.spaces[0].splits = {MakeSplit({ids[0], pane.id})};
    state.Select(pane.id);
    state.Close(pane.id);
    CHECK(SelectedID(state) == ids[0]);
    CHECK(state.spaces[0].splits.empty());
}

TEST(closingTheFirstPaneFocusesTheOneAfterIt) {
    auto [state, ids] = MakeState(3);
    state.spaces[0].splits = {MakeSplit({ids[0], ids[1], ids[2]})};
    state.Select(ids[0]);
    state.Close(ids[0]);
    CHECK(SelectedID(state) == ids[1]);
    CHECK(state.spaces[0].splits.size() == 1 && state.spaces[0].splits[0].tabIDs == (std::vector<std::string>{ids[1], ids[2]}));
    state.Select(ids[2]);
    state.Close(ids[2]);
    CHECK(SelectedID(state) == ids[1]);
    CHECK(state.spaces[0].splits.empty());
}

TEST(closingAnEmptyPaneNextToAClaudeTabRemovesIt) {
    BrowserState state = OneSpace();
    Tab tab = MakeTab("https://app.blacksmith.sh");
    tab.pinnedURL = tab.url;
    Tab pane;
    pane.id = NewUuid();
    pane.url = "about:blank";
    pane.splitPane = true;
    Folder session = MakeFolder("Blacksmith", {PinnedItem{tab}, PinnedItem{pane}}, true);
    state.spaces[0].pinnedItems = {PinnedItem{MakeFolder("Claude", {PinnedItem{session}}, true)}};
    state.spaces[0].splits = {MakeSplit({tab.id, pane.id})};
    state.Select(pane.id);
    CHECK(state.IsInEphemeralFolder(pane.id));
    CHECK(state.Close(pane.id) == CloseOutcome::Removed);
    CHECK(!state.FindTabByID(pane.id) && state.FindTabByID(tab.id));
    CHECK(state.spaces[0].splits.empty());
    CHECK(SelectedID(state) == tab.id);
    // A pane that never had a page isn't worth reopening.
    CHECK(state.recentlyClosed.empty() && state.archived.empty());
    // The Claude folder's real tab still only unloads.
    CHECK(state.Close(tab.id) == CloseOutcome::Unloaded);
}

TEST(closingAPaneThatLoadedAPageNextToAClaudeTabRemovesIt) {
    BrowserState state = OneSpace();
    Tab tab = MakeTab("https://app.blacksmith.sh");
    tab.pinnedURL = tab.url;
    Tab pane = MakeTab("https://www.google.com/search?q=test");
    pane.pinnedURL = pane.url;
    pane.splitPane = true;
    Folder session = MakeFolder("Blacksmith", {PinnedItem{tab}, PinnedItem{pane}}, true);
    state.spaces[0].pinnedItems = {PinnedItem{MakeFolder("Claude", {PinnedItem{session}}, true)}};
    state.spaces[0].splits = {MakeSplit({tab.id, pane.id})};
    state.Select(pane.id);
    CHECK(!state.ShowsCloseButton(tab.id));
    CHECK(state.ShowsCloseButton(pane.id));
    CHECK(state.Close(pane.id) == CloseOutcome::Removed);
    CHECK(!state.FindTabByID(pane.id) && state.FindTabByID(tab.id));
    CHECK(ArchivedIds(state) == std::vector<std::string>{pane.id});
    CHECK(state.ReopenLastClosed() == pane.id);
    CHECK(Ids(state.spaces[0].tabs) == std::vector<std::string>{pane.id});
    CHECK(!state.FindTabByID(pane.id)->splitPane);
}

TEST(closingAStrandedBlankPinnedTabRemovesIt) {
    // An empty pane out of its split, pinned at about:blank, alone in Claude › Blacksmith.
    BrowserState state = OneSpace();
    Tab blank = MakeTab("about:blank");
    blank.pinnedURL = "about:blank";
    state.spaces[0].pinnedItems = {PinnedItem{MakeFolder("Claude", {PinnedItem{MakeFolder("Blacksmith", {PinnedItem{blank}}, true)}}, true)}};
    CHECK(state.Close(blank.id) == CloseOutcome::Removed);
    CHECK(!state.FindTabByID(blank.id));
    // It was the folder's only tab, so Claude › Blacksmith and Claude go with it.
    CHECK(state.spaces[0].pinnedItems.empty());
}

TEST(closingTheExpandedPaneShowsTheRest) {
    auto [state, ids] = MakeState(3);
    SplitView split = MakeSplit({ids[0], ids[1], ids[2]});
    split.widthFactors = {0.5, 0.25, 0.25};
    split.expandedTabID = ids[1];
    state.spaces[0].splits = {split};
    state.Select(ids[1]);
    state.Close(ids[1]);
    const SplitView& left = state.spaces[0].splits.at(0);
    CHECK(!left.expandedTabID);
    // The closed pane's share goes to the others in proportion.
    CHECK(left.tabIDs == (std::vector<std::string>{ids[0], ids[2]}));
    CHECK(std::abs(left.widthFactors[0] - 2.0 / 3) < 1e-9 && std::abs(left.widthFactors[1] - 1.0 / 3) < 1e-9);
}

// MARK: Beyond the Mac's tests

TEST(closingAnUnknownTabDoesNothing) {
    auto [state, ids] = MakeState(2);
    const BrowserState before = state;
    CHECK(state.Close("no-such-tab") == CloseOutcome::NotFound);
    CHECK(state == before);
    CHECK(!state.ReopenLastClosed());
    CHECK(!state.ReopenClosed(ids[0]));
}

TEST(closingAnUnselectedTabKeepsTheSelection) {
    auto [state, ids] = MakeState(3);
    state.Select(ids[2]);
    state.Close(ids[0]);
    CHECK(SelectedID(state) == ids[2]);
    CHECK(state.recentlyClosed.back().index == 0);
}

TEST(recentlyClosedAndTheArchiveKeepOnlyTheNewest) {
    BrowserState state = OneSpace();
    std::vector<std::string> closed;
    for (int i = 0; i < 30; ++i) {
        closed.push_back(state.OpenTab("https://t" + std::to_string(i) + ".example"));
        state.Close(closed.back());
    }
    CHECK(state.recentlyClosed.size() == BrowserState::kRecentlyClosedLimit);
    CHECK(state.recentlyClosed.front().tab.id == closed[5] && state.recentlyClosed.back().tab.id == closed[29]);
    std::vector<ClosedTab> many;
    for (int i = 0; i < 600; ++i) many.push_back(ClosedTab{MakeTab("https://a.example"), state.spaces[0].id, 0, std::nullopt, std::nullopt, std::nullopt, {}});
    const std::string newest = many.back().tab.id;
    state.AppendToArchive(std::move(many));
    CHECK(state.archived.size() == BrowserState::kArchiveLimit);
    CHECK(state.archived.back().tab.id == newest);
}

TEST(aReopenedTabGoesBackToItsSpaceOrTheCurrentOne) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const std::string work = state.spaces[1].id;
    const std::string tab = state.OpenTab("https://work.example", work, false);
    state.Close(tab);
    // Back in Work, which comes forward.
    CHECK(state.ReopenLastClosed() == tab);
    CHECK(state.selectedSpaceID == work && SelectedID(state) == tab);
    // Its space is gone: it comes back in the current one, at the top if it was further down.
    state.Close(tab);
    state.recentlyClosed.back().index = 99;
    state.spaces.erase(state.spaces.begin() + 1);
    state.selectedSpaceID = state.spaces[0].id;
    state.OpenTab("https://home.example");
    CHECK(state.ReopenLastClosed() == tab);
    CHECK(state.spaces[0].tabs.back().id == tab && SelectedID(state) == tab);
}

TEST(aPopupThatClosesItselfHandsTheScreenBackToItsOpener) {
    auto [state, ids] = MakeState(3);
    state.Select(ids[2]);
    const std::string popup = state.OpenTab("https://accounts.example/signin");
    // On screen: back to the tab that opened it, not the neighbour Close would pick.
    state.PageClosedItself(popup, ids[2]);
    CHECK(!state.FindTabByID(popup));
    CHECK(SelectedID(state) == ids[2]);
    // Its opener gone too: Close's choice stands.
    const std::string orphan = state.OpenTab("https://accounts.example/signin");
    state.PageClosedItself(orphan, std::string("gone"));
    CHECK(SelectedID(state) == ids[0]);
    // Not on screen: the selection stays.
    const std::string background = state.OpenTab("https://accounts.example/signin", std::nullopt, false);
    state.Select(ids[1]);
    state.PageClosedItself(background, ids[2]);
    CHECK(SelectedID(state) == ids[1] && !state.FindTabByID(background));
    // A pinned tab's page closing itself only unloads it.
    Pin(state, ids[1]);
    state.PageClosedItself(ids[1], std::nullopt);
    CHECK(state.FindTabByID(ids[1]));
}

TEST(splitsKeepOnlyLiveMembersInOneSplitEach) {
    auto [state, ids] = MakeState(4);
    state.spaces[0].splits = {MakeSplit({ids[0], ids[1], "gone"}), MakeSplit({ids[1], ids[2]}), MakeSplit({ids[2], ids[3]})};
    state.NormalizeSplits();
    // The first keeps its two live panes. The second loses ids[1] (taken) and with one pane
    // left ends, but still claims ids[2] (normalizeSplits claims before it counts), so the
    // third loses it and ends too.
    CHECK(state.spaces[0].splits.size() == 1);
    CHECK(state.spaces[0].splits[0].tabIDs == (std::vector<std::string>{ids[0], ids[1]}));
    // Favorite splits: by profile, dropped once empty.
    Tab a = MakeTab("https://a.example"), b = MakeTab("https://b.example");
    state.SetFavorites({a, b});
    state.favoriteSplitsByProfile[BrowserState::kDefaultProfile] = {MakeSplit({a.id, b.id})};
    CHECK(state.SplitContaining(b.id));
    state.Close(b.id);  // unloads, and leaves the split
    CHECK(state.favoriteSplitsByProfile.empty());
}

TEST(aSplitLosingPanesGivesTheirWidthToTheRest) {
    auto [state, ids] = MakeState(2);
    SplitView split = MakeSplit({ids[0], "gone", ids[1], "gone too"});
    split.widthFactors = {0.4, 0.2, 0.2, 0.2};
    split.expandedTabID = "gone";
    state.spaces[0].splits = {split};
    state.NormalizeSplits();
    const SplitView& kept = state.spaces[0].splits.at(0);
    CHECK(kept.tabIDs == (std::vector<std::string>{ids[0], ids[1]}));
    CHECK(kept.widthFactors.size() == 2 && std::abs(kept.widthFactors[0] - 2.0 / 3) < 1e-12 &&
          std::abs(kept.widthFactors[1] - 1.0 / 3) < 1e-12);
    CHECK(!kept.expandedTabID);
    // One that loses nothing keeps its factors as written.
    state.spaces[0].splits[0].widthFactors = {3, 1};
    state.NormalizeSplits();
    CHECK(state.spaces[0].splits[0].widthFactors == (std::vector<double>{3, 1}));
}

// Ctrl+W passes the selected tab's own id, which closing moves and erases.
TEST(closingTheSelectedTabByItsOwnIdSelectsTheNextOne) {
    auto [state, ids] = MakeState(3);
    state.Select(ids[1]);
    CHECK(state.Close(state.SelectedTab()->id) == CloseOutcome::Removed);
    CHECK(SelectedID(state) == ids[2]);
    CHECK(!state.FindTabByID(ids[1]));
    CHECK(state.recentlyClosed.back().tab.id == ids[1]);
    // The last one: the one above.
    CHECK(state.Close(state.SelectedTab()->id) == CloseOutcome::Removed);
    CHECK(SelectedID(state) == ids[0]);
    // And back, by the closed entry's own id.
    CHECK(state.ReopenClosed(state.recentlyClosed.back().tab.id) == ids[2]);
    CHECK(SelectedID(state) == ids[2]);
}

TEST(closingASelectedBlankPinnedTabOrFavoriteByItsOwnIdRemovesIt) {
    auto [state, ids] = MakeState(1);
    Tab blank = MakeTab("about:blank");
    state.spaces[0].pinnedItems = {PinnedItem{blank}};
    state.Select(blank.id);
    CHECK(state.Close(state.SelectedTab()->id) == CloseOutcome::Removed);
    CHECK(!state.FindTabByID(blank.id));
    CHECK(SelectedID(state) == ids[0]);

    Tab empty = MakeTab("about:blank");
    Tab mail = MakeTab("https://mail.example");
    state.SetFavorites({empty, mail});
    state.Select(empty.id);
    CHECK(state.Close(state.SelectedTab()->id) == CloseOutcome::Removed);
    CHECK(state.Favorites().size() == 1 && state.Favorites()[0].id == mail.id);
    CHECK(SelectedID(state) == mail.id);
}

TEST(closedTabsAndSplitsRoundTripTheMacsJSON) {
    auto [state, ids] = MakeState(3);
    state.spaces[0].splits = {MakeSplit({ids[0], ids[1]})};
    state.spaces[0].splits[0].orientation = "vertical";
    state.spaces[0].splits[0].expandedTabID = ids[1];
    state.Close(ids[2]);
    state.recentlyClosed[0].littleKite = true;
    state.recentlyClosed[0].extra.emplace("future", json::Value(1.0));
    state.archived[0].littleKite = true;
    const json::Value encoded = Encode(state);
    const json::Value* closed = encoded.Find("recentlyClosed");
    CHECK(closed && closed->AsArray() && closed->AsArray()->size() == 1);
    const json::Value& entry = (*closed->AsArray())[0];
    CHECK(entry.Find("index") && entry.Find("index")->AsNumber() == 2.0);
    // Recently Closed keeps the tab as it closed; the archive's copy is stamped.
    CHECK(!entry.Find("reason") && !entry.Find("archivedAt"));
    const json::Value& archivedEntry = (*encoded.Find("archived")->AsArray())[0];
    CHECK(archivedEntry.Find("reason") && *archivedEntry.Find("reason")->AsString() == "manual");
    CHECK(archivedEntry.Find("archivedAt") && archivedEntry.Find("archivedAt")->AsNumber());
    auto decoded = DecodeBrowserState(encoded);
    CHECK(decoded && *decoded == state);
    // Written as the Mac writes them: no splits key on a space without any.
    BrowserState plain = OneSpace();
    CHECK(!Encode(plain).Find("favoriteSplits"));
    CHECK(!(*Encode(plain).Find("spaces")->AsArray())[0].Find("splits"));
    CHECK(Encode(plain).Find("archived") && Encode(plain).Find("recentlyClosed"));
    // What JSONDecoder refuses, Kite refuses: an unknown reason, a fractional index, a bad orientation.
    auto refuses = [&](auto edit) {
        json::Value copy = encoded;
        edit(copy);
        return !DecodeBrowserState(copy);
    };
    auto member = [](json::Value& v, const char* key) -> json::Value& { return v.AsObject()->at(key); };
    auto firstClosed = [&](json::Value& v) -> json::Object& { return *(*member(v, "recentlyClosed").AsArray())[0].AsObject(); };
    CHECK(refuses([&](json::Value& v) { firstClosed(v).insert_or_assign("reason", json::Value(std::string("swept"))); }));
    CHECK(refuses([&](json::Value& v) { firstClosed(v).insert_or_assign("index", json::Value(1.5)); }));
    CHECK(refuses([&](json::Value& v) {
        json::Value& space = (*member(v, "spaces").AsArray())[0];
        (*member(space, "splits").AsArray())[0].AsObject()->insert_or_assign("orientation", json::Value(std::string("diagonal")));
    }));
}
