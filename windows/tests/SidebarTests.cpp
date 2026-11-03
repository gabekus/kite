// Ports of KiteCore's CollapsePinnedTabsTests (TabRenameTests.swift), plus the sidebar's rows
// (the Mac's SidebarSpaceList.buildRows), its favicons (FaviconSource) and the address field's
// text (SidebarHeaderView.readModel), which the Mac checks only by eye.

#include "Check.h"
#include "core/Sidebar.h"
#include "core/Url.h"
#include "core/Uuid.h"

using namespace kite;

namespace {

Tab MakeTab(std::string url, std::string title) {
    Tab tab;
    tab.id = NewUuid();
    tab.url = std::move(url);
    tab.title = std::move(title);
    return tab;
}

Folder MakeFolder(std::string name, std::vector<PinnedItem> items, bool expanded = true) {
    Folder folder;
    folder.id = NewUuid();
    folder.name = std::move(name);
    folder.items = std::move(items);
    folder.isExpanded = expanded;
    return folder;
}

// CollapsePinnedTabsTests.state(): a pinned tab A, a folder F holding B, and an unpinned C,
// selected.
struct Fixture {
    BrowserState state;
    std::string a, b, c, folder;
};

Fixture CollapseState() {
    Fixture f;
    f.state = BrowserState::MakeDefault(std::nullopt);
    f.state.spaces.resize(1);
    Space& space = f.state.spaces[0];
    space.name = "S";
    space.icon = "🏠";
    Tab a = MakeTab("https://a.example", "A"), b = MakeTab("https://b.example", "B"), c = MakeTab("https://c.example", "C");
    f.a = a.id;
    f.b = b.id;
    f.c = c.id;
    Folder folder = MakeFolder("F", {PinnedItem{b}});
    f.folder = folder.id;
    space.pinnedItems = {PinnedItem{a}, PinnedItem{folder}};
    space.tabs = {c};
    space.selectedTabID = c.id;
    f.state.selectedSpaceID = space.id;
    return f;
}

std::vector<SidebarRow::Kind> Kinds(const std::vector<SidebarRow>& rows) {
    std::vector<SidebarRow::Kind> out;
    for (const SidebarRow& row : rows) out.push_back(row.kind);
    return out;
}

using K = SidebarRow::Kind;

}  // namespace

TEST(collapsingHidesThePinnedTabsAndExpandingBringsThemBack) {
    Fixture f = CollapseState();
    const std::string space = f.state.selectedSpaceID;
    CHECK(ShownPinnedItems(f.state, f.state.SelectedSpace()).size() == 2);
    TogglePinnedSection(f.state, space);
    CHECK(IsPinnedSectionCollapsed(f.state, space));
    CHECK(ShownPinnedItems(f.state, f.state.SelectedSpace()).empty());
    TogglePinnedSection(f.state, space);
    CHECK(!IsPinnedSectionCollapsed(f.state, space));
    CHECK(ShownPinnedItems(f.state, f.state.SelectedSpace()).size() == 2);
}

TEST(collapsedKeepsTheSelectedPinnedTabEvenFromAFolder) {
    Fixture f = CollapseState();
    TogglePinnedSection(f.state, f.state.selectedSpaceID);
    f.state.Select(f.b);
    const auto shown = ShownPinnedItems(f.state, f.state.SelectedSpace());
    CHECK(shown.size() == 1 && shown[0].Id() == f.b);
}

