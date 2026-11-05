// The favorites grid (core/Favorites.h). The Mac's Swift tests that cover it are ported case for
// case and named for theirs: SidebarGroupTests.aSplitIsOneRowAndMovesAsOne (its grouping half;
// itemMove comes with dragging, W18), ProfilesTests.favoritesBelongToTheCurrentSpacesProfile (as
// the grid shows it) and the tab numbers' KiteCoreTests.tabNumbersAndCycling and
// SplitViewTests.tabNumbersCountASplitOnce with the favorites first. FavoritesTests.
// favoritesAreSharedAndOpenInTheCurrentSpace is in ModelTests and TabClosingTests
// (selectingAFavoriteKeepsTheSpace, closingAFavoriteUnloadsIt) but for toggleFavorite, which comes
// with the tile's and the tab's menus (W14, W17). The grid itself (FavoritesTrayView,
// FavoritesTrayLayout, FavoritePaneView.applyFill, NSImage.dominantColor) is AppKit with no Swift
// tests: each case is named for the Mac code it checks, with ArcMetrics.Sidebar's numbers.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <string_view>
#include <cstdint>
#include <vector>

#include "Check.h"
#include "core/Favorites.h"
#include "core/OneShotFlags.h"
#include "core/Sidebar.h"
#include "core/Uuid.h"

using namespace kite;

namespace {

namespace F = favorites_metrics;

bool Near(double a, double b, double within = 0.001) { return std::fabs(a - b) <= within; }

// Ids of their own, distinct whatever NewUuid's randomness does on the machine running the tests.
std::string TestID() {
    static int next = 0;
    char id[37];
    std::snprintf(id, sizeof(id), "00000000-0000-4000-8000-%012d", ++next);
    return id;
}

Tab Favorite(std::string url, std::string title, std::string id = TestID()) {
    Tab tab;
    tab.id = std::move(id);
    tab.url = std::move(url);
    tab.title = std::move(title);
    return tab;
}

// The default state with `count` favorites (site0 … site{count-1}) and nothing selected.
BrowserState WithFavorites(size_t count) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    for (Space& space : state.spaces) space.id = TestID();
    state.selectedSpaceID = state.spaces[0].id;
    std::vector<Tab> grid;
    for (size_t i = 0; i < count; ++i) grid.push_back(Favorite("https://site" + std::to_string(i) + ".example", "Site " + std::to_string(i)));
    state.SetFavorites(std::move(grid));
    return state;
}

// An icon `side` px a side filled with one premultiplied colour.
std::vector<uint8_t> Icon(uint32_t side, uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
    std::vector<uint8_t> px(static_cast<size_t>(side) * side * 4);
    for (size_t i = 0; i < px.size(); i += 4) {
        px[i] = static_cast<uint8_t>(b * a / 255);
        px[i + 1] = static_cast<uint8_t>(g * a / 255);
        px[i + 2] = static_cast<uint8_t>(r * a / 255);
        px[i + 3] = a;
    }
    return px;
}

void Paint(std::vector<uint8_t>& px, uint32_t side, uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t* p = px.data() + (static_cast<size_t>(y) * side + x) * 4;
    p[0] = b;
    p[1] = g;
    p[2] = r;
    p[3] = 255;
}

}  // namespace

// MARK: FavoritesTrayLayout.columns

TEST(favoritesTrayLayoutBalancesItsRows) {
    // Kite's 240pt sidebar: 224pt inside the padding, room for four 47pt tiles.
    const float width = 240 - 2 * sidebar_metrics::kPadding;
    const int expected[] = {1, 1, 2, 3, 4, 3, 3, 4, 4, 3, 4, 4, 4};  // for 0 … 12 favorites
    for (size_t n = 0; n < std::size(expected); ++n) CHECK(FavoritesColumns(n, width) == expected[n]);
    // The doc comment's cases: 5 are 3 + 2, 7 are 4 + 3, 9 are 3 × 3.
    CHECK(FavoritesColumns(5, width) == 3 && FavoritesColumns(7, width) == 4 && FavoritesColumns(9, width) == 3);
}

TEST(favoritesTrayLayoutFitsSquareTilesInANarrowSidebar) {
    // ArcMetrics' medium header: four 47pt tiles with their gaps need 212pt of row.
    CHECK(FavoritesColumns(4, 212) == 4);
    CHECK(FavoritesColumns(4, 211.9f) == 2);  // three fit, so 2 + 2
    CHECK(FavoritesColumns(8, 157) == 3);     // three a row fit: 3 + 3 + 2
    CHECK(FavoritesColumns(8, 156) == 2);     // two do: 2 × 4
    CHECK(FavoritesColumns(3, 10) == 1);      // never none
}

