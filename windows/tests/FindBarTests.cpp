// Find in page (core/FindBar.h): the Mac's AskOnPageTests cases for the find bar
// (Tests/KiteCoreTests/AskOnPageTests.swift), named after them, then the query logic of
// KiteMac's FindBar.swift, which the Mac tests only through its UI, and the field's undo
// (core/TextUndo.h).

#include <cmath>
#include <string>

#include "Check.h"
#include "core/FindBar.h"
#include "core/TextUndo.h"

using namespace kite;

// AskOnPageTests.placeholderFollowsArc
TEST(placeholderFollowsArc) {
    CHECK(ask_on_page::Placeholder(false, false) == "Find in page…");
    CHECK(ask_on_page::Placeholder(false, true) == "Find in page…");
    CHECK(ask_on_page::Placeholder(true, false) == "Find or ask…");
    CHECK(ask_on_page::Placeholder(true, true) == "Ask a question…");
}

// AskOnPageTests.askModeOnlyWhenThePageHasNoMatch
TEST(askModeOnlyWhenThePageHasNoMatch) {
    CHECK(!ask_on_page::IsAskMode(false, "why", 0, true));
    CHECK(ask_on_page::IsAskMode(true, "why is the sky blue", 0, false));
    CHECK(!ask_on_page::IsAskMode(true, "sky", 3, false));
    // Still searching: not a question yet.
    CHECK(!ask_on_page::IsAskMode(true, "sky", std::nullopt, false));
    CHECK(!ask_on_page::IsAskMode(true, "   ", 0, false));
    // In a conversation every query is a question.
    CHECK(ask_on_page::IsAskMode(true, "sky", 3, true));
    CHECK(ask_on_page::IsAskMode(true, "", std::nullopt, true));
}

// AskOnPageTests.matchLabelFollowsArc
TEST(matchLabelFollowsArc) {
    for (bool ask : {true, false}) {
        CHECK(ask_on_page::MatchLabel("", false, 0, std::nullopt, ask) == "");
        CHECK(ask_on_page::MatchLabel("sky", true, 3, 2, ask) == "2/3");
        CHECK(ask_on_page::MatchLabel("sky", true, std::nullopt, std::nullopt, ask) == "");
    }
    // Ask on Page on: the SwiftUI view's "No matches"; off: the AppKit view's "Not Found".
    CHECK(ask_on_page::MatchLabel("sky", false, 0, std::nullopt, true) == "No matches");
    CHECK(ask_on_page::MatchLabel("sky", false, 0, std::nullopt, false) == "Not Found");
    // WebKit only says found or not.
    CHECK(ask_on_page::MatchLabel("sky", false, std::nullopt, std::nullopt, true) == "No matches");
    CHECK(ask_on_page::MatchLabel("sky", false, std::nullopt, std::nullopt, false) == "Not Found");
}

// AskOnPageTests.findBarStylesFollowArc
TEST(findBarStylesFollowArc) {
    using namespace find_bar_style;
    CHECK(ForAskEnabled(false) == FindBarStyle::Find);
    CHECK(Width(FindBarStyle::Find) == 300 && Inset(FindBarStyle::Find) == 10 && CornerRadius(FindBarStyle::Find) == 5);
    CHECK(Width(FindBarStyle::Ask) == 400 && Inset(FindBarStyle::Ask) == 20 && CornerRadius(FindBarStyle::Ask) == 10);
    CHECK(!Slides(FindBarStyle::Find) && Slides(FindBarStyle::Ask));
    // The find bar's divider: 1pt, 7pt from top and bottom of the 32pt bar, 1.5pt left of the close button.
    CHECK(DividerHeight(32) == 18);
    // The ask card's spring: Arc's (response 0.28 s, damping fraction 0.63) as CASpringAnimation terms.
    const Spring spring = AskSpring();
    CHECK(std::abs(spring.stiffness - 503.5) < 0.5);
    CHECK(std::abs(spring.damping - 28.27) < 0.01);
    CHECK(spring.mass == 1);
    CHECK(AskHiddenOffset(44) == 104);
}

// Windows' own: the bar's frame in the content card (BrowserWindowController+PageCommands'
// constraints), which the Mac sets with Auto Layout.
TEST(findBarSitsInTheCardsTopRightCorner) {
    // A 1280×820 window: the card runs from the sidebar's 240 to 1270, from 32 down.
    CHECK((FindBarFrameIn(240, 32, 1270) == FindBarFrame{960, 42, 300, 32}));
    // A card narrower than the bar narrows it, 10pt from either edge.
    CHECK((FindBarFrameIn(240, 32, 500) == FindBarFrame{250, 42, 240, 32}));
    // Never negative.
    CHECK(FindBarFrameIn(240, 32, 250).width == 0);
    // The ask card's inset is 20.
    CHECK((FindBarFrameIn(240, 32, 1270, FindBarStyle::Ask) == FindBarFrame{850, 52, 400, 32}));
}

TEST(findBarFollowsTheAppsAppearance) {
    CHECK(!FindBarIsDark("light", true));
    CHECK(FindBarIsDark("dark", false));
    CHECK(FindBarIsDark("automatic", true));
    CHECK(!FindBarIsDark("automatic", false));
    CHECK(FindBarIsDark("", true));
}

// FindBar.swift's search(): typing searches at once, with no debounce, from the first match.
TEST(typingSearchesFromTheFirstMatch) {
    FindQuery query;
    CHECK((query.TextChanged("d") == FindQuery::Search{"d", true, false}));
    CHECK(query.Searching());
    CHECK((query.TextChanged("do") == FindQuery::Search{"do", true, false}));
    CHECK(query.Query() == "do");
}