TEST(itIsPerSpaceAndSaved) {
    Fixture f = CollapseState();
    f.state.AddSpace("Two", "💼", Theme::Presets()[1]);
    const std::string first = f.state.spaces[0].id;
    TogglePinnedSection(f.state, first);
    CHECK(!IsPinnedSectionCollapsed(f.state, f.state.spaces[1].id));
    auto decoded = DecodeBrowserState(json::Value(Encode(f.state)));
    CHECK(decoded && IsPinnedSectionCollapsed(*decoded, first));
    // The Mac's Set<UUID>: an array of the ids, under Arc's name for it.
    const json::Value encoded = Encode(f.state);
    const json::Value* saved = encoded.Find("spacesWithCollapsedPinnedSections");
    CHECK(saved && saved->AsArray() && saved->AsArray()->size() == 1 && *(*saved->AsArray())[0].AsString() == first);
    // An unknown space changes nothing.
    TogglePinnedSection(f.state, NewUuid());
    CHECK(IsPinnedSectionCollapsed(f.state, first) && !IsPinnedSectionCollapsed(f.state, f.state.spaces[1].id));
}

TEST(collapsedSectionsReadFromTheMacMatchWhateverTheCase) {
    Fixture f = CollapseState();
    std::string lower = f.state.selectedSpaceID;
    for (char& ch : lower) ch = static_cast<char>(ch >= 'A' && ch <= 'Z' ? ch - 'A' + 'a' : ch);
    f.state.extra["spacesWithCollapsedPinnedSections"] = json::Value(json::Array{json::Value(lower), json::Value(42)});
    CHECK(IsPinnedSectionCollapsed(f.state, f.state.selectedSpaceID));
    TogglePinnedSection(f.state, f.state.selectedSpaceID);
    CHECK(!IsPinnedSectionCollapsed(f.state, f.state.selectedSpaceID));
}

TEST(rowsListTheHeaderPinnedDividerNewTabThenTodaysTabs) {
    Fixture f = CollapseState();
    const auto rows = SidebarRows(f.state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Tab, K::Folder, K::Tab, K::Divider, K::NewTab, K::Tab}));
    if (rows.size() != 7) return;
    CHECK(rows[0].title == "S" && rows[0].icon == "🏠" && rows[0].hasPinned && !rows[0].pinnedCollapsed);
    CHECK(rows[1].id == f.a && rows[1].pinned && rows[1].depth == 0 && !rows[1].selected);
    CHECK(rows[2].id == f.folder && rows[2].title == "F" && rows[2].expanded && rows[2].depth == 0);
    CHECK(rows[3].id == f.b && rows[3].depth == 1 && rows[3].pinned);
    CHECK(rows[4].showsLine);
    CHECK(rows[5].title == "New Tab" && rows[5].id == f.state.spaces[0].id);
    CHECK(rows[6].id == f.c && !rows[6].pinned && rows[6].selected && rows[6].title == "C");
}

TEST(rowsSitAtArcsPitch) {
    Fixture f = CollapseState();
    const auto rows = SidebarRows(f.state, 0);
    // The header and the 3pt spacer under it, then 41pt rows and the 25pt divider.
    const std::vector<float> tops{0, 39, 80, 121, 162, 187, 228};
    const std::vector<float> heights{39, 41, 41, 41, 25, 41, 41};
    CHECK(rows.size() == tops.size());
    for (size_t i = 0; i < rows.size() && i < tops.size(); ++i) {
        CHECK(rows[i].top == tops[i]);
        CHECK(rows[i].height == heights[i]);
    }
}

TEST(aCollapsedFolderShowsOnlyItsSelectedTabFromAnyDepth) {
    Fixture f = CollapseState();
    Space& space = f.state.spaces[0];
    Tab deep = MakeTab("https://deep.example", "Deep");
    Tab other = MakeTab("https://other.example", "Other");
    Folder inner = MakeFolder("Inner", {PinnedItem{deep}});
    Folder outer = MakeFolder("Outer", {PinnedItem{other}, PinnedItem{inner}}, false);
    space.pinnedItems.push_back(PinnedItem{outer});
    // Nothing selected in it: just the folder.
    auto rows = SidebarRows(f.state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Tab, K::Folder, K::Tab, K::Folder, K::Divider, K::NewTab, K::Tab}));
    // Its selected tab, two levels down, shows right under it.
    f.state.Select(deep.id);
    rows = SidebarRows(f.state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Tab, K::Folder, K::Tab, K::Folder, K::Tab, K::Divider, K::NewTab, K::Tab}));
    if (rows.size() == 9) {
        CHECK(!rows[4].expanded && rows[4].title == "Outer");
        CHECK(rows[5].id == deep.id && rows[5].depth == 1 && rows[5].selected);
    }
}