// MARK: FavoritesTrayView.layout

TEST(favoritesTrayViewLaysOutOneFavoriteAcrossTheSidebar) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(1), 0, 240, true);
    CHECK(tray.columns == 1 && tray.tiles.size() == 1);
    // Under the address field (82pt), 8pt down; 47pt high, the padding's width.
    CHECK(tray.tiles[0].frame == (BarRect{8, 90, 232, 137}));
    CHECK(tray.height == F::kTopGap + F::kHeight + F::kBottomGap);
    CHECK(SidebarListTop(tray) == 82 + 63);
    // Its one pane is the whole tile.
    CHECK(tray.tiles[0].panes.size() == 1 && tray.tiles[0].panes[0].frame == tray.tiles[0].frame);
}

TEST(favoritesTrayViewLaysOutFourInARow) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(4), 0, 240, true);
    CHECK(tray.columns == 4 && tray.height == 63);
    // (224 - 3 × 8) / 4 = 50pt each, 58pt apart.
    for (size_t i = 0; i < 4; ++i) {
        const float x = 8 + 58.0f * static_cast<float>(i);
        CHECK(tray.tiles[i].frame == (BarRect{x, 90, x + 50, 137}));
    }
}

TEST(favoritesTrayViewWrapsNineIntoThreeRows) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(9), 0, 240, true);
    CHECK(tray.columns == 3);
    CHECK(tray.height == F::kTopGap + 3 * F::kHeight + 2 * F::kSpacing + F::kBottomGap);
    const float tile = (224 - 2 * 8) / 3.0f;
    // In reading order: across, then down.
    CHECK(Near(tray.tiles[4].frame.left, 8 + tile + 8) && tray.tiles[4].frame.top == 90 + 55);
    CHECK(Near(tray.tiles[8].frame.right, 232) && tray.tiles[8].frame.top == 90 + 110 && tray.tiles[8].frame.bottom == 90 + 110 + 47);
    CHECK(tray.tiles[3].frame.left == 8);
}

TEST(favoritesTrayViewIsHiddenWithNoFavoritesOnceTheEmptyStateIsDismissed) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(0), 0, 240, true);  // dismissed
    CHECK(tray.tiles.empty() && tray.height == 0 && SidebarListTop(tray) == sidebar_metrics::kHeaderAreaHeight);
    CHECK(!InFavorites(tray, 240, 100, 100));
}

TEST(favoriteTileViewShowsASplitAsOneTileWithItsPanes) {
    BrowserState state = WithFavorites(5);
    const auto& grid = state.Favorites();
    state.favoriteSplitsByProfile["Default"] = {SplitView{"S", {grid[1].id, grid[2].id}, {0.5, 0.5}, "horizontal", std::nullopt, {}},
                                                SplitView{"V", {grid[3].id, grid[4].id}, {0.5, 0.5}, "vertical", std::nullopt, {}}};
    const FavoritesTray tray = LayOutFavorites(state, 0, 240, true);
    // Three slots: site0, the split S, the split V, so three a row.
    CHECK(tray.tiles.size() == 3 && tray.columns == 3);
    CHECK(tray.tiles[1].id == "S" && tray.tiles[1].split && !tray.tiles[1].vertical && tray.tiles[1].panes.size() == 2);
    const BarRect& tile = tray.tiles[1].frame;
    const BarRect& a = tray.tiles[1].panes[0].frame;
    const BarRect& b = tray.tiles[1].panes[1].frame;
    // Side by side, 2pt apart, sharing the tile.
    CHECK(a.left == tile.left && Near(b.left - a.right, 2) && Near(b.right, tile.right) && a.top == tile.top && a.bottom == tile.bottom);
    // A top/bottom split stacks them.
    const BarRect& top = tray.tiles[2].panes[0].frame;
    const BarRect& bottom = tray.tiles[2].panes[1].frame;
    CHECK(tray.tiles[2].vertical && Near(top.Height(), 22.5) && Near(bottom.top - top.bottom, 2) && Near(bottom.bottom, tray.tiles[2].frame.bottom));
    CHECK(top.left == tray.tiles[2].frame.left && top.right == tray.tiles[2].frame.right);
}

