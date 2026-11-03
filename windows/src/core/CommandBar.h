#pragma once
// The command bar's model (Ctrl+T, Ctrl+L): which rows it shows for what's typed. Ports
// KiteCore's TabSearch.swift and CommandSearch.swift, and the rows of the Mac's
// CommandBarView.suggestions, whose order it keeps. Not yet: history (no history store),
// menu commands (W8), the search engine's suggestions and Site Search.

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Models.h"

namespace kite {

namespace command_search {
// How well a menu command's title matches what's typed ("cop url" finds Copy URL): higher
// is better, nullopt when it doesn't match.
std::optional<int> Score(std::string_view query, std::string_view title);
}  // namespace command_search

namespace tab_search {

// Points into the state it was ranked in: valid until that state changes.
struct Match {
    const Tab* tab;
    const Space* space;  // the selected space for a favorite
    int score;
};

// Open tabs matching `query`, best first (then most recently used): favorites and the
// selected space's tabs get a bonus. Runs on every keystroke in the bar: an ASCII title or
// address (most of them) is compared in place, with no allocation.
std::vector<Match> Rank(std::string_view query, const BrowserState& state, size_t limit = 6);
// `query` already trimmed and lowercased.
std::optional<int> Score(std::string_view query, const Tab& tab);

}  // namespace tab_search

// The Mac's CommandBarMode: a new tab (Ctrl+T) or the current tab's address (Ctrl+L).
enum class CommandBarMode { NewTab, EditCurrent };

// One row, with what the bar draws (the Mac's SuggestionRow): a snapshot of the state the
// rows were made from, so the bar makes them again when the state changes.
struct CommandSuggestion {
    enum class Kind { Open, Search, SwitchTab };
    Kind kind;
    std::string url;     // what Enter loads (Open, Search) or the tab's address (SwitchTab)
    std::string title;   // the URL (Open), the query (Search), the tab's display title (SwitchTab)
    std::string detail;  // the dim label before the arrow: "Open", "Search Google", "Switch to Tab"
    std::string tabID;   // SwitchTab
    std::optional<std::string> faviconURL;  // SwitchTab
    bool operator==(const CommandSuggestion&) const = default;
};

// The rows for `text`, top first; Enter takes the highlighted one (the first by default).
// A URL: open it, then matching tabs, then a search for the text. Anything else: the search,
// then matching tabs. Editing the current tab leaves that tab out.
std::vector<CommandSuggestion> CommandBarSuggestions(std::string_view text, const BrowserState& state, CommandBarMode mode);

}  // namespace kite
