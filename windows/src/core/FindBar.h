#pragma once
// Find in page's model (Ctrl+F): what the Mac's find bar shows and asks the page for, without the
// view. Ports KiteCore's FindBarStyle.swift and the find half of AskOnPage.swift (the placeholder,
// the counter's label, when Return would ask), and the query logic of KiteMac's FindBar.swift
// (search, step, show), whose rules it keeps. Ask on Page's card and conversation aren't ported:
// Windows has the find bar only (Ask on Page is off by default on the Mac too).

#include <optional>
#include <string>
#include <string_view>

namespace kite {

namespace ask_on_page {

// The find field's placeholder, as Arc picks it: plain find with Ask on Page off, "Find or ask…"
// with it on, "Ask a question…" once a conversation has started.
std::string Placeholder(bool enabled, bool inConversation);

// Whether Return asks instead of finding: with Ask on Page on, a non-blank query the page has no
// match for (a finished search, 0 matches), or any query once the bar is in a conversation.
// `matches` is none until a search for the current query has come back.
bool IsAskMode(bool enabled, std::string_view query, std::optional<int> matches, bool inConversation);

// The counter's text when a finished search found nothing: Ask on Page on, Arc's SwiftUI view's;
// off, its AppKit FindInPageView's, in the FindInPageError red.
inline constexpr std::string_view kNoMatchesLabel = "No matches";
inline constexpr std::string_view kNotFoundLabel = "Not Found";

// The text right of the query: nothing for an empty query or before the search comes back, "No
// matches" / "Not Found" for none, else "active/total". `matches` is none when the engine only
// says found or not (WebKit), which shows nothing when found.
std::string MatchLabel(std::string_view query, bool found, std::optional<int> matches, std::optional<int> activeMatch, bool askEnabled);

}  // namespace ask_on_page

// Arc's two Ctrl+F bars: with Ask on Page off its AppKit FindInPageView, with it on its SwiftUI
// AskInPageView, a wider card. Points.
enum class FindBarStyle { Find, Ask };

namespace find_bar_style {

FindBarStyle ForAskEnabled(bool askEnabled);
// Preferred width; a card narrower than the bar narrows it.
double Width(FindBarStyle style);
// Gap to the content card's top and trailing edges, and the least gap to its leading edge.
double Inset(FindBarStyle style);
double CornerRadius(FindBarStyle style);
// The find view appears and goes at once; the ask card slides in from above and back up.
bool Slides(FindBarStyle style);
// The ask card is never taller than the content card less this.
inline constexpr double kAskVerticalMargin = 40;
// The find bar's divider: 1pt wide, 7pt from the bar's top, 14pt shorter than the bar.
double DividerHeight(double barHeight);
// How far above its place the ask card starts when it slides in, and how far up it goes to leave.
inline constexpr double kAskShowOffset = 300;
double AskHiddenOffset(double height);

struct Spring {
    double mass = 1, stiffness = 0, damping = 0;
};
// Arc's spring helper: stiffness (2π / response)² · mass, damping 4π · fraction · mass / response.
Spring MakeSpring(double response, double dampingFraction, double mass = 1);
// The ask card's, both ways: response 0.28 s, damping fraction 0.63.
Spring AskSpring();

}  // namespace find_bar_style

// The find bar's frame (FindBar.Metrics.size, and BrowserWindowController+PageCommands'
// constraints): pinned to the content card's top-right corner, `Inset` in, the style's width but
// never closer than `Inset` to the card's leading edge, 32pt tall. Points, as the card is given.
struct FindBarFrame {
    double left = 0, top = 0, width = 0, height = 0;
    bool operator==(const FindBarFrame&) const = default;
};
inline constexpr double kFindBarHeight = 32;
FindBarFrame FindBarFrameIn(double cardLeft, double cardTop, double cardRight, FindBarStyle style = FindBarStyle::Find);

// The bar's colours follow the app's appearance, as the Mac's do (NSApp.appearance, from the
// session's pageAppearance): "light" or "dark", else the system's.
bool FindBarIsDark(std::string_view pageAppearance, bool systemDark);

// What a page's find reported: found or not, and with Chromium the number of matches and which
// one is active (1-based).
struct FindResult {
    bool found = false;
    std::optional<int> matches;
    std::optional<int> activeMatch;
};

// The Mac FindBar's query: what's typed, the last query searched (so the same query steps to the
// next match and a changed one starts a new search), the matches the page reported and the
// counter's label. A Search with empty text means stop finding (and clear the highlights).
class FindQuery {
public:
    struct Search {
        std::string text;
        bool forward = true;
        bool findNext = false;
        bool operator==(const Search&) const = default;
    };

    // Ask on Page (it picks the "No matches" label); Windows has none yet, so it stays off.
    bool askEnabled = false;

    const std::string& Query() const { return query_; }
    // The counter's text, and whether it's the "Not Found" red.
    const std::string& Label() const { return label_; }
    bool LabelIsNotFound() const { return label_ == ask_on_page::kNotFoundLabel; }
    std::optional<int> Matches() const { return matches_; }
    // A search was asked for and not stopped since: the page's reports are for it.
    bool Searching() const { return searching_; }

    // The field's text changed (controlTextDidChange): the counter clears and a new search
    // starts, or finding stops for an empty field.
    Search TextChanged(std::string text);
    // Return, Shift+Return, the arrows, Ctrl+G and Ctrl+Shift+G: the next or previous match, or a
    // new search when the query changed since the last one. None for an empty query.
    std::optional<Search> Step(bool forward);
    // The page's report for the current search (FindBar.show).
    void Show(const FindResult& result);
    // The bar closed: empty, nothing searched (clearQuery).
    void Clear();
    // Finding stopped (the bar closed, or the page went): later reports are stale.
    void Stopped() { searching_ = false; }

private:
    std::string query_, lastQuery_, label_;
    std::optional<int> matches_;
    bool searching_ = false;
};

}  // namespace kite