// MARK: SidebarGroupTests

TEST(aSplitIsOneRowAndMovesAsOne) {
    std::vector<std::string> ids;
    for (int i = 0; i < 5; ++i) ids.push_back(TestID());
    const std::vector<SplitView> splits{SplitView{"SPLIT", {ids[1], ids[2]}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    const std::vector<SidebarGroup> groups = GroupBySplit(ids, splits);
    CHECK(groups.size() == 4);
    CHECK(groups[0].indices == std::vector<size_t>{0} && groups[1].indices == (std::vector<size_t>{1, 2}) &&
          groups[2].indices == std::vector<size_t>{3} && groups[3].indices == std::vector<size_t>{4});
    CHECK(groups[1].id == "SPLIT" && groups[1].split == &splits[0] && groups[0].id == ids[0] && !groups[0].split);
}

// MARK: FavoritesTrayView.rebuild: what each pane shows

TEST(favoritePaneViewShowsTheTabsTitleFaviconAndSelection) {
    BrowserState state = WithFavorites(2);
    std::vector<Tab> grid = state.Favorites();
    grid[0].faviconURL = "https://cdn.example/mail.png";
    grid[1].customTitle = "Renamed";
    state.SetFavorites(grid);
    state.Select(grid[1].id);
    const FavoritesTray tray = LayOutFavorites(state, state.SelectedSpaceIndex(), 240, true);
    const FavoritePane& first = tray.tiles[0].panes[0];
    const FavoritePane& second = tray.tiles[1].panes[0];
    // FaviconSource: the page's reported icon, else the site's /favicon.ico.
    CHECK(first.favicon.url == "https://cdn.example/mail.png" && second.favicon.url == "https://site1.example/favicon.ico");
    // Its tooltip is the tab's DisplayTitle; the selected one is the space's selected tab.
    CHECK(first.title == "Site 0" && second.title == "Renamed");
    CHECK(!first.selected && second.selected);
    // A tab without a page has no favicon (the globe).
    grid[0].url.reset();
    grid[0].faviconURL.reset();
    state.SetFavorites(grid);
    CHECK(!LayOutFavorites(state, 0, 240, true).tiles[0].panes[0].favicon.url);
}

TEST(favoritesBelongToTheCurrentSpacesProfile) {
    BrowserState state = WithFavorites(2);  // the Default profile's
    state.extra["profiles"] = json::Value(json::Array{json::Value(json::Object{{"directory", "Profile 1"}, {"name", "Work"}})});
    state.spaces[1].extra["profile"] = json::Value("Profile 1");
    state.favoritesByProfile["Profile 1"] = {Favorite("https://work.example", "Work")};
    // Each space's grid is its profile's, whichever space is selected.
    CHECK(LayOutFavorites(state, 0, 240, true).tiles.size() == 2);
    CHECK(LayOutFavorites(state, 1, 240, true).tiles.size() == 1 && LayOutFavorites(state, 1, 240, true).tiles[0].panes[0].title == "Work");
    state.SelectSpaceAt(1);
    CHECK(state.Favorites().size() == 1 && FavoritesOf(state, 1).size() == 1 && FavoritesOf(state, 0).size() == 2);
    // A profile with no grid shows none.
    state.favoritesByProfile.erase("Profile 1");
    CHECK(LayOutFavorites(state, 1, 240, true).height == 0);
}

// MARK: FavoritePaneView: presses

TEST(favoritePaneViewSelectsOnReleaseInside) {
    BrowserState state = WithFavorites(4);
    const FavoritesTray tray = LayOutFavorites(state, 0, 240, true);
    const std::string id = state.Favorites()[2].id;
    // The third tile, at x 124…174.
    const auto press = FavoritePressAt(tray, 150, 110);
    CHECK(press && press->tabID == id);
    CHECK(FavoriteRelease(*press, tray, 170, 130) == (FavoriteTap{FavoriteTap::Action::SelectTab, id}));
    // Let go outside the pane it pressed (on its neighbour too): nothing.
    CHECK(FavoriteRelease(*press, tray, 200, 110).action == FavoriteTap::Action::None);
    CHECK(FavoriteRelease(*press, tray, 150, 140).action == FavoriteTap::Action::None);
}

TEST(favoriteTileViewTurnsAMoveOfFourPointsIntoADrag) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(1), 0, 240, true);
    auto press = FavoritePressAt(tray, 100, 110);
    CHECK(press);
    FavoriteMove(*press, 103, 110);
    CHECK(!press->dragged && FavoriteRelease(*press, tray, 103, 110).action == FavoriteTap::Action::SelectTab);
    FavoriteMove(*press, 104, 110);
    // A drag lets go without selecting (it drops, which W18b brings), even back where it began.
    CHECK(press->dragged && FavoriteRelease(*press, tray, 100, 110).action == FavoriteTap::Action::None);
}