TEST(aCollapsedPinnedSectionKeepsTheSelectedPinnedTabAtTheTop) {
    Fixture f = CollapseState();
    TogglePinnedSection(f.state, f.state.selectedSpaceID);
    auto rows = SidebarRows(f.state, 0);
    // The divider stays: the space still has pinned items, just folded away.
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Divider, K::NewTab, K::Tab}));
    CHECK(!rows.empty() && rows[0].pinnedCollapsed && rows[0].hasPinned);
    CHECK(rows.size() > 1 && rows[1].showsLine);
    f.state.Select(f.b);
    rows = SidebarRows(f.state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Tab, K::Divider, K::NewTab, K::Tab}));
    CHECK(rows.size() > 1 && rows[1].id == f.b && rows[1].depth == 0 && rows[1].selected);
}

TEST(theDividerShowsOnlyWithSomethingToDivide) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    // An empty space: header and New Tab.
    CHECK(Kinds(SidebarRows(state, 0)) == (std::vector<K>{K::Header, K::NewTab}));
    // Today's tabs alone: a divider with no line.
    state.OpenTab("https://example.com");
    auto rows = SidebarRows(state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Divider, K::NewTab, K::Tab}));
    CHECK(rows.size() > 1 && !rows[1].showsLine && !rows[0].hasPinned);
    // Pinned items alone: the line.
    state.spaces[0].pinnedItems.push_back(PinnedItem{state.spaces[0].tabs[0]});
    state.spaces[0].tabs.clear();
    rows = SidebarRows(state, 0);
    CHECK(Kinds(rows) == (std::vector<K>{K::Header, K::Tab, K::Divider, K::NewTab}));
    CHECK(rows.size() > 2 && rows[2].showsLine);
    // Another space, or none.
    CHECK(SidebarRows(state, 1).size() == 2);
    CHECK(SidebarRows(state, 9).empty());
}

TEST(tabRowsUseTheDisplayTitle) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const std::string id = state.OpenTab("https://www.example.com/a");
    state.spaces[0].tabs[0].title = "";
    CHECK(SidebarRows(state, 0).back().title == "www.example.com");
    state.spaces[0].tabs[0].customTitle = "Mine";
    CHECK(SidebarRows(state, 0).back().title == "Mine");
    state.OpenTab(std::nullopt);
    CHECK(SidebarRows(state, 0)[3].title == "New Tab");
    CHECK(SidebarRows(state, 0)[3].selected && !SidebarRows(state, 0)[4].selected && SidebarRows(state, 0)[4].id == id);
}

TEST(faviconsComeFromThePageOrItsSite) {
    // The page's own icon wins.
    CHECK(FaviconSourceOf("https://a.example/x", "https://cdn.example/i.png").url == std::optional<std::string>("https://cdn.example/i.png"));
    // Else the site's /favicon.ico, by scheme and host (no port, no path, no user).
    CHECK(FaviconSourceOf("https://u@a.example:8443/x?y#z", std::nullopt).url ==
          std::optional<std::string>("https://a.example/favicon.ico"));
    CHECK(FaviconSourceOf("http://a.example", std::nullopt).url == std::optional<std::string>("http://a.example/favicon.ico"));
    // Not for other schemes, no host, an IPv6 host (the Mac's URL is nil), or no page.
    CHECK(!FaviconSourceOf("file:///C:/x.html", std::nullopt).url);
    CHECK(!FaviconSourceOf("about:blank", std::nullopt).url);
    CHECK(!FaviconSourceOf("http://[::1]:8000/", std::nullopt).url);
    CHECK(!FaviconSourceOf(std::nullopt, std::nullopt).url);
    CHECK(FaviconSourceOf(std::nullopt, std::nullopt) == FaviconSource{});
}