// FindBar.swift's step(forward:): the same query moves through its matches; a changed one starts again.
TEST(theSameQueryStepsToTheNextMatch) {
    FindQuery query;
    query.TextChanged("domain");
    CHECK((query.Step(true) == FindQuery::Search{"domain", true, true}));
    CHECK((query.Step(false) == FindQuery::Search{"domain", false, true}));
    query.TextChanged("domains");
    CHECK((query.Step(false) == FindQuery::Search{"domains", false, true}));
}

TEST(anEmptyQueryStopsFinding) {
    FindQuery query;
    query.TextChanged("sky");
    query.Show(FindResult{true, 3, 1});
    CHECK(query.Label() == "1/3");
    // Deleting the last character: finding stops and the counter clears.
    CHECK((query.TextChanged("") == FindQuery::Search{"", true, false}));
    CHECK(!query.Searching());
    CHECK(query.Label().empty());
    CHECK(!query.Matches());
    // Return in an empty field does nothing.
    CHECK(!query.Step(true));
}

// FindBar.swift's show(_:) and controlTextDidChange: a report fills the counter; the next
// keystroke clears it until its own search comes back.
TEST(theCounterShowsThePagesReport) {
    FindQuery query;
    query.TextChanged("sky");
    CHECK(query.Label().empty());
    query.Show(FindResult{true, 12, 0});  // Chromium's first, interim report
    CHECK(query.Label() == "0/12");
    query.Show(FindResult{true, 12, 3});
    CHECK(query.Label() == "3/12");
    CHECK(query.Matches() == 12);
    CHECK(!query.LabelIsNotFound());
    query.TextChanged("skyz");
    CHECK(query.Label().empty());
    CHECK(!query.Matches());
    query.Show(FindResult{false, 0, 0});
    CHECK(query.Label() == "Not Found");
    CHECK(query.LabelIsNotFound());
    CHECK(query.Matches() == 0);
    // A found-or-not engine: found counts as one match, and shows no counter.
    query.Show(FindResult{true, std::nullopt, std::nullopt});
    CHECK(query.Matches() == 1);
    CHECK(query.Label().empty());
}

TEST(closingTheBarClearsTheQuery) {
    FindQuery query;
    query.TextChanged("sky");
    query.Show(FindResult{true, 2, 1});
    query.Clear();
    CHECK(query.Query().empty());
    CHECK(query.Label().empty());
    CHECK(!query.Searching());
    // Reopened and typed again, the same text is a new search, not a step.
    CHECK((query.TextChanged("sky") == FindQuery::Search{"sky", true, false}));
}

TEST(stoppedSearchesIgnoreLateReports) {
    FindQuery query;
    query.TextChanged("sky");
    query.Stopped();
    CHECK(!query.Searching());
    CHECK(query.Step(true)->findNext);  // a step after a stop searches again
    CHECK(query.Searching());
}

// core/TextUndo.h: NSTextView's grouping, as the Mac's find field undoes.
TEST(typingUndoesAsOneGroup) {
    TextUndo<std::string> undo;
    std::string text;
    for (char c : std::string("sky")) {
        undo.Record(text, TextUndo<std::string>::Kind::Typing);
        text += c;
    }
    // Backspace is typing too.
    undo.Record(text, TextUndo<std::string>::Kind::Typing);
    text.pop_back();
    CHECK(text == "sk");
    auto back = undo.Undo(text);
    CHECK(back && back->empty());
    CHECK(!undo.CanUndo());
    auto forward = undo.Redo("");
    CHECK(forward && *forward == "sk");
}

TEST(movingTheCaretStartsANewGroup) {
    TextUndo<std::string> undo;
    undo.Record("", TextUndo<std::string>::Kind::Typing);
    undo.Record("a", TextUndo<std::string>::Kind::Typing);
    undo.BreakTyping();
    undo.Record("ab", TextUndo<std::string>::Kind::Typing);
    CHECK(undo.Undo("abc") == std::optional<std::string>("ab"));
    CHECK(undo.Undo("ab") == std::optional<std::string>(""));
    CHECK(!undo.Undo(""));
}

TEST(aPasteIsItsOwnGroup) {
    TextUndo<std::string> undo;
    undo.Record("", TextUndo<std::string>::Kind::Typing);
    undo.Record("a", TextUndo<std::string>::Kind::Other);  // pasted "bc"
    undo.Record("abc", TextUndo<std::string>::Kind::Typing);
    CHECK(undo.Undo("abcd") == std::optional<std::string>("abc"));
    CHECK(undo.Undo("abc") == std::optional<std::string>("a"));
    CHECK(undo.Undo("a") == std::optional<std::string>(""));
}

TEST(aNewEditDropsTheRedo) {
    TextUndo<std::string> undo;
    undo.Record("", TextUndo<std::string>::Kind::Typing);
    CHECK(undo.Undo("a") == std::optional<std::string>(""));
    CHECK(undo.CanRedo());
    undo.Record("", TextUndo<std::string>::Kind::Typing);
    CHECK(!undo.CanRedo());
    undo.Reset();
    CHECK(!undo.CanUndo() && !undo.CanRedo());
}

TEST(undoKeepsTheLastHundredGroups) {
    TextUndo<std::string> undo;
    for (int i = 0; i < 150; ++i) undo.Record(std::to_string(i), TextUndo<std::string>::Kind::Other);
    size_t count = 0;
    std::string current = "150", last;
    while (auto back = undo.Undo(current)) {
        last = current = *back;
        ++count;
    }
    CHECK(count == TextUndo<std::string>::kLimit);
    CHECK(last == "50");
}
