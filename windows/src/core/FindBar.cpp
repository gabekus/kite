// See FindBar.h.

#include "core/FindBar.h"

#include <algorithm>
#include <numbers>

#include "core/Unicode.h"

namespace kite {

namespace ask_on_page {

std::string Placeholder(bool enabled, bool inConversation) {
    if (!enabled) return "Find in page…";
    return inConversation ? "Ask a question…" : "Find or ask…";
}

bool IsAskMode(bool enabled, std::string_view query, std::optional<int> matches, bool inConversation) {
    if (!enabled) return false;
    // Swift's trimmingCharacters(in: .whitespaces): blank is nothing but whitespace.
    const bool blank = unicode::Trim(query).empty();
    if (!blank && matches == 0) return true;
    return inConversation;
}

std::string MatchLabel(std::string_view query, bool found, std::optional<int> matches, std::optional<int> activeMatch, bool askEnabled) {
    if (query.empty()) return {};
    const std::optional<int> total = matches ? matches : (found ? std::nullopt : std::optional<int>(0));
    if (!total) return {};
    if (*total < 1) return std::string(askEnabled ? kNoMatchesLabel : kNotFoundLabel);
    return std::to_string(activeMatch.value_or(0)) + "/" + std::to_string(*total);
}

}  // namespace ask_on_page

namespace find_bar_style {

FindBarStyle ForAskEnabled(bool askEnabled) { return askEnabled ? FindBarStyle::Ask : FindBarStyle::Find; }
double Width(FindBarStyle style) { return style == FindBarStyle::Find ? 300 : 400; }
double Inset(FindBarStyle style) { return style == FindBarStyle::Find ? 10 : 20; }
double CornerRadius(FindBarStyle style) { return style == FindBarStyle::Find ? 5 : 10; }
bool Slides(FindBarStyle style) { return style == FindBarStyle::Ask; }
double DividerHeight(double barHeight) { return barHeight - 14; }
double AskHiddenOffset(double height) { return 20 + height + kAskVerticalMargin; }

Spring MakeSpring(double response, double dampingFraction, double mass) {
    const double omega = 2 * std::numbers::pi / response;
    return Spring{mass, omega * omega * mass, 4 * std::numbers::pi * dampingFraction * mass / response};
}

Spring AskSpring() { return MakeSpring(0.28, 0.63); }

}  // namespace find_bar_style

FindBarFrame FindBarFrameIn(double cardLeft, double cardTop, double cardRight, FindBarStyle style) {
    const double inset = find_bar_style::Inset(style);
    const double right = cardRight - inset;
    // The preferred width gives way to the leading inset, so a narrow card narrows the bar.
    const double width = std::max(0.0, std::min(find_bar_style::Width(style), right - (cardLeft + inset)));
    return FindBarFrame{right - width, cardTop + inset, width, kFindBarHeight};
}

bool FindBarIsDark(std::string_view pageAppearance, bool systemDark) {
    if (pageAppearance == "light") return false;
    if (pageAppearance == "dark") return true;
    return systemDark;
}

FindQuery::Search FindQuery::TextChanged(std::string text) {
    query_ = std::move(text);
    lastQuery_.clear();
    matches_.reset();
    label_.clear();
    if (query_.empty()) {
        searching_ = false;
        return Search{"", true, false};
    }
    return *Step(true);
}

std::optional<FindQuery::Search> FindQuery::Step(bool forward) {
    if (query_.empty()) return std::nullopt;
    // A changed query starts a new search; the same one moves to the next match.
    Search search{query_, forward, query_ == lastQuery_};
    lastQuery_ = query_;
    searching_ = true;
    return search;
}

void FindQuery::Show(const FindResult& result) {
    matches_ = result.matches ? result.matches : std::optional<int>(result.found ? 1 : 0);
    label_ = ask_on_page::MatchLabel(query_, result.found, result.matches, result.activeMatch, askEnabled);
}

void FindQuery::Clear() {
    query_.clear();
    lastQuery_.clear();
    matches_.reset();
    label_.clear();
    searching_ = false;
}

}  // namespace kite