TEST(kitesOwnPagesShowASymbol) {
    CHECK(FaviconSourceOf("kite://history", std::nullopt).symbol == InternalPage::History);
    CHECK(FaviconSourceOf("KITE://Archive", std::nullopt).symbol == InternalPage::Archive);
    CHECK(FaviconSourceOf("kite://site-settings?site=https://a.example", std::nullopt).symbol == InternalPage::SiteSettings);
    CHECK(FaviconSourceOf("kite://settings/privacy", std::nullopt).symbol == InternalPage::Settings);
    CHECK(FaviconSourceOf("kite://search-engines", std::nullopt).symbol == InternalPage::SearchEngines);
    CHECK(!FaviconSourceOf("kite://nope", std::nullopt).symbol);
    CHECK(!FaviconSourceOf("https://history", std::nullopt).symbol);
    CHECK(!FaviconSourceOf("kite://history", std::nullopt).url);
}

TEST(theAddressFieldShowsTheSelectedTabsHost) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    CHECK(AddressFieldText(state) == "Search or enter URL");
    state.OpenTab("https://news.ycombinator.com/item?id=1");
    CHECK(AddressFieldText(state) == "news.ycombinator.com");
    state.OpenTab(std::nullopt);
    CHECK(AddressFieldText(state) == "Search or enter URL");
    state.OpenTab("about:blank");
    CHECK(AddressFieldText(state) == "Search or enter URL");
}

// URLSession loads a page's data: icon on the Mac (FaviconCache); Windows decodes it in place.
TEST(dataFaviconsDecodeInPlace) {
    CHECK(url::DataBytes("data:image/png;base64,iVBORw0KGgo=") == std::optional<std::string>("\x89PNG\r\n\x1a\n"));
    CHECK(url::DataBytes("DATA:image/x-icon;BASE64,AAAB") == std::optional<std::string>(std::string("\0\0\1", 3)));
    // Without ;base64 the text itself, percent escapes decoded (an inline SVG).
    CHECK(url::DataBytes("data:image/svg+xml,%3Csvg%20xmlns='x'/%3E") == std::optional<std::string>("<svg xmlns='x'/>"));
    CHECK(url::DataBytes("data:,") == std::optional<std::string>(""));
    // Whitespace in base64 is skipped; anything else outside its alphabet fails.
    CHECK(url::DataBytes("data:;base64,QU JD\nRA==") == std::optional<std::string>("ABCD"));
    CHECK(!url::DataBytes("data:;base64,QU*J"));
    CHECK(!url::DataBytes("data:;base64,QUJDR"));  // a lone sixth bit group
    CHECK(!url::DataBytes("data:image/png;base64"));  // no comma
    CHECK(!url::DataBytes("https://a.example/favicon.ico"));
    CHECK(!url::DataBytes("datax:,a"));
    // A lone or broken escape stays as it is.
    CHECK(url::DataBytes("data:,100%") == std::optional<std::string>("100%"));
    CHECK(url::DataBytes("data:,%zz%4") == std::optional<std::string>("%zz%4"));
}

// GitHub's and Hacker News's icons are SVG (NSImage reads them on the Mac); bitmaps are not.
TEST(svgFaviconsAreRecognised) {
    CHECK(LooksLikeSvg("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"><path d=\"M0 0h16v16H0z\"/></svg>"));
    CHECK(LooksLikeSvg("\xEF\xBB\xBF\n  <?xml version=\"1.0\"?>\n<!-- icon -->\n<svg/>"));
    CHECK(!LooksLikeSvg("\x89PNG\r\n\x1a\n<svg"));
    CHECK(!LooksLikeSvg(std::string("\0\0\1\0", 4)));  // an .ico
    CHECK(!LooksLikeSvg("<!doctype html><html><body>Not found</body></html>"));
    CHECK(!LooksLikeSvg(""));
    CHECK(!LooksLikeSvg("   "));
}

