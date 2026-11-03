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