TEST(favoritePaneViewDoesntAcceptFirstMouse) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(1), 0, 240, true);
    CHECK(!FavoritePressAt(tray, 100, 110, true));
    CHECK(FavoritePressAt(tray, 100, 110, false));
}

TEST(favoritesTrayViewTakesPressesInItsGapsButTapsNothing) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(4), 0, 240, true);
    // Between tiles, in the 8pt above, at the sidebar's edge: the tray's, no pane.
    for (const auto& [x, y] : {std::pair{61.0f, 110.0f}, {100.0f, 84.0f}, {2.0f, 110.0f}, {100.0f, 140.0f}}) {
        CHECK(InFavorites(tray, 240, x, y));
        CHECK(!FavoritePressAt(tray, x, y));
    }
    // The band ends at the page's top.
    CHECK(!InFavorites(tray, 240, 100, 145) && InFavorites(tray, 240, 100, 144.9f));
    CHECK(!InFavorites(tray, 240, 100, 81.9f));
}

TEST(favoriteTileViewsSplitGapTakesNoTap) {
    BrowserState state = WithFavorites(2);
    const auto& grid = state.Favorites();
    state.favoriteSplitsByProfile["Default"] = {SplitView{"S", {grid[0].id, grid[1].id}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    const FavoritesTray tray = LayOutFavorites(state, 0, 240, true);
    CHECK(tray.tiles.size() == 1);
    // 224pt split in two 111pt panes 2pt apart: the gap is at 119…121.
    CHECK(!FavoritePressAt(tray, 120, 110));
    CHECK(FavoritePressAt(tray, 118, 110)->tabID == grid[0].id && FavoritePressAt(tray, 122, 110)->tabID == grid[1].id);
}

// MARK: The page under the grid

TEST(theSpacesPageStartsUnderTheFavorites) {
    BrowserState state = WithFavorites(4);
    const std::vector<SidebarRow> rows = SidebarRows(state, 0);
    const float listTop = SidebarListTop(LayOutFavorites(state, 0, 240, true));
    CHECK(listTop == 145);
    // The space's header is where the page starts, under the grid, not under the address field.
    CHECK(SidebarHitTest(rows, 240, 820, 0, 100, 150, listTop) == (SidebarHit{SidebarHit::Target::Row, 0}));
    CHECK(SidebarHitTest(rows, 240, 820, 0, 100, 140, listTop).target == SidebarHit::Target::None);
    CHECK(SidebarRowAt(rows, 240, 820, 0, 100, 150, listTop) == 0u);
    // The list is shorter by the grid: the page ends at the space bar either way.
    CHECK(SidebarListBottom(820, listTop) == 770);
    CHECK(SidebarListBottom(100, listTop) == listTop);
    // A press on New Tab, found where it now is.
    const float newTab = listTop + rows.back().top + 20;
    const auto press = SidebarPressAt(rows, 240, 820, 0, 100, newTab, 1, false, listTop);
    CHECK(press && press->kind == SidebarRow::Kind::NewTab);
    CHECK(SidebarRelease(*press, rows, 240, 820, 0, 100, newTab, listTop).action == SidebarTap::Action::NewTab);
}

TEST(theSpacesPageScrollsTheRoomLeftUnderTheFavorites) {
    BrowserState state = WithFavorites(9);
    for (int i = 0; i < 20; ++i) state.OpenTab("https://tab" + std::to_string(i) + ".example", std::nullopt, false, Now(), TestID());
    const std::vector<SidebarRow> rows = SidebarRows(state, 0);
    const float listTop = SidebarListTop(LayOutFavorites(state, 0, 240, true));
    // Less room, so further to scroll to its end.
    const float plain = SidebarMaxScroll(rows, 820, 1);
    const float under = SidebarMaxScroll(rows, 820, 1, listTop);
    CHECK(Near(under - plain, listTop - sidebar_metrics::kHeaderAreaHeight));
}

// MARK: Ctrl+1–9 (BrowserState.selectTab(number:)): the favorites first

TEST(tabNumbersCountTheFavoritesFirst) {
    BrowserState state = WithFavorites(2);
    const std::string a = state.Favorites()[0].id, b = state.Favorites()[1].id;
    const std::string tab = state.OpenTab("https://tab.example", std::nullopt, true, Now(), TestID());
    state.SelectTabNumber(1);
    CHECK(state.SelectedTab()->id == a);
    state.SelectTabNumber(2);
    CHECK(state.SelectedTab()->id == b);
    state.SelectTabNumber(3);
    CHECK(state.SelectedTab()->id == tab);
    // Ctrl+9 is the last tab, never a favorite while the space has its own.
    state.SelectTabNumber(9);
    CHECK(state.SelectedTab()->id == tab);
    // The selected favorite's pane shows it, in whichever space you're in.
    state.SelectSpaceAt(1);
    state.SelectTabNumber(2);
    CHECK(state.SelectedSpaceIndex() == 1 && LayOutFavorites(state, 1, 240, true).tiles[1].panes[0].selected);
    CHECK(!LayOutFavorites(state, 0, 240, true).tiles[1].panes[0].selected);
    // A space with only favorites: Ctrl+9 is the last favorite.
    state.SelectTabNumber(9);
    CHECK(state.SelectedTab()->id == b);
}

TEST(tabNumbersCountAFavoriteSplitOnce) {
    BrowserState state = WithFavorites(3);
    const auto grid = state.Favorites();
    state.favoriteSplitsByProfile["Default"] = {SplitView{"S", {grid[0].id, grid[1].id}, {0.5, 0.5}, "horizontal", std::nullopt, {}}};
    std::vector<Tab> stamped = grid;
    stamped[1].lastActiveAt = 50;  // the split's pane used last
    state.SetFavorites(stamped);
    const std::string tab = state.OpenTab("https://tab.example", std::nullopt, true, 60, TestID());
    // Stops: [split S], site2, tab, as the grid's tiles.
    CHECK(state.SidebarStops(state.SelectedSpaceIndex()).size() == 3);
    CHECK(LayOutFavorites(state, state.SelectedSpaceIndex(), 240, true).tiles.size() == 2);
    state.SelectTabNumber(2, 70);
    CHECK(state.SelectedTab()->id == grid[2].id);
    state.SelectTabNumber(1, 80);
    CHECK(state.SelectedTab()->id == grid[1].id);
    state.SelectTabNumber(3, 90);
    CHECK(state.SelectedTab()->id == tab);
}

// MARK: FavoritePaneView.applyFill

TEST(favoritePaneViewFillsUnselectedPanesWithTheFieldsWash) {
    CHECK(FavoriteLookOf(false, false, true, true) == (FavoriteLook{0.10f, 0, false}));
    CHECK(Near(FavoriteLookOf(false, true, true, false).fill, 0.20));
    // chromeFill on a light theme: 3.5 times, at most 0.7.
    CHECK(Near(FavoriteLookOf(false, false, false, true).fill, 0.35) && Near(FavoriteLookOf(false, true, false, true).fill, 0.70));
    CHECK(FavoriteLookOf(false, true, false, true).tint == 0 && !FavoriteLookOf(false, true, false, true).ring);
}

TEST(favoritePaneViewFillsTheSelectedPaneWithItsFaviconsColour) {
    // Dark: white 0.45, the colour at 0.2 (0.3 hovered), its ring.
    CHECK(FavoriteLookOf(true, false, true, true) == (FavoriteLook{0.45f, 0.2f, true}));
    CHECK(FavoriteLookOf(true, true, true, true) == (FavoriteLook{0.45f, 0.3f, true}));
    // Light: white 0.8, no colour at rest, 0.1 hovered, the ring either way.
    CHECK(FavoriteLookOf(true, false, false, true) == (FavoriteLook{0.8f, 0, true}));
    CHECK(FavoriteLookOf(true, true, false, true) == (FavoriteLook{0.8f, 0.1f, true}));
    // No colour (a grey, missing or not yet loaded favicon): just white.
    CHECK(FavoriteLookOf(true, true, true, false) == (FavoriteLook{0.45f, 0, false}));
    CHECK(FavoriteLookOf(true, false, false, false) == (FavoriteLook{0.8f, 0, false}));
}

// MARK: NSImage.dominantColor

TEST(dominantColorIsTheIconsMostCommonSaturatedHue) {
    constexpr uint32_t side = F::kColorSampleSide;
    // YouTube's red with a white glyph: the red.
    std::vector<uint8_t> icon = Icon(side, 255, 0, 51);
    for (uint32_t y = 6; y < 10; ++y) {
        for (uint32_t x = 6; x < 10; ++x) Paint(icon, side, x, y, 255, 255, 255);
    }
    const auto red = DominantColor(icon.data(), side, side, side * 4);
    CHECK(red && Near(red->r, 1) && Near(red->g, 0) && Near(red->b, 0.2));
    // The fullest bin's average: two violets in one bin (hues 0.70 and 0.73) average, an orange
    // minority loses.
    std::vector<uint8_t> mixed = Icon(side, 0, 0, 0, 0);
    for (uint32_t x = 0; x < side; ++x) {
        Paint(mixed, side, x, 0, 51, 0, 255);
        Paint(mixed, side, x, 1, 102, 0, 255);
        Paint(mixed, side, x, 2, 255, 128, 0);
    }
    const auto violet = DominantColor(mixed.data(), side, side, side * 4);
    CHECK(violet && Near(violet->r, 0.3) && Near(violet->g, 0) && Near(violet->b, 1));
}

TEST(dominantColorIsNoneForAGreyOrEmptyIcon) {
    constexpr uint32_t side = F::kColorSampleSide;
    // GitHub's black and white, Wikipedia's grey, a transparent icon, a dark one.
    for (const auto& icon : {Icon(side, 24, 23, 23), Icon(side, 255, 255, 255), Icon(side, 128, 128, 128), Icon(side, 255, 0, 0, 0),
                             Icon(side, 30, 0, 0)}) {
        CHECK(!DominantColor(icon.data(), side, side, side * 4));
    }
    // Only pixels more than half opaque count: a faint red wash doesn't.
    const auto faint = Icon(side, 255, 0, 0, 127);
    CHECK(!DominantColor(faint.data(), side, side, side * 4));
    const auto solid = Icon(side, 255, 0, 0, 200);
    // Premultiplied pixels are read as their colour.
    const auto read = DominantColor(solid.data(), side, side, side * 4);
    CHECK(read && Near(read->r, 1, 0.01) && Near(read->g, 0));
    CHECK(!DominantColor(nullptr, side, side, side * 4));
}

TEST(dominantColorBreaksTiesByHueOrder) {
    constexpr uint32_t side = 2;
    std::vector<uint8_t> icon(side * side * 4, 0);
    Paint(icon, side, 0, 0, 0, 0, 255);  // blue, bin 8
    Paint(icon, side, 1, 0, 255, 0, 0);  // red, bin 0
    const auto color = DominantColor(icon.data(), side, side, side * 4);
    CHECK(color && color->r == 1 && color->b == 0);
}

TEST(favoriteHighlightMixesInCalibratedRGBAsNSColorBlendedDoes) {
    // YouTube's red as dominantColor finds it in its 16px icon (with its pink edge pixels): the Mac's
    // ring is (255, 149, 150) in review/w13-mac's rest.png; a plain sRGB mix gives (255, 129, 129).
    const ThemeColor ring = FavoriteHighlight(ThemeColor{1, 0.0106f, 0.0106f});
    CHECK(Near(ring.r * 255, 255, 0.5) && Near(ring.g * 255, 149.2, 0.5) && Near(ring.b * 255, 150, 0.5));
    // White stays white, and a grey stays grey (lighter).
    const ThemeColor white = FavoriteHighlight(ThemeColor{1, 1, 1});
    CHECK(Near(white.r, 1) && Near(white.g, 1) && Near(white.b, 1));
    const ThemeColor grey = FavoriteHighlight(ThemeColor{0.5f, 0.5f, 0.5f});
    CHECK(grey.r > 0.5f && Near(grey.r, grey.g, 0.002) && Near(grey.g, grey.b, 0.002));
}

// MARK: FavoritesEmptyStateView

TEST(favoritesEmptyStateViewShowsUntilDismissed) {
    // A fresh profile with no favorites: the dashed box, 59pt in a 240pt sidebar (its subtitle on
    // two lines), with 8pt above and below; the space's header near y 157.
    const FavoritesTray tray = LayOutFavorites(WithFavorites(0), 0, 240, false);
    CHECK(tray.emptyState && tray.tiles.empty());
    CHECK(tray.height == 75 && SidebarListTop(tray) == 157);
    CHECK(tray.emptyFrame == (BarRect{8, 90, 232, 149}));
    // The close button 4pt in from its top-right, below the 6pt inset: 18pt.
    CHECK(tray.closeFrame == (BarRect{210, 100, 228, 118}));
    CHECK(InFavorites(tray, 240, 100, 84) && OverEmptyState(tray, 100, 120) && !OverEmptyState(tray, 100, 150));
    // Dismissed, no tray; with favorites, never the empty state.
    CHECK(LayOutFavorites(WithFavorites(0), 0, 240, true).height == 0);
    CHECK(!LayOutFavorites(WithFavorites(2), 0, 240, false).emptyState);
}

TEST(favoritesEmptyStateViewIsAtLeastATileHigh) {
    // height(forWidth:): max(47, title + 2 + subtitle) + 12, a line being SF's line box (15 for the
    // 12pt title, 14 for the 11pt subtitle) and a wrapped one's lines its pitch (15, 14).
    namespace E = favorites_empty;
    CHECK(E::LineHeight(12) == 15 && E::LineHeight(11) == 14 && E::LinePitch(12) == 15 && E::LinePitch(11) == 14);
    CHECK(E::Height(1, 1) == 47 + 12);  // 15 + 2 + 14 = 31 < 47
    CHECK(E::Height(1, 2) == 47 + 12);  // 45 < 47
    CHECK(E::Height(1, 3) == 15 + 2 + 42 + 12);
    CHECK(E::Height(2, 3) == 30 + 2 + 42 + 12);
    // As the shell measures it: a taller box pushes the page down with it.
    CHECK(SidebarListTop(LayOutFavorites(std::vector<FavoriteTile>{}, 240, false, E::Height(2, 3))) == 82 + 8 + 86 + 8);
}

TEST(favoritesEmptyStateViewsCloseButtonDismissesIt) {
    const FavoritesTray tray = LayOutFavorites(WithFavorites(0), 0, 240, false);
    // A SymbolButton: it takes the click that brings the window forward, and acts on release over it.
    const auto press = FavoritePressAt(tray, 219, 109, true);
    CHECK(press && press->target == FavoritePress::Target::CloseEmptyState);
    CHECK(FavoriteRelease(*press, tray, 220, 110).action == FavoriteTap::Action::DismissEmptyState);
    CHECK(FavoriteRelease(*press, tray, 200, 110).action == FavoriteTap::Action::None);
    // Elsewhere on the box, nothing (the drop target, with W18b).
    CHECK(!FavoritePressAt(tray, 100, 120));
}

// MARK: What a pane draws again (FavoritePaneView.show)

TEST(favoritePaneViewDrawsAgainOnlyWhatChanged) {
    BrowserState state = WithFavorites(2);
    FavoritePane pane = LayOutFavorites(state, 0, 240, true).tiles[0].panes[0];
    const std::optional<std::pair<BarRect, FaviconSource>> drawn = std::make_pair(pane.frame, pane.favicon);
    // Never drawn: everything.
    CHECK(FavoriteRedrawFor(std::nullopt, pane, false) == (FavoriteRedraw{true, true, true}));
    // Selected, retitled: nothing.
    pane.selected = true;
    pane.title = "Renamed";
    CHECK(FavoriteRedrawFor(drawn, pane, false) == FavoriteRedraw{});
    // Another appearance: the icon (the globe is labelColor).
    CHECK(FavoriteRedrawFor(drawn, pane, true) == (FavoriteRedraw{false, false, true}));
    // Another favicon: the icon and its colour's tint and ring, not a stale one's.
    FavoritePane moved = pane;
    moved.favicon.url = "https://other.example/icon.png";
    CHECK(FavoriteRedrawFor(drawn, moved, false) == (FavoriteRedraw{false, true, true}));
    // Another frame (another count of favorites): all of it.
    moved = pane;
    moved.frame.right -= 10;
    CHECK(FavoriteRedrawFor(drawn, moved, false) == (FavoriteRedraw{true, true, true}));
}

// MARK: OneShotFlags (OneShotFlags.swift's file on a test profile)

namespace {
// Tests/Fixtures/one-shot-flags.plist, which the Swift suite reads with PropertyListDecoder too
// (OneShotFlagsTests.readsTheSharedFixture): favoritesEmptyStateDismissed true,
// passwordManagerOfferShown false, as a binary property list in Apple's format.
std::string FlagsFixture() {
    std::ifstream in(std::filesystem::path(KITE_FIXTURES_DIR) / "one-shot-flags.plist", std::ios::binary);
    return std::string{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}
}  // namespace

TEST(oneShotFlagsReadTheSharedFixture) {
    const std::string fixture = FlagsFixture();
    CHECK(fixture.size() == 111);
    const auto flags = OneShotFlags::Parse(fixture);
    CHECK(flags && flags->size() == 2);
    CHECK(flags && flags->at("favoritesEmptyStateDismissed") && !flags->at("passwordManagerOfferShown"));
}

TEST(oneShotFlagsWriteAPropertyListTheyReadBack) {
    std::map<std::string, bool> flags{{"favoritesEmptyStateDismissed", true}, {"passwordManagerOfferShown", false}};
    const std::optional<std::string> bytes = OneShotFlags::Write(flags);
    // The fixture's bytes, for the same flags (keys in order, no shared objects).
    CHECK(bytes && *bytes == FlagsFixture());
    CHECK(bytes && OneShotFlags::Parse(*bytes) == flags);
    // A long key (an extended count), a non-ASCII one (UTF-16, a surrogate pair too), and none at all.
    std::map<std::string, bool> odd{{std::string(300, 'k'), true}, {"caf\xc3\xa9", false}, {"\xf0\x9f\xaa\x81kite", true}};
    const auto oddBytes = OneShotFlags::Write(odd);
    CHECK(oddBytes && OneShotFlags::Parse(*oddBytes) == odd);
    const auto none = OneShotFlags::Write({});
    CHECK(none && OneShotFlags::Parse(*none) == (std::map<std::string, bool>{}));
}

TEST(oneShotFlagsRefuseAKeyThatIsntUTF8) {
    // A stray continuation byte, a truncated sequence, an overlong slash: none of them text.
    for (const char* key : {"bad\x80key", "cut\xe2\x82", "\xc0\xaf"}) {
        CHECK(!OneShotFlags::Write({{key, true}}));
    }
    // And Set says so, keeping the flag for this run.
    OneShotFlags flags = OneShotFlags::Load(std::filesystem::temp_directory_path() / ("kite-flags-" + TestID() + "-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())));
    CHECK(!flags.Set("bad\x80key", true).empty() && flags.Get("bad\x80key"));
}

TEST(oneShotFlagsReadNothingFromAnythingElse) {
    CHECK(!OneShotFlags::Parse(""));
    CHECK(!OneShotFlags::Parse("bplist00"));
    CHECK(!OneShotFlags::Parse("<?xml version=\"1.0\"?><plist/>"));
    // A value that isn't a boolean: [String: Bool] doesn't decode, so no flags at all.
    std::string bytes = FlagsFixture();
    bytes[72] = 0x10;  // the first value's marker, now an integer
    CHECK(!OneShotFlags::Parse(bytes));
    // Truncated: none.
    const std::string fixture = FlagsFixture();
    CHECK(!OneShotFlags::Parse(std::string_view(fixture).substr(0, fixture.size() - 1)));
}

TEST(oneShotFlagsLiveInTheProfilesFolder) {
    namespace fs = std::filesystem;
    const fs::path folder = fs::temp_directory_path() / ("kite-flags-" + TestID() + "-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    // A missing file: nothing set.
    OneShotFlags flags = OneShotFlags::Load(folder);
    CHECK(!flags.Get(OneShotFlags::kFavoritesEmptyStateDismissed));
    CHECK(flags.Set(OneShotFlags::kFavoritesEmptyStateDismissed, true).empty());
    CHECK(flags.Get(OneShotFlags::kFavoritesEmptyStateDismissed));
    CHECK(fs::exists(folder / OneShotFlags::kFileName) && !fs::exists(folder / "One-Shot Flags.plist.tmp"));
    CHECK(OneShotFlags::Load(folder).Get(OneShotFlags::kFavoritesEmptyStateDismissed));
    // Another flag set keeps the first.
    CHECK(OneShotFlags::Load(folder).Set("passwordManagerOfferShown", true).empty());
    CHECK(OneShotFlags::Load(folder).Get(OneShotFlags::kFavoritesEmptyStateDismissed));
    // A folder that can't be made (a file in its way): the error names it.
    const fs::path blocked = folder / "file";
    { std::ofstream(blocked) << "x"; }
    const std::string problem = OneShotFlags::Load(blocked / "profile").Set("asked", true);
    CHECK(problem.find("couldn't create") == 0 && problem.find("profile") != std::string::npos);
    std::error_code error;
    fs::remove_all(folder, error);
}