// KiteCoreTests' nested-folder test (setFolderExpanded): a folder opens and closes at any depth.
TEST(foldersOpenAndCloseAtAnyDepth) {
    Fixture f = CollapseState();
    Space& space = f.state.spaces[0];
    Tab deep = MakeTab("https://deep.example", "Deep");
    Folder inner = MakeFolder("Inner", {PinnedItem{deep}});
    Folder outer = MakeFolder("Outer", {PinnedItem{inner}});
    space.pinnedItems.push_back(PinnedItem{outer});
    // A tab two folders down is a row like any other: clicking it selects it.
    f.state.Select(deep.id);
    CHECK(f.state.SelectedTab() && f.state.SelectedTab()->id == deep.id);
    f.state.SetFolderExpanded(inner.id, false);
    const Folder& o = std::get<Folder>(f.state.spaces[0].pinnedItems.back().value);
    CHECK(o.isExpanded && !std::get<Folder>(o.items[0].value).isExpanded);
    f.state.SetFolderExpanded(f.folder, false);
    CHECK(!std::get<Folder>(f.state.spaces[0].pinnedItems[1].value).isExpanded);
    f.state.SetFolderExpanded(f.folder, true);
    CHECK(std::get<Folder>(f.state.spaces[0].pinnedItems[1].value).isExpanded);
    const BrowserState before = f.state;
    f.state.SetFolderExpanded("no-such-folder", false);
    CHECK(f.state == before);
}

// The list sits between the header (82pt) and the space bar (50pt), and scrolls until its last
// row reaches the bottom.
TEST(theListScrollsOnlyAsFarAsItsLastRow) {
    Fixture f = CollapseState();
    const auto rows = SidebarRows(f.state, 0);
    CHECK(SidebarContentHeight(rows) == 269);
    CHECK(SidebarListBottom(800) == 750);
    CHECK(SidebarListBottom(100) == 82);  // never above the header
    CHECK(SidebarMaxScroll(rows, 800) == 0);
    // 400pt tall: 268pt of list for 269pt of rows.
    CHECK(SidebarMaxScroll(rows, 400) == 1);
    CHECK(SidebarMaxScroll(rows, 300) == 101);
    CHECK(SidebarMaxScroll({}, 300) == 0);
    // On a display's pixel grid the limit rounds down to a whole pixel: 100.7pt is 100pt at 1x
    // and 100.5pt at 2x; scale 0 leaves it as it is.
    CHECK(SidebarMaxScroll(rows, 300.3f, 1) == 100);
    CHECK(SidebarMaxScroll(rows, 300.3f, 2) == 100.5f);
    CHECK(SidebarMaxScroll(rows, 300.3f, 0) == SidebarMaxScroll(rows, 300.3f));
}

