#pragma once
// The command bar's model (Ctrl+T, Ctrl+L): which rows it shows for what's typed. Ports
// KiteCore's TabSearch.swift and CommandSearch.swift, and the rows of the Mac's
// CommandBar.computeSuggestions, whose order it keeps, history's rows included (W25a). Not
// yet: menu commands, the search engine's suggestions, Site Search, and the tab order of
// CommandBarOrder (W7c).

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/History.h"
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
    enum class Kind { Open, Search, SwitchTab, History };
    Kind kind;
    std::string url;     // what Enter loads (Open, Search, History) or the tab's address (SwitchTab)
    std::string title;   // the URL (Open), the query (Search), the tab's or page's display title
    std::string detail;  // the dim label before the arrow: "Open", "Search Google", "Switch to Tab"; none for History
    std::string tabID;   // SwitchTab
    std::optional<std::string> faviconURL;  // SwitchTab
    // After the title, dimmer: a history row's host and path ("github.com/gabekus/kite"), as
    // Arc's "The Browser Company — youtube.com/c/thebrowsercompany". Empty when the page has no
    // title (its host is the title then).
    std::string subtitle;
    bool operator==(const CommandSuggestion&) const = default;
};

// The rows for `text`, top first; Enter takes the highlighted one (the first by default).
// A URL: open it, then matching tabs, then pages from `history`, then a search for the text.
// Anything else: the search, then matching tabs, then history. Editing the current tab leaves
// that tab out. History is the current space's profile's: up to three pages, never one already
// shown as a tab, the page you're on, or the URL the Open row opens.
std::vector<CommandSuggestion> CommandBarSuggestions(std::string_view text, const BrowserState& state, CommandBarMode mode,
                                                     const History* history = nullptr, Timestamp now = Now());
// A history row's subtitle: the host without "www." and the path, unless it's "/".
std::string HistorySubtitle(const HistoryEntry& entry);

}  // namespace kite
