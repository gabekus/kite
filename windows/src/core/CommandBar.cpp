// See CommandBar.h.

#include "core/CommandBar.h"

#include <algorithm>

#include "core/TextMatch.h"
#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Url.h"

namespace kite {
namespace {

using text_match::Field;
using text_match::Query;
using text_match::ReplaceAll;
using text_match::TrimmedLowercase;

// Text as Swift's String sees it: a sequence of Characters (grapheme clusters), so prefixes
// and substrings never end inside one (typing "e" doesn't match "e" + U+0301), compared by
// canonical equivalence (precomposed "é" matches "e" + U+0301), via NFD.
using Chars = std::vector<std::u32string>;

Chars Split(std::string_view utf8) { return unicode::Characters(unicode::Decomposed(utf8)); }

bool HasPrefix(const Chars& text, const Chars& prefix) {
    return prefix.size() <= text.size() && std::equal(prefix.begin(), prefix.end(), text.begin());
}

bool Contains(const Chars& text, const Chars& part) {
    return std::search(text.begin(), text.end(), part.begin(), part.end()) != text.end();
}

bool IsWordCharacter(const std::u32string& c) { return !c.empty() && (unicode::IsLetter(c[0]) || unicode::IsNumber(c[0])); }

// Swift's split(whereSeparator: { !$0.isLetter && !$0.isNumber }): runs of letters and
// numbers, empty runs dropped.
std::vector<Chars> Words(const Chars& text) {
    std::vector<Chars> words;
    Chars word;
    for (const auto& c : text) {
        if (IsWordCharacter(c)) {
            word.push_back(c);
        } else if (!word.empty()) {
            words.push_back(std::move(word));
            word.clear();
        }
    }
    if (!word.empty()) words.push_back(std::move(word));
    return words;
}

std::optional<int> ScoreTab(const Query& q, const Tab& tab) {
    // A renamed tab is found by its name as well as its page's title.
    std::string joined;
    std::string_view titleText = tab.title;
    if (tab.customTitle) {
        joined = *tab.customTitle + " " + tab.title;
        titleText = joined;
    }
    const Field title(titleText);
    if (title.HasPrefix(q)) return 100;
    if (title.WordHasPrefix(q)) return 80;
    const std::string_view address = tab.url ? std::string_view(*tab.url) : std::string_view();
    {
        const std::string host = ReplaceAll(unicode::Lowercased(url::Host(address).value_or("")), "www.", "");
        if (Field(host).HasPrefix(q)) return 70;
    }
    if (title.Contains(q)) return 60;
    if (Field(address).Contains(q)) return 40;
    return std::nullopt;
}

}  // namespace

namespace command_search {

std::optional<int> Score(std::string_view query, std::string_view title) {
    const std::string q = TrimmedLowercase(query);
    if (q.empty()) return std::nullopt;
    const Chars t = Split(unicode::Lowercased(title));
    const Chars typed = Split(q);
    if (HasPrefix(t, typed)) return 100;
    const std::vector<Chars> words = Words(t);
    // Every typed word starts some word of the title, in any order (q.split(separator: " ")).
    std::vector<Chars> parts;
    Chars part;
    for (const auto& c : typed) {
        if (c == U" ") {
            if (!part.empty()) parts.push_back(std::move(part));
            part.clear();
        } else {
            part.push_back(c);
        }
    }
    if (!part.empty()) parts.push_back(std::move(part));
    const bool allStart = std::all_of(parts.begin(), parts.end(), [&](const Chars& p) {
        return std::any_of(words.begin(), words.end(), [&](const Chars& w) { return HasPrefix(w, p); });
    });
    if (allStart) return 80;
    if (Contains(t, typed)) return 50;
    return std::nullopt;
}

}  // namespace command_search

namespace tab_search {

std::optional<int> Score(std::string_view query, const Tab& tab) { return ScoreTab(Query(query), tab); }

std::vector<Match> Rank(std::string_view query, const BrowserState& state, size_t limit) {
    const std::string lowered = TrimmedLowercase(query);
    if (lowered.empty()) return {};
    const Query q(lowered);
    const Space& selected = state.SelectedSpace();
    std::vector<Match> matches;
    for (const Tab& tab : state.Favorites()) {
        if (auto score = ScoreTab(q, tab)) matches.push_back({&tab, &selected, *score + 5});
    }
    for (const Space& space : state.spaces) {
        // The Mac's space.allTabs: pinned (folders included), then unpinned.
        for (const Tab* tab : space.AllTabs()) {
            if (auto score = ScoreTab(q, *tab)) matches.push_back({tab, &space, *score + (&space == &selected ? 5 : 0)});
        }
    }
    // Best score, then most recently used; ties keep the order found, so the result is
    // the same every time (the Mac's sort leaves such ties in no set order).
    std::vector<size_t> order(matches.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    const size_t kept = std::min(limit, order.size());
    std::partial_sort(order.begin(), order.begin() + static_cast<std::ptrdiff_t>(kept), order.end(), [&](size_t a, size_t b) {
        const Match& x = matches[a];
        const Match& y = matches[b];
        if (x.score != y.score) return x.score > y.score;
        if (x.tab->lastActiveAt != y.tab->lastActiveAt) return x.tab->lastActiveAt > y.tab->lastActiveAt;
        return a < b;
    });
    std::vector<Match> out;
    out.reserve(kept);
    for (size_t i = 0; i < kept; ++i) out.push_back(matches[order[i]]);
    return out;
}

}  // namespace tab_search

std::string HistorySubtitle(const HistoryEntry& entry) {
    if (entry.title.empty()) return {};
    // The Mac's url.host() and url.path(), both percent-encoded as written.
    const std::string host = ReplaceAll(url::Host(entry.url).value_or(""), "www.", "");
    const std::string_view path = url::Path(entry.url);
    return host + (path == "/" ? std::string() : std::string(path));
}

std::vector<CommandSuggestion> CommandBarSuggestions(std::string_view input, const BrowserState& state, CommandBarMode mode,
                                                     const History* history, Timestamp now) {
    const std::string text(unicode::Trim(input));
    if (text.empty()) return {};
    const SearchEngine engine = SearchEngineFromRaw(state.searchEngine).value_or(SearchEngine::Google);
    const Tab* selected = state.SelectedTab();

    const std::vector<tab_search::Match> matches = tab_search::Rank(text, state, 5);
    std::vector<CommandSuggestion> tabs;
    for (const tab_search::Match& match : matches) {
        if (mode == CommandBarMode::EditCurrent && selected && match.tab->id == selected->id) continue;
        tabs.push_back({CommandSuggestion::Kind::SwitchTab, match.tab->url.value_or(""), match.tab->DisplayTitle(), "Switch to Tab",
                        match.tab->id, match.tab->faviconURL, {}});
    }
    const CommandSuggestion search{CommandSuggestion::Kind::Search, SearchURL(engine, text), text,
                                   std::string("Search ") + DisplayName(engine), {}, std::nullopt, {}};

    // Pages visited before, minus any already shown as a tab and the page you're on (Arc showed
    // neither): the Mac asks for six and keeps three.
    std::vector<HistoryEntry> visited;
    if (history) {
        std::vector<const std::string*> open;
        for (const tab_search::Match& match : matches) {
            if (match.tab->url) open.push_back(&*match.tab->url);
        }
        if (selected && selected->url) open.push_back(&*selected->url);
        for (HistoryEntry& entry : history->Search(text, 6, now)) {
            if (visited.size() == 3) break;
            const bool shown = std::any_of(open.begin(), open.end(), [&](const std::string* url) { return *url == entry.url; });
            if (!shown) visited.push_back(std::move(entry));
        }
    }
    const auto historyRows = [&](const std::optional<std::string>& except) {
        std::vector<CommandSuggestion> rows;
        for (const HistoryEntry& entry : visited) {
            if (except && entry.url == *except) continue;
            rows.push_back({CommandSuggestion::Kind::History, entry.url, entry.DisplayTitle(), {}, {}, std::nullopt, HistorySubtitle(entry)});
        }
        return rows;
    };

    std::vector<CommandSuggestion> out;
    if (url_input::LooksLikeURL(text)) {
        if (auto url = url_input::Resolve(text, engine)) {
            out.push_back({CommandSuggestion::Kind::Open, *url, *url, "Open", {}, std::nullopt, {}});
            out.insert(out.end(), tabs.begin(), tabs.end());
            const auto rows = historyRows(*url);
            out.insert(out.end(), rows.begin(), rows.end());
            out.push_back(search);
            return out;
        }
    }
    out.push_back(search);
    out.insert(out.end(), tabs.begin(), tabs.end());
    const auto rows = historyRows(std::nullopt);
    out.insert(out.end(), rows.begin(), rows.end());
    return out;
}

}  // namespace kite