// The Mac's hitTest/acceptsPress: pills take presses, the header all of it, its chevron its
// own, the address field all but its end; nothing in the gaps.
TEST(clicksLandOnPillsTheHeaderAndTheAddressField) {
    using T = SidebarHit::Target;
    Fixture f = CollapseState();
    const auto rows = SidebarRows(f.state, 0);  // header, A, F, B, divider, New Tab, C
    auto hit = [&](float x, float y, float scroll = 0) { return SidebarHitTest(rows, 240, 800, scroll, x, y); };
    // The address field: 8 to 230 (its last 2pt aren't the text button), 46 to 82.
    CHECK(hit(8, 46) == (SidebarHit{T::AddressField, 0}));
    CHECK(hit(229.5f, 81.9f) == (SidebarHit{T::AddressField, 0}));
    CHECK(hit(230.5f, 60) == SidebarHit{});
    CHECK(hit(7.5f, 60) == SidebarHit{});
    CHECK(hit(100, 45) == SidebarHit{});
    // The header: all of its cell, the 3pt spacer under it included (SidebarList's header
    // height), with the chevron's button at 205 to 231.
    CHECK(hit(20, 82) == (SidebarHit{T::Row, 0}));
    CHECK(hit(20, 120.9f) == (SidebarHit{T::Row, 0}));
    CHECK(hit(205, 82 + 5) == (SidebarHit{T::PinnedChevron, 0}));
    CHECK(hit(230.9f, 82 + 30.9f) == (SidebarHit{T::PinnedChevron, 0}));
    CHECK(hit(204.9f, 90) == (SidebarHit{T::Row, 0}));
    CHECK(hit(231, 90) == (SidebarHit{T::Row, 0}));
    CHECK(hit(220, 82 + 4.9f) == (SidebarHit{T::Row, 0}));
    // A's pill: 2.5pt into its row (82 + 39), 36pt tall, across the list.
    CHECK(hit(8, 121 + 2.5f) == (SidebarHit{T::Row, 1}));
    CHECK(hit(231.9f, 121 + 38.4f) == (SidebarHit{T::Row, 1}));
    CHECK(hit(100, 121 + 2) == SidebarHit{});    // the gap above it
    CHECK(hit(100, 121 + 38.6f) == SidebarHit{});  // and under it
    CHECK(hit(232, 140) == SidebarHit{});         // the padding
    CHECK(hit(100, 82 + 80 + 20) == (SidebarHit{T::Row, 2}));    // the folder
    CHECK(hit(100, 82 + 162 + 12) == SidebarHit{});              // the divider
    CHECK(hit(100, 82 + 187 + 20) == (SidebarHit{T::Row, 5}));   // New Tab
    CHECK(hit(100, 82 + 228 + 20) == (SidebarHit{T::Row, 6}));   // C
    CHECK(hit(100, 82 + 269 + 20) == SidebarHit{});              // past the last row
    // Scrolled 41pt, A sits where the header was; the space bar takes nothing.
    CHECK(hit(100, 82 + 0 + 20, 41) == (SidebarHit{T::Row, 1}));
    CHECK(SidebarHitTest(rows, 240, 300, 0, 100, 251) == SidebarHit{});
    // 300pt tall and scrolled all the way (101pt), C's pill ends just above the space bar.
    CHECK(SidebarHitTest(rows, 240, 300, 101, 100, 240) == (SidebarHit{T::Row, 6}));
    // Without pinned items the header has no chevron.
    BrowserState plain = BrowserState::MakeDefault(std::nullopt);
    const auto plainRows = SidebarRows(plain, 0);
    CHECK(SidebarHitTest(plainRows, 240, 800, 0, 215, 82 + 15) == (SidebarHit{T::Row, 0}));
}

// A tap needs the release inside the pressed row's bounds: its whole height and the list's width.
TEST(aReleaseCountsInsideItsRowsBounds) {
    Fixture f = CollapseState();
    const auto rows = SidebarRows(f.state, 0);
    CHECK(SidebarRowAt(rows, 240, 800, 0, 100, 121) == std::optional<size_t>(1));
    CHECK(SidebarRowAt(rows, 240, 800, 0, 100, 121 + 40.9f) == std::optional<size_t>(1));
    CHECK(SidebarRowAt(rows, 240, 800, 0, 100, 162) == std::optional<size_t>(2));
    CHECK(SidebarRowAt(rows, 240, 800, 0, 100, 82 + 170) == std::optional<size_t>(4));  // the divider has bounds too
    CHECK(!SidebarRowAt(rows, 240, 800, 0, 7, 130));
    CHECK(!SidebarRowAt(rows, 240, 800, 0, 232, 130));
    CHECK(!SidebarRowAt(rows, 240, 800, 0, 100, 81));
    CHECK(!SidebarRowAt(rows, 240, 300, 0, 100, 250));  // under the list
}

