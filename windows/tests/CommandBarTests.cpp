// Ports of KiteCore's TabSearchTests and CommandSearchTests (KiteCoreTests.swift) and
// TabRenameTests.tabSearchFindsARenamedTabByItsName, plus the command bar's rows (the Mac's
// CommandBarView.suggestions) and the lowercasing they rely on.

#include "Check.h"
#include "core/CommandBar.h"
#include "core/Unicode.h"

using namespace kite;

namespace {

Tab* Find(BrowserState& state, const std::string& id) {
    auto location = state.Location(id);
    return location ? state.TabAt(*location) : nullptr;
}

// One space with no tabs (BrowserState(spaces: [Space(...)]) in the Swift tests).
BrowserState OneSpace() {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    state.spaces.resize(1);
    state.selectedSpaceID = state.spaces[0].id;
    return state;
}

}  // namespace

TEST(tabSearchRanksTitlePrefixAboveURLMatches) {
    BrowserState state = OneSpace();
    const std::string docs = state.OpenTab("https://swift.org/docs", std::nullopt, true, 1);
    Find(state, docs)->title = "Documentation";
    const std::string gh = state.OpenTab("https://github.com/swiftlang/swift", std::nullopt, true, 2);
    Find(state, gh)->title = "swiftlang/swift";

    const auto results = tab_search::Rank("swift", state);
    CHECK(results.size() == 2);
    CHECK(results.size() == 2 && results[0].tab->id == gh && results[1].tab->id == docs);
    CHECK(!tab_search::Rank("doc", state).empty() && tab_search::Rank("doc", state)[0].tab->id == docs);
    CHECK(tab_search::Rank("zzz", state).empty());
}

TEST(tabSearchFindsARenamedTabByItsName) {
    Tab tab;
    tab.url = "https://example.com";
    tab.title = "Example Domain";
    tab.customTitle = "Reference";
    CHECK(tab_search::Score("refer", tab).has_value());
    CHECK(tab_search::Score("example", tab).has_value());
}

TEST(tabSearchScores) {
    Tab tab;
    tab.url = "https://www.Wikipedia.org/wiki/Kite";
    tab.title = "Kite – Wikipedia";
    CHECK(tab_search::Score("kite", tab) == 100);       // title prefix
    CHECK(tab_search::Score("wiki", tab) == 80);        // a word of the title
    CHECK(tab_search::Score("wikipedia.o", tab) == 70);  // host, without www.
    CHECK(tab_search::Score("e – w", tab) == 60);       // inside the title
    CHECK(tab_search::Score("/wiki/k", tab) == 40);     // inside the URL
    CHECK(!tab_search::Score("zzz", tab));
    // Characters, not bytes: "e" isn't a prefix of "e" + U+0301.
    Tab accented;
    accented.title = "e\xCC\x81t\xC3\xA9";
    CHECK(!tab_search::Score("e", accented));
    CHECK(tab_search::Score("e\xCC\x81", accented) == 100);
}

TEST(tabSearchPrefersTheSelectedSpaceThenRecentTabs) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);  // Personal (selected), Work
    const std::string other = state.OpenTab("https://a.example", state.spaces[1].id, false, 5);
    Find(state, other)->title = "Alpha";
    const std::string here = state.OpenTab("https://b.example", std::nullopt, true, 1);
    Find(state, here)->title = "Alphabet";
    const std::string recent = state.OpenTab("https://c.example", std::nullopt, true, 3);
    Find(state, recent)->title = "Alpine";
    const auto results = tab_search::Rank("alp", state);
    CHECK(results.size() == 3);
    CHECK(results.size() == 3 && results[0].tab->id == recent && results[1].tab->id == here && results[2].tab->id == other);
    CHECK(results.size() == 3 && results[2].spaceID == state.spaces[1].id);
    CHECK(tab_search::Rank("alp", state, 1).size() == 1);
}

TEST(commandSearchPrefersTitlePrefixThenWordPrefixes) {
    CHECK(command_search::Score("copy", "Copy URL") == 100);
    CHECK(command_search::Score("cop url", "Copy URL as Markdown") == 80);
    CHECK(command_search::Score("markdown url", "Copy URL as Markdown") == 80);
    CHECK(command_search::Score("ark", "Copy URL as Markdown") == 50);
}

TEST(commandSearchRejectsNonMatches) {
    CHECK(!command_search::Score("zoom", "Copy URL"));
    CHECK(!command_search::Score("  ", "Copy URL"));
}

TEST(commandBarRowsForASearch) {
    BrowserState state = OneSpace();
    const std::string tab = state.OpenTab("https://news.example", std::nullopt, true, 1);
    Find(state, tab)->title = "News of the day";
    CHECK(CommandBarSuggestions("   ", state, CommandBarMode::NewTab).empty());
    const auto rows = CommandBarSuggestions(" news ", state, CommandBarMode::NewTab);
    CHECK(rows.size() == 2);
    CHECK(rows.size() == 2 && rows[0].kind == CommandSuggestion::Kind::Search && rows[0].text == "news" &&
          rows[0].url == "https://www.google.com/search?q=news");
    CHECK(rows.size() == 2 && rows[1].kind == CommandSuggestion::Kind::SwitchTab && rows[1].tabID == tab);
    // Editing the current tab's address doesn't offer that same tab.
    CHECK(CommandBarSuggestions("news", state, CommandBarMode::EditCurrent).size() == 1);
}

TEST(commandBarRowsForAURL) {
    BrowserState state = OneSpace();
    state.searchEngine = "duckDuckGo";
    const std::string tab = state.OpenTab("https://example.com/a", std::nullopt, true, 1);
    const auto rows = CommandBarSuggestions("example.com", state, CommandBarMode::NewTab);
    CHECK(rows.size() == 3);
    CHECK(rows.size() == 3 && rows[0].kind == CommandSuggestion::Kind::Open && rows[0].url == "https://example.com");
    CHECK(rows.size() == 3 && rows[1].kind == CommandSuggestion::Kind::SwitchTab && rows[1].tabID == tab);
    CHECK(rows.size() == 3 && rows[2].kind == CommandSuggestion::Kind::Search &&
          rows[2].url == "https://duckduckgo.com/?q=example.com");
}

TEST(lowercasesLikeSwift) {
    CHECK(unicode::Lowercased("Hello WORLD") == "hello world");
    CHECK(unicode::Lowercased("\xC3\x89T\xC3\x89") == "\xC3\xA9t\xC3\xA9");             // ÉTÉ
    CHECK(unicode::Lowercased("\xC4\xB0") == "i\xCC\x87");                              // İ → i + U+0307
    CHECK(unicode::Lowercased("\xCE\x91\xCE\xA3") == "\xCE\xB1\xCF\x83");              // ΑΣ → ασ (no final sigma)
    CHECK(unicode::Lowercased("\xF0\x9E\xA4\x80") == "\xF0\x9E\xA4\xA2");              // Adlam
    CHECK(unicode::Lowercased("\xE1\xBA\x9E") == "\xC3\x9F");                           // ẞ → ß
    CHECK(unicode::Lowercased("\xE2\x84\xAA") == "k");                                  // Kelvin sign
    CHECK(unicode::Encode(U"a\U0001F600") == "a\xF0\x9F\x98\x80");
}
