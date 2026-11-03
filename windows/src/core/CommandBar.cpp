// See CommandBar.h.

#include "core/CommandBar.h"

#include <algorithm>

#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Url.h"

namespace kite {
namespace {

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

std::string TrimmedLowercase(std::string_view text) { return unicode::Lowercased(unicode::Trim(text)); }

// Every occurrence of `from` replaced, as Foundation's replacingOccurrences(of:with:).
std::string ReplaceAll(std::string text, std::string_view from, std::string_view to) {
    for (size_t at = text.find(from); at != std::string::npos; at = text.find(from, at + to.size())) {
        text.replace(at, from.size(), to);
    }
    return text;
}

bool IsAscii(std::string_view text) {
    return std::all_of(text.begin(), text.end(), [](char b) { return static_cast<unsigned char>(b) < 0x80; });
}
char AsciiLower(char b) { return b >= 'A' && b <= 'Z' ? static_cast<char>(b + 32) : b; }
bool IsAsciiWordCharacter(char b) { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9'); }

// Text folded for comparing (lowercased, decomposed) with where its Characters start:
// comparing code points and starts compares Characters the way Swift does.
struct Folded {
    std::u32string text;
    std::vector<bool> starts;

    explicit Folded(std::string_view utf8) : text(unicode::Folded(utf8)), starts(unicode::CharacterStarts(text)) {}

    bool IsWordStart(size_t at) const {
        const auto word = [&](size_t i) { return unicode::IsLetter(text[i]) || unicode::IsNumber(text[i]); };
        if (!starts[at] || !word(at)) return false;
        if (at == 0) return true;
        size_t previous = at - 1;
        while (previous > 0 && !starts[previous]) --previous;  // the previous Character's first scalar
        return !word(previous);
    }

    // `part`'s Characters are this text's, from `at`.
    bool MatchesAt(size_t at, const Folded& part) const {
        if (at + part.text.size() > text.size()) return false;
        return std::equal(part.text.begin(), part.text.end(), text.begin() + static_cast<std::ptrdiff_t>(at)) &&
               std::equal(part.starts.begin(), part.starts.end(), starts.begin() + static_cast<std::ptrdiff_t>(at));
    }
};

// What's typed, lowercased and decomposed, as ASCII bytes or as Characters.
struct Query {
    Folded folded;
    std::string ascii;          // the same, when it's all ASCII
    bool isAscii;
    bool allWordCharacters;     // every Character a letter or number: it can start a word

    explicit Query(std::string_view lowered) : folded(lowered) {
        isAscii = std::all_of(folded.text.begin(), folded.text.end(), [](char32_t c) { return c < 0x80; });
        if (isAscii) {
            for (char32_t c : folded.text) ascii += static_cast<char>(c);
        }
        allWordCharacters = true;
        for (size_t i = 0; i < folded.text.size(); ++i) {
            if (folded.starts[i] && !unicode::IsLetter(folded.text[i]) && !unicode::IsNumber(folded.text[i])) allWordCharacters = false;
        }
    }
};

// One of a tab's texts (title, host, address). Most are ASCII, which lowercasing,
// decomposition and grapheme breaking leave as they are (but for CR LF, one Character):
// those are compared in place, byte by byte, with nothing allocated. Anything else is
// folded once and compared by Characters.
class Field {
public:
    explicit Field(std::string_view raw) : raw_(raw), ascii_(IsAscii(raw)) {}

    bool HasPrefix(const Query& q) const {
        if (ascii_) return q.isAscii && AsciiMatchesAt(0, q.ascii) && AsciiBoundary(q.ascii.size());
        return Text().MatchesAt(0, q.folded) && Text().starts[q.folded.text.size()];
    }

    bool Contains(const Query& q) const {
        if (ascii_) {
            if (!q.isAscii) return false;
            for (size_t at = 0; at + q.ascii.size() <= raw_.size(); ++at) {
                if (AsciiMatchesAt(at, q.ascii) && AsciiBoundary(at) && AsciiBoundary(at + q.ascii.size())) return true;
            }
            return false;
        }
        const Folded& text = Text();
        for (size_t at = 0; at + q.folded.text.size() <= text.text.size(); ++at) {
            if (text.starts[at] && text.MatchesAt(at, q.folded) && text.starts[at + q.folded.text.size()]) return true;
        }
        return false;
    }

    // Some word of the field (a run of letters and numbers) starts with what's typed.
    bool WordHasPrefix(const Query& q) const {
        if (!q.allWordCharacters) return false;
        if (ascii_) {
            if (!q.isAscii) return false;
            for (size_t at = 0; at < raw_.size(); ++at) {
                const bool starts = IsAsciiWordCharacter(raw_[at]) && (at == 0 || !IsAsciiWordCharacter(raw_[at - 1]));
                if (starts && AsciiMatchesAt(at, q.ascii)) return true;
            }
            return false;
        }
        const Folded& text = Text();
        for (size_t at = 0; at + q.folded.text.size() <= text.text.size(); ++at) {
            if (text.IsWordStart(at) && text.MatchesAt(at, q.folded) && text.starts[at + q.folded.text.size()]) return true;
        }
        return false;
    }

private:
    bool AsciiMatchesAt(size_t at, std::string_view lowered) const {
        if (at + lowered.size() > raw_.size()) return false;
        for (size_t i = 0; i < lowered.size(); ++i) {
            if (AsciiLower(raw_[at + i]) != lowered[i]) return false;
        }
        return true;
    }
    // Between two Characters: anywhere in ASCII but inside CR LF.
    bool AsciiBoundary(size_t at) const { return at == 0 || at >= raw_.size() || !(raw_[at - 1] == '\r' && raw_[at] == '\n'); }

    const Folded& Text() const {
        if (!folded_) folded_.emplace(raw_);
        return *folded_;
    }

    std::string_view raw_;
    bool ascii_;
    mutable std::optional<Folded> folded_;
};

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

std::vector<CommandSuggestion> CommandBarSuggestions(std::string_view input, const BrowserState& state, CommandBarMode mode) {
    const std::string text(unicode::Trim(input));
    if (text.empty()) return {};
    const SearchEngine engine = SearchEngineFromRaw(state.searchEngine).value_or(SearchEngine::Google);
    const Tab* selected = state.SelectedTab();

    std::vector<CommandSuggestion> tabs;
    for (const tab_search::Match& match : tab_search::Rank(text, state, 5)) {
        if (mode == CommandBarMode::EditCurrent && selected && match.tab->id == selected->id) continue;
        tabs.push_back({CommandSuggestion::Kind::SwitchTab, match.tab->url.value_or(""), match.tab->DisplayTitle(), "Switch to Tab",
                        match.tab->id, match.tab->faviconURL});
    }
    const CommandSuggestion search{CommandSuggestion::Kind::Search, SearchURL(engine, text), text,
                                   std::string("Search ") + DisplayName(engine), {}, std::nullopt};

    std::vector<CommandSuggestion> out;
    if (url_input::LooksLikeURL(text)) {
        if (auto url = url_input::Resolve(text, engine)) {
            out.push_back({CommandSuggestion::Kind::Open, *url, *url, "Open", {}, std::nullopt});
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