// A press is held by the item it pressed; letting go acts as the Mac's mouseUp does.
TEST(aPressTapsWhatItPressedWhenItLetsGoOverIt) {
    using T = SidebarHit::Target;
    using A = SidebarTap::Action;
    Fixture f = CollapseState();
    const std::string spaceID = f.state.spaces[0].id;
    auto rows = SidebarRows(f.state, 0);  // header, A, F, B, divider, New Tab, C
    auto press = [&](float x, float y, int clicks = 1, bool activating = false) {
        return SidebarPressAt(rows, 240, 800, 0, x, y, clicks, activating);
    };
    auto release = [&](const SidebarPress& p, float x, float y) { return SidebarRelease(p, rows, 240, 800, 0, x, y); };

    // C's row is 310 to 351: a release anywhere in it taps, even outside the pill.
    const auto c = press(100, 330);
    CHECK(c == (SidebarPress{T::Row, K::Tab, f.c, 1}));
    CHECK(release(*c, 100, 330) == (SidebarTap{A::SelectTab, f.c, false}));
    CHECK(release(*c, 20, 350.5f) == (SidebarTap{A::SelectTab, f.c, false}));
    // Dragged off its row, or out of the list, it taps nothing.
    CHECK(release(*c, 100, 352) == SidebarTap{});
    CHECK(release(*c, 100, 300) == SidebarTap{});
    CHECK(release(*c, 5, 330) == SidebarTap{});
    // The second press of a double-click doesn't select (it renames, later).
    const auto c2 = press(100, 330, 2);
    CHECK(c2 && c2->clicks == 2);
    CHECK(release(*c2, 100, 330) == SidebarTap{});

    // The folder opens and closes; New Tab opens a tab; the header's body does nothing yet.
    CHECK(release(*press(100, 182), 100, 182) == (SidebarTap{A::SetFolderExpanded, f.folder, false}));
    CHECK(release(*press(100, 289), 100, 289) == (SidebarTap{A::NewTab, {}, false}));
    const auto header = press(40, 100);
    CHECK(header == (SidebarPress{T::Row, K::Header, spaceID, 1}));
    CHECK(release(*header, 40, 100) == SidebarTap{});
    CHECK(!press(100, 256));  // the divider

    // The chevron and the field act only when let go over themselves.
    const auto chevron = press(218, 95);
    CHECK(chevron == (SidebarPress{T::PinnedChevron, K::Header, spaceID, 1}));
    CHECK(release(*chevron, 210, 110) == (SidebarTap{A::TogglePinnedSection, spaceID, false}));
    CHECK(release(*chevron, 100, 95) == SidebarTap{});
    const auto field = press(100, 60);
    CHECK(field == (SidebarPress{T::AddressField, K::Tab, {}, 1}));
    CHECK(release(*field, 200, 80) == (SidebarTap{A::EditAddress, {}, false}));
    CHECK(release(*field, 100, 100) == SidebarTap{});

    // A click that activates the window presses only what accepts first mouse.
    CHECK(!press(100, 330, 1, true));
    CHECK(!press(40, 100, 1, true));
    CHECK(press(100, 60, 1, true) == field);
    CHECK(press(218, 95, 1, true) == chevron);
}

// Rows can move while a press is held (a tab opens or closes): the press stays its item's.
TEST(aPressFollowsItsItemWhenRowsMove) {
    using A = SidebarTap::Action;
    Fixture f = CollapseState();
    auto rows = SidebarRows(f.state, 0);
    const auto c = SidebarPressAt(rows, 240, 800, 0, 100, 330, 1);
    CHECK(c && c->id == f.c);
    // A tab opens above C: C moves down a row, and what's now under the press isn't C.
    Tab d = MakeTab("https://d.example", "D");
    f.state.spaces[0].tabs.insert(f.state.spaces[0].tabs.begin(), d);
    rows = SidebarRows(f.state, 0);
    CHECK(SidebarRelease(*c, rows, 240, 800, 0, 100, 330) == SidebarTap{});
    CHECK(SidebarRelease(*c, rows, 240, 800, 0, 100, 370) == (SidebarTap{A::SelectTab, f.c, false}));
    // C goes: the press taps nothing.
    f.state.spaces[0].tabs.pop_back();
    rows = SidebarRows(f.state, 0);
    CHECK(SidebarRelease(*c, rows, 240, 800, 0, 100, 330) == SidebarTap{});
    CHECK(SidebarRelease(*c, rows, 240, 800, 0, 100, 370) == SidebarTap{});
}

