// See CommandBar.h.

#include "core/CommandBar.h"

#include <algorithm>

#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Url.h"

namespace kite {
namespace {

// Text as Swift's String sees it: a sequence of Characters (grapheme clusters), so
// prefixes and substrings never end inside one (typing "e" doesn't match "e" + U+0301).
using Chars = std::vector<std::u32string>;

Chars Split(std::string_view utf8) { return unicode::Characters(utf8); }

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

std::string TrimmedLowercase(std::string_view text) { return unicode::Lowercased(unicode::Trim(text)); }

// Every occurrence of `from` replaced, as Foundation's replacingOccurrences(of:with:).
std::string ReplaceAll(std::string text, std::string_view from, std::string_view to) {
    for (size_t at = text.find(from); at != std::string::npos; at = text.find(from, at + to.size())) {
        text.replace(at, from.size(), to);
    }
    return text;
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

std::optional<int> Score(std::string_view query, const Tab& tab) {
    // A renamed tab is found by its name as well as its page's title.
    std::string titleText = tab.customTitle ? *tab.customTitle + " " + tab.title : tab.title;
    const Chars title = Split(unicode::Lowercased(titleText));
    const std::string address = tab.url.value_or("");
    const Chars host = Split(ReplaceAll(unicode::Lowercased(url::Host(address).value_or("")), "www.", ""));
    const Chars url = Split(unicode::Lowercased(address));
    const Chars q = Split(query);

    if (HasPrefix(title, q)) return 100;
    for (const Chars& word : Words(title)) {
        if (HasPrefix(word, q)) return 80;
    }
    if (HasPrefix(host, q)) return 70;
    if (Contains(title, q)) return 60;
    if (Contains(url, q)) return 40;
    return std::nullopt;
}

std::vector<Match> Rank(std::string_view query, const BrowserState& state, size_t limit) {
    const std::string q = TrimmedLowercase(query);
    if (q.empty()) return {};
    std::vector<Match> matches;
    for (const Tab& tab : state.Favorites()) {
        if (auto score = Score(q, tab)) matches.push_back({&tab, state.selectedSpaceID, *score + 5});
    }
    const size_t favorites = state.Favorites().size();
    for (size_t s = 0; s < state.spaces.size(); ++s) {
        const Space& space = state.spaces[s];
        // The space's pinned tabs (folders included), then its unpinned ones: SidebarTabs
        // without the favorites at its start.
        const std::vector<const Tab*> tabs = state.SidebarTabs(s);
        for (size_t i = favorites; i < tabs.size(); ++i) {
            auto score = Score(q, *tabs[i]);
            if (!score) continue;
            matches.push_back({tabs[i], space.id, *score + (space.id == state.selectedSpaceID ? 5 : 0)});
        }
    }
    std::stable_sort(matches.begin(), matches.end(), [](const Match& a, const Match& b) {
        return a.score != b.score ? a.score > b.score : a.tab->lastActiveAt > b.tab->lastActiveAt;
    });
    if (matches.size() > limit) matches.resize(limit);
    return matches;
}

}  // namespace tab_search

std::vector<CommandSuggestion> CommandBarSuggestions(std::string_view input, const BrowserState& state, CommandBarMode mode) {
    const std::string text(unicode::Trim(input));
    if (text.empty()) return {};
    const SearchEngine engine = SearchEngineFromRaw(state.searchEngine).value_or(SearchEngine::Google);
    const Tab* selected = state.SelectedTab();

    std::vector<CommandSuggestion> tabs;
    for (const tab_search::Match& match : tab_search::Rank(text, state, 5)) {
        if (mode == CommandBarMode::EditCurrent && selected && match.tab->id == selected->id) continue;
        tabs.push_back({CommandSuggestion::Kind::SwitchTab, match.tab->url.value_or(""), {}, match.tab->id});
    }
    const CommandSuggestion search{CommandSuggestion::Kind::Search, SearchURL(engine, text), text, {}};

    std::vector<CommandSuggestion> out;
    if (url_input::LooksLikeURL(text)) {
        if (auto url = url_input::Resolve(text, engine)) {
            out.push_back({CommandSuggestion::Kind::Open, *url, {}, {}});
            out.insert(out.end(), tabs.begin(), tabs.end());
            out.push_back(search);
            return out;
        }
    }
    out.push_back(search);
    out.insert(out.end(), tabs.begin(), tabs.end());
    return out;
}

}  // namespace kite