// A tab's close button (SidebarRowCell's place(close)): 24pt, 6pt from the pill's end, centred;
// it acts on release over itself, takes the click that brings the window forward (a
// SymbolButton), and isn't there for a tab in one of Claude's folders.
TEST(aTabsCloseButtonClosesIt) {
    using T = SidebarHit::Target;
    using A = SidebarTap::Action;
    Fixture f = CollapseState();
    auto rows = SidebarRows(f.state, 0);  // header, A, F, B, divider, New Tab, C (310 to 351)
    auto hit = [&](float x, float y) { return SidebarHitTest(rows, 240, 800, 0, x, y); };
    CHECK(hit(202, 318.5f) == (SidebarHit{T::CloseButton, 6}));
    CHECK(hit(225.9f, 342.4f) == (SidebarHit{T::CloseButton, 6}));
    CHECK(hit(201.9f, 330) == (SidebarHit{T::Row, 6}));
    CHECK(hit(226, 330) == (SidebarHit{T::Row, 6}));
    CHECK(hit(214, 318.4f) == (SidebarHit{T::Row, 6}));
    CHECK(hit(214, 342.5f) == (SidebarHit{T::Row, 6}));
    // Pinned tabs have one too; folders and New Tab don't.
    CHECK(hit(214, 140) == (SidebarHit{T::CloseButton, 1}));
    CHECK(hit(214, 182) == (SidebarHit{T::Row, 2}));
    CHECK(hit(214, 289) == (SidebarHit{T::Row, 5}));

    const auto press = SidebarPressAt(rows, 240, 800, 0, 214, 330, 1);
    CHECK(press == (SidebarPress{T::CloseButton, K::Tab, f.c, 1}));
    CHECK(SidebarRelease(*press, rows, 240, 800, 0, 210, 335) == (SidebarTap{A::CloseTab, f.c, false}));
    CHECK(SidebarRelease(*press, rows, 240, 800, 0, 150, 330) == SidebarTap{});  // let go on the row
    // The second click of a double-click on it still closes (a button ignores the count).
    const auto again = SidebarPressAt(rows, 240, 800, 0, 214, 330, 2);
    CHECK(SidebarRelease(*again, rows, 240, 800, 0, 214, 330) == (SidebarTap{A::CloseTab, f.c, false}));
    // It takes the click that activates the window; the row around it doesn't.
    CHECK(SidebarPressAt(rows, 240, 800, 0, 214, 330, 1, true) == press);
    CHECK(!SidebarPressAt(rows, 240, 800, 0, 150, 330, 1, true));

    // A tab Claude opened in its folder has none: its row takes the press.
    Space& space = f.state.spaces[0];
    Folder claude = MakeFolder("Claude", {PinnedItem{MakeTab("https://claude.example", "Task")}});
    claude.ephemeral = true;
    space.pinnedItems.insert(space.pinnedItems.begin(), PinnedItem{claude});
    rows = SidebarRows(f.state, 0);  // header, Claude, Task, A, ...
    CHECK(rows[2].kind == K::Tab && !rows[2].showsClose && rows[3].showsClose);
    CHECK(SidebarHitTest(rows, 240, 800, 0, 214, 82 + rows[2].top + 20) == (SidebarHit{T::Row, 2}));
}
