// The icon picker (core/SpaceIconPicker.h): the Mac's SpaceIconPicker and EmojiCatalog
// (SpaceIconPicker.swift), ArcMetrics.SpaceIconPicker, SpaceIconImages.discard and the header's
// icon button (SpaceHeaderRowCell.openPicker). The Mac has no tests of its own for any of them
// (SwiftUI views, checked by eye), so these check what its code does: the catalog as Swift splits
// it, search by ICU's names, the grid's layout and hits, the tabs, the category bar's scroll, a
// pick and the picture it leaves behind, and where the popover hangs. SpacesTests'
// anIconIsOneCharacter and anImageIconIsAFileNameInTheIconsFolder, which pick an icon, are
// SpaceEditingTests' (W9d).
//
// The expected counts and search results were worked out apart from this code, from the Swift
// file with Python's unicodedata (Unicode 14.0) and a split of the catalog's strings by hand.

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <sstream>
#include <optional>
#include <string>
#include <vector>

#include "Check.h"
#include "core/Sidebar.h"
#include "core/SpaceIconPicker.h"
#include "core/Unicode.h"

using namespace kite;

namespace {

namespace M = icon_picker_metrics;
using Target = IconPickerHit::Target;

// Code points as hex, for comparing emoji without writing them out.
std::string Hex(const std::string& text) {
    std::string out;
    char buffer[16];
    for (const char32_t c : unicode::Decode(text)) {
        std::snprintf(buffer, sizeof buffer, "%s%X", out.empty() ? "" : " ", static_cast<unsigned>(c));
        out += buffer;
    }
    return out;
}

std::vector<std::string> Hexes(const std::vector<std::string>& texts, size_t count) {
    std::vector<std::string> out;
    for (size_t i = 0; i < texts.size() && i < count; ++i) out.push_back(Hex(texts[i]));
    return out;
}

BrowserState TwoSpaces(const std::string& icon) {
    BrowserState state;
    state.spaces.clear();
    state.AddSpace("A", icon, Theme::Presets()[0]);
    state.AddSpace("B", "", Theme::Presets()[1]);
    state.SelectSpaceAt(0);
    return state;
}

}  // namespace

// EmojiCatalog.categories: eight, in Arc's order, each with its bar symbol and its emoji split
// into Characters as Swift's chars() does (a ZWJ sequence, a keycap and a flag are one each).
TEST(theCatalogIsTheMacsSplitIntoCharacters) {
    const auto& categories = EmojiCategories();
    CHECK(categories.size() == 8);
    const std::vector<std::string> names = {"Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
                                            "Travel & Places",  "Objects",          "Symbols",      "Flags"};
    const std::vector<std::string> symbols = {"face.smiling", "sun.max", "cup.and.saucer", "rosette", "car", "lightbulb", "heart", "flag"};
    const std::vector<size_t> counts = {160, 146, 108, 78, 116, 168, 266, 59};
    for (size_t i = 0; i < categories.size() && i < 8; ++i) {
        CHECK(categories[i].name == names[i]);
        CHECK(categories[i].symbol == symbols[i]);
        CHECK(categories[i].emoji.size() == counts[i]);
        // Every bar symbol has a glyph in both fonts.
        CHECK(categories[i].glyph.fluent != 0 && categories[i].glyph.mdl2 != 0);
    }
    CHECK(AllEmoji().size() == 1101);
    CHECK(Hex(AllEmoji().front()) == "1F600");
    // ☺️ (with its variation selector), 😮‍💨 (a ZWJ sequence), #️⃣ (a keycap), 🇦🇪 (the last flag).
    CHECK(std::find(AllEmoji().begin(), AllEmoji().end(), "\xE2\x98\xBA\xEF\xB8\x8F") != AllEmoji().end());
    CHECK(Hex(categories[0].emoji[45]) == "1F62E 200D 1F4A8");
    CHECK(std::count_if(AllEmoji().begin(), AllEmoji().end(), [](const std::string& e) { return Hex(e) == "23 FE0F 20E3"; }) == 1);
    CHECK(Hex(AllEmoji().back()) == "1F1E6 1F1EA");
    // No emoji is in the catalog twice, so a category's first is where its own section starts
    // (scrollTo finds the first cell with that id).
    std::vector<std::string> sorted = AllEmoji();
    std::sort(sorted.begin(), sorted.end());
    CHECK(std::adjacent_find(sorted.begin(), sorted.end()) == sorted.end());
    CHECK(RemoveIconGlyph().fluent == u'');
}

// Every emoji in the grid is one Character, so picking it sets it as it is (setSpaceIcon keeps
// icon.first).
TEST(everyEmojiSetsAsItIs) {
    BrowserState state = TwoSpaces("");
    const std::string id = state.spaces[0].id;
    for (const std::string& emoji : AllEmoji()) {
        state.SetSpaceIcon(id, emoji);
        CHECK(state.spaces[0].icon == emoji);
    }
}

// EmojiCatalog.name: ICU's Any-Name, "\N{NAME}" a code point, lowercased.
TEST(anEmojisNameIsICUsLowercased) {
    CHECK(EmojiName("\xF0\x9F\x98\x80") == "\\n{grinning face}");
    CHECK(EmojiName("\xE2\x98\xBA\xEF\xB8\x8F") == "\\n{white smiling face}\\n{variation selector-16}");
    CHECK(EmojiName("\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8") ==
          "\\n{regional indicator symbol letter u}\\n{regional indicator symbol letter s}");
    CHECK(EmojiName("#\xEF\xB8\x8F\xE2\x83\xA3") == "\\n{number sign}\\n{variation selector-16}\\n{combining enclosing keycap}");
    // Nothing the catalog doesn't hold.
    CHECK(EmojiName("A").empty());
    CHECK(EmojiName("").empty());
    for (const std::string& emoji : AllEmoji()) CHECK(!EmojiName(emoji).empty());
}

// The Mac's `emoji`: the name holds the query, trimmed of spaces and lowercased. Flags are named
// by their letters, so "united" finds none and "cat" finds every regional indicator.
TEST(searchMatchesTheNames) {
    CHECK(Hexes(EmojiMatching("grinning"), 10) == (std::vector<std::string>{"1F600", "1F601", "1F929", "1F92A"}));
    CHECK(EmojiMatching("  GRINNING\t") == EmojiMatching("grinning"));
    CHECK(EmojiMatching("cat").size() == 55);
    CHECK(Hexes(EmojiMatching("cat"), 3) == (std::vector<std::string>{"1F431", "1F408", "2716 FE0F"}));
    CHECK(EmojiMatching("united").empty());
    CHECK(EmojiMatching("flag").size() == 12);
    CHECK(EmojiMatching("keycap").size() == 13);
    CHECK(Hexes(EmojiMatching("zero width"), 4) ==
          (std::vector<std::string>{"1F62E 200D 1F4A8", "1F3F3 FE0F 200D 1F308", "1F3F3 FE0F 200D 26A7 FE0F", "1F3F4 200D 2620 FE0F"}));
    CHECK(Hexes(EmojiMatching("\\n{red apple}"), 2) == (std::vector<std::string>{"1F34E"}));
    CHECK(EmojiMatching("regional indicator symbol letter u").size() == 3);
    // Every name has "\n{", and nothing at all is everything.
    CHECK(EmojiMatching("n{").size() == 1101);
    CHECK(EmojiMatching("").size() == 1101);
    CHECK(EmojiMatching(" \t ").size() == 1101);
    // .whitespaces trims spaces and tabs, not a line break, so that's searched for (and found in no name).
    CHECK(EmojiMatching("\n").empty());
}

// It opens on the tab the icon came from (an emoji's or none's Emoji, a symbol's Icon); a
// picture's would be Image, which Windows doesn't have yet.
TEST(itOpensOnTheIconsTab) {
    CHECK(IconPickerOpeningTab("") == IconPickerTab::Emoji);
    CHECK(IconPickerOpeningTab("\xF0\x9F\x9A\x80") == IconPickerTab::Emoji);
    CHECK(IconPickerOpeningTab("symbol:star.fill") == IconPickerTab::Icon);
    CHECK(IconPickerOpeningTab("image:3F2A.png") == IconPickerTab::Emoji);
    BrowserState state = TwoSpaces("symbol:leaf.fill");
    const auto picker = OpenIconPicker(state, state.spaces[0].id);
    CHECK(picker && picker->tab == IconPickerTab::Icon && picker->query.empty() && picker->category == 0 && picker->scroll == 0);
    CHECK(!OpenIconPicker(state, "nope"));
    CHECK(IconPickerTabTitle(IconPickerTab::Emoji) == "Emoji");
    CHECK(IconPickerTabTitle(IconPickerTab::Icon) == "Icon");
    CHECK(IconPickerTabTitle(IconPickerTab::Image) == "Image");
    CHECK(IconPickerTabAvailable(IconPickerTab::Icon) && !IconPickerTabAvailable(IconPickerTab::Image));
}

// The SwiftUI layout with ArcMetrics.SpaceIconPicker: 272 wide, inset 12; the tabs (and the bin
// once there's an icon), Search 10 under them, the 165pt grid, a divider and the category bar;
// the Icon tab's 7 rows of 8 under the tabs, 12 either side.
TEST(theLayoutIsTheMacs) {
    const IconPickerLayout emoji = LayOutIconPicker(IconPickerTab::Emoji, true);
    CHECK(emoji.width == 272);
    CHECK(emoji.tabs == (PickerRect{12, 12, 237, 34}));
    CHECK(emoji.remove == (PickerRect{245, 12, 260, 34}));
    CHECK(emoji.segments.size() == 3 && emoji.segments[1] == (PickerRect{87, 12, 162, 34}));
    CHECK(emoji.search == (PickerRect{12, 44, 260, 66}));
    CHECK(emoji.grid == (PickerRect{0, 66, 272, 231}));
    CHECK(emoji.divider == (PickerRect{12, 231, 260, 232}));
    CHECK(emoji.categories.size() == 8 && emoji.categories[0] == (PickerRect{12, 232, 43, 262}) &&
          emoji.categories[7] == (PickerRect{229, 232, 260, 262}));
    CHECK(emoji.height == 268);
    CHECK(emoji.columns == 7 && emoji.pitch == 33.5f && emoji.gridLeft == 18.75f);
    // No icon, no bin: the tabs take the row.
    const IconPickerLayout bare = LayOutIconPicker(IconPickerTab::Emoji, false);
    CHECK(!bare.remove && bare.tabs == (PickerRect{12, 12, 260, 34}));
    const IconPickerLayout icon = LayOutIconPicker(IconPickerTab::Icon, true);
    CHECK(!icon.search && !icon.divider && icon.categories.empty());
    CHECK(icon.grid == (PickerRect{0, 46, 272, 277}));
    CHECK(icon.height == 289);
    CHECK(icon.columns == 8 && icon.pitch == 31 && icon.gridLeft == 12);
}

// cell(): each the emoji's pitch wide and a row tall, centred on its column, the emoji grid
// scrolled under its scroll view; only the rows the view shows are drawn.
TEST(cellsSitOnTheirColumnsAndScroll) {
    const IconPickerLayout emoji = LayOutIconPicker(IconPickerTab::Emoji, false);
    CHECK(IconPickerCellFrame(emoji, 0, 0) == (PickerRect{18.75f, 66, 52.25f, 99}));
    CHECK(IconPickerCellFrame(emoji, 8, 0) == (PickerRect{52.25f, 99, 85.75f, 132}));
    CHECK(IconPickerCellFrame(emoji, 8, 33) == (PickerRect{52.25f, 66, 85.75f, 99}));
    CHECK(IconPickerRows(1101, 7) == 158 && IconPickerRows(0, 7) == 0 && IconPickerRows(7, 7) == 1 && IconPickerRows(8, 7) == 2);
    CHECK(IconPickerMaxScroll(1101) == 158 * 33 - 165);
    CHECK(IconPickerMaxScroll(4) == 0);
    CHECK(IconPickerVisibleRows(emoji, 1101, 0) == (std::pair<size_t, size_t>{0, 5}));
    CHECK(IconPickerVisibleRows(emoji, 1101, 10) == (std::pair<size_t, size_t>{0, 6}));
    CHECK(IconPickerVisibleRows(emoji, 1101, 33) == (std::pair<size_t, size_t>{1, 6}));
    CHECK(IconPickerVisibleRows(emoji, 1101, IconPickerMaxScroll(1101)) == (std::pair<size_t, size_t>{153, 158}));
    CHECK(IconPickerVisibleRows(emoji, 4, 0) == (std::pair<size_t, size_t>{0, 1}));
    CHECK(IconPickerVisibleRows(emoji, 0, 0) == (std::pair<size_t, size_t>{0, 0}));
    // The Icon tab's columns are 31 apart, so neighbouring cells overlap by 2.5pt.
    const IconPickerLayout icon = LayOutIconPicker(IconPickerTab::Icon, false);
    CHECK(IconPickerCellFrame(icon, 0, 0) == (PickerRect{10.75f, 46, 44.25f, 79}));
    CHECK(IconPickerCellFrame(icon, 1, 0) == (PickerRect{41.75f, 46, 75.25f, 79}));
}

// A point hits the control it's over; in the grid, the cell it's in where the scroll view shows
// it, the later where two overlap; nothing in the margins, past the last cell or on Image.
TEST(pointsHitWhatTheyreOver) {
    IconPickerState state;
    const IconPickerLayout emoji = LayOutIconPicker(IconPickerTab::Emoji, true);
    const size_t all = AllEmoji().size();
    CHECK(IconPickerHitTest(emoji, state, all, 20, 20) == (IconPickerHit{Target::Tab, 0}));
    CHECK(IconPickerHitTest(emoji, state, all, 100, 20) == (IconPickerHit{Target::Tab, 1}));
    CHECK(IconPickerHitTest(emoji, state, all, 200, 20) == IconPickerHit{});  // Image: disabled
    CHECK(IconPickerHitTest(emoji, state, all, 250, 20) == (IconPickerHit{Target::Remove, 0}));
    CHECK(IconPickerHitTest(emoji, state, all, 240, 20) == IconPickerHit{});  // the gap before it
    CHECK(IconPickerHitTest(emoji, state, all, 100, 50) == (IconPickerHit{Target::Search, 0}));
    CHECK(IconPickerHitTest(emoji, state, all, 35, 70) == (IconPickerHit{Target::Cell, 0}));
    CHECK(IconPickerHitTest(emoji, state, all, 35, 230.9f) == (IconPickerHit{Target::Cell, 28}));
    CHECK(IconPickerHitTest(emoji, state, all, 18.7f, 70) == IconPickerHit{});
    CHECK(IconPickerHitTest(emoji, state, all, 253.25f, 70) == IconPickerHit{});
    CHECK(IconPickerHitTest(emoji, state, all, 253.2f, 70) == (IconPickerHit{Target::Cell, 6}));
    CHECK(IconPickerHitTest(emoji, state, all, 100, 231.5f) == IconPickerHit{});  // the divider
    CHECK(IconPickerHitTest(emoji, state, all, 20, 240) == (IconPickerHit{Target::Category, 0}));
    CHECK(IconPickerHitTest(emoji, state, all, 259, 261) == (IconPickerHit{Target::Category, 7}));
    // Scrolled a row, the top row is the second.
    state.scroll = 33;
    CHECK(IconPickerHitTest(emoji, state, all, 35, 70) == (IconPickerHit{Target::Cell, 7}));
    // Four matches: one row, and nothing past the fourth.
    state.scroll = 0;
    CHECK(IconPickerHitTest(emoji, state, 4, 140, 70) == (IconPickerHit{Target::Cell, 3}));
    CHECK(IconPickerHitTest(emoji, state, 4, 170, 70) == IconPickerHit{});
    CHECK(IconPickerHitTest(emoji, state, 4, 35, 100) == IconPickerHit{});
    // The Icon tab: overlapping frames go to the later cell.
    state.tab = IconPickerTab::Icon;
    state.scroll = 500;  // the emoji grid's; the Icon tab doesn't scroll
    const IconPickerLayout icon = LayOutIconPicker(IconPickerTab::Icon, false);
    const size_t symbols = IconTabSymbols().size();
    CHECK(IconPickerHitTest(icon, state, symbols, 10.75f, 50) == (IconPickerHit{Target::Cell, 0}));
    CHECK(IconPickerHitTest(icon, state, symbols, 10.7f, 50) == IconPickerHit{});
    CHECK(IconPickerHitTest(icon, state, symbols, 41.7f, 50) == (IconPickerHit{Target::Cell, 0}));
    CHECK(IconPickerHitTest(icon, state, symbols, 43, 50) == (IconPickerHit{Target::Cell, 1}));
    CHECK(IconPickerHitTest(icon, state, symbols, 261, 50) == (IconPickerHit{Target::Cell, 7}));
    CHECK(IconPickerHitTest(icon, state, symbols, 261.3f, 50) == IconPickerHit{});
    CHECK(IconPickerHitTest(icon, state, symbols, 250, 276) == (IconPickerHit{Target::Cell, 55}));
    CHECK(IconPickerHitTest(icon, state, symbols, 250, 277) == IconPickerHit{});
}

// The grid's cells are what a pick sets: the matching emoji, or the Icon tab's 56 symbols.
TEST(theCellsAreWhatAPickSets) {
    IconPickerState state;
    CHECK(IconPickerCells(state) == AllEmoji());
    state.query = "grinning";
    CHECK(IconPickerCells(state).size() == 4);
    state.tab = IconPickerTab::Icon;
    const std::vector<std::string> icons = IconPickerCells(state);
    CHECK(icons.size() == 56 && icons.front() == "symbol:star.fill" && icons.back() == "symbol:tram.fill");
    // Every one has a stand-in, glyph or drawn shape.
    for (const std::string& icon : icons) CHECK(SpaceIconLookOf(icon, Theme::Presets()[0]).kind == SpaceIconLook::Kind::Symbol);
    state.tab = IconPickerTab::Image;
    CHECK(IconPickerCells(state).empty());
}

// The tabs: a segment shows its tab, and the emoji grid it comes back to starts at its top
// (SwiftUI makes it again), keeping what was searched; Image can't be chosen yet.
TEST(switchingTabs) {
    IconPickerState state;
    state.query = "cat";
    state.scroll = 99;
    SelectIconPickerTab(state, IconPickerTab::Icon);
    CHECK(state.tab == IconPickerTab::Icon && state.scroll == 0 && state.query == "cat");
    state.scroll = 0;
    SelectIconPickerTab(state, IconPickerTab::Image);
    CHECK(state.tab == IconPickerTab::Icon);
    SelectIconPickerTab(state, IconPickerTab::Emoji);
    CHECK(state.tab == IconPickerTab::Emoji && state.query == "cat");
    // The same tab again changes nothing.
    state.scroll = 66;
    SelectIconPickerTab(state, IconPickerTab::Emoji);
    CHECK(state.scroll == 66);
}

// A category's button clears Search and, when the choice changes (onChange(of: category)),
// scrolls its first emoji's row to the top.
TEST(aCategoryScrollsToItsFirstEmoji) {
    IconPickerState state;
    const std::vector<float> rows = {0, 22, 43, 59, 70, 86, 110, 148};
    for (size_t i = 1; i < rows.size(); ++i) {
        SelectIconPickerCategory(state, i);
        CHECK(state.category == i && state.scroll == rows[i] * 33);
    }
    SelectIconPickerCategory(state, 0);
    CHECK(state.scroll == 0);
    // The current one again while searching: Search clears, the grid stays where it was.
    state.scroll = 99;
    state.query = "cat";
    SelectIconPickerCategory(state, 0);
    CHECK(state.query.empty() && state.category == 0 && state.scroll == 99);
    // One past the last does nothing.
    SelectIconPickerCategory(state, 8);
    CHECK(state.category == 0 && state.scroll == 99);
}

// The wheel scrolls the emoji grid within its rows; Search keeps the scroll where it still fits.
TEST(theEmojiGridScrollsWithinItsRows) {
    IconPickerState state;
    ScrollIconPicker(state, -10, 1101);
    CHECK(state.scroll == 0);
    ScrollIconPicker(state, 100, 1101);
    CHECK(state.scroll == 100);
    ScrollIconPicker(state, 100000, 1101);
    CHECK(state.scroll == IconPickerMaxScroll(1101));
    // Search gives the grid's cells back: 12 flags, two rows, no scroll.
    CHECK(SetIconPickerQuery(state, "flag").size() == 12);
    CHECK(state.scroll == 0 && state.query == "flag");
    CHECK(SetIconPickerQuery(state, "").size() == 1101);
    CHECK(state.scroll == 0);
    state.scroll = 300;
    SetIconPickerQuery(state, "a");
    CHECK(state.scroll == std::min(300.0f, IconPickerMaxScroll(EmojiMatching("a").size())));
    // The Icon tab doesn't scroll.
    state.tab = IconPickerTab::Icon;
    state.scroll = 0;
    ScrollIconPicker(state, 50, 56);
    CHECK(state.scroll == 0);
}

// pick(): the icon set, and the picture the old icon was deleted once nothing shows it
// (SpaceIconImages.discard).
TEST(aPickSetsTheIconAndLetsTheOldPictureGo) {
    BrowserState state = TwoSpaces("image:3F2A.png");
    const std::string a = state.spaces[0].id, b = state.spaces[1].id;
    auto pick = PickSpaceIcon(state, a, "\xF0\x9F\x9A\x80");
    CHECK(pick && pick->icon == "\xF0\x9F\x9A\x80" && pick->discard == std::optional<std::string>("3F2A.png"));
    pick = PickSpaceIcon(state, a, "symbol:leaf.fill");
    CHECK(pick && pick->icon == "symbol:leaf.fill" && !pick->discard);
    // The bin: no icon, the dot.
    pick = PickSpaceIcon(state, a, "");
    CHECK(pick && pick->icon.empty() && !pick->discard);
    CHECK(!PickSpaceIcon(state, "nope", "x"));
    // A picture another space still shows stays.
    state.SetSpaceIcon(a, "image:same.png");
    state.SetSpaceIcon(b, "image:same.png");
    pick = PickSpaceIcon(state, a, "\xF0\x9F\x8C\x99");
    CHECK(pick && !pick->discard);
    // Picking the same picture keeps its file.
    CHECK(!PictureToDiscard("image:same.png", state.spaces));
    CHECK(PictureToDiscard("image:gone.png", state.spaces) == std::optional<std::string>("gone.png"));
    CHECK(!PictureToDiscard("image:../x.png", state.spaces));
    CHECK(!PictureToDiscard("\xF0\x9F\x8C\x99", state.spaces));
}

// NSPopover under the header's icon: centred on it, kept 4pt inside the screen, its arrow on the
// icon's middle but never over the corners.
TEST(thePopoverHangsUnderTheIcon) {
    const PickerRect screen{0, 0, 1920, 1040};
    // The header's icon in a window at (500, 50): its button 513...539 across, 137...163 down.
    IconPickerPlacement p = PlaceIconPicker(PickerRect{513, 137, 539, 163}, 272, 268, screen);
    CHECK(p == (IconPickerPlacement{390, 163, 272, 279, 136}));
    // Near the screen's left edge it moves right; the arrow stays on the icon.
    p = PlaceIconPicker(PickerRect{113, 137, 139, 163}, 272, 268, screen);
    CHECK(p.left == 4 && p.arrowX == 122);
    p = PlaceIconPicker(PickerRect{-20, 137, 6, 163}, 272, 268, screen);
    CHECK(p.left == 4 && p.arrowX == 21);
    // And at the right edge, left.
    p = PlaceIconPicker(PickerRect{1897, 137, 1923, 163}, 272, 289, screen);
    CHECK(p.left == 1644 && p.arrowX == 251 && p.height == 300);
}

// The header's icon is a button (SidebarPassthroughButton): a press and release over it opens
// the picker, even on the click that brings the window forward; an icon-less header has none.
TEST(theHeadersIconOpensThePicker) {
    using T = SidebarHit::Target;
    using A = SidebarTap::Action;
    BrowserState state = TwoSpaces("\xF0\x9F\x9A\x80");
    const std::string id = state.spaces[0].id;
    const auto rows = SidebarRows(state, 0);
    auto hit = [&](float x, float y) { return SidebarHitTest(rows, 240, 800, 0, x, y); };
    CHECK(hit(13, 82 + 5) == (SidebarHit{T::HeaderIcon, 0}));
    CHECK(hit(38.9f, 82 + 30.9f) == (SidebarHit{T::HeaderIcon, 0}));
    CHECK(hit(12.9f, 90) == (SidebarHit{T::Row, 0}));
    CHECK(hit(39, 90) == (SidebarHit{T::Row, 0}));
    CHECK(hit(20, 82 + 4.9f) == (SidebarHit{T::Row, 0}));
    CHECK(hit(20, 82 + 31) == (SidebarHit{T::Row, 0}));
    const auto press = SidebarPressAt(rows, 240, 800, 0, 20, 95, 1);
    CHECK(press == (SidebarPress{T::HeaderIcon, SidebarRow::Kind::Header, id, 1}));
    CHECK(SidebarRelease(*press, rows, 240, 800, 0, 30, 100) == (SidebarTap{A::ChangeIcon, id, false}));
    CHECK(SidebarRelease(*press, rows, 240, 800, 0, 60, 100) == SidebarTap{});
    CHECK(SidebarPressAt(rows, 240, 800, 0, 20, 95, 1, true) == press);
    const auto twice = SidebarPressAt(rows, 240, 800, 0, 20, 95, 2);
    CHECK(SidebarRelease(*twice, rows, 240, 800, 0, 20, 95) == (SidebarTap{A::ChangeIcon, id, false}));
    // No icon: the slot is the name's, and the header's body.
    const auto bare = SidebarRows(state, 1);
    CHECK(SidebarHitTest(bare, 240, 800, 0, 20, 95) == (SidebarHit{T::Row, 0}));
}

// A right-click on the header's icon opens the space's menu, as one on the rest of the header
// does: the icon button passes it on to its cell (SidebarListCells' rightMouseDown,
// SpaceHeaderRowCell.contextMenu(at:)). Nothing else in the list has the space's menu.
TEST(aRightClickOnTheHeadersIconOpensTheSpacesMenu) {
    using T = SidebarHit::Target;
    BrowserState state = TwoSpaces("\xF0\x9F\x9A\x80");
    const std::string id = state.spaces[0].id;
    const auto rows = SidebarRows(state, 0);
    CHECK(HeaderMenuSpace(rows, SidebarHitTest(rows, 240, 800, 0, 20, 95)) == std::optional<std::string>(id));  // the icon
    CHECK(HeaderMenuSpace(rows, SidebarHitTest(rows, 240, 800, 0, 100, 95)) == std::optional<std::string>(id));  // the name
    CHECK(!HeaderMenuSpace(rows, SidebarHit{}));
    CHECK(!HeaderMenuSpace(rows, SidebarHit{T::HeaderIcon, 7}));
    CHECK(!HeaderMenuSpace(rows, SidebarHit{T::AddressField, 0}));
    // A tab's row: not the space's menu.
    state.OpenTab("https://example.com", id, false);
    const auto withTab = SidebarRows(state, 0);
    for (size_t i = 0; i < withTab.size(); ++i) {
        if (withTab[i].kind == SidebarRow::Kind::Tab) CHECK(!HeaderMenuSpace(withTab, SidebarHit{T::Row, i}));
    }
}

namespace {

// The string literals in `text` from `from` on, between `open` and the next `"`.
std::string Between(const std::string& text, size_t& at, const std::string& open) {
    const size_t start = text.find(open, at);
    if (start == std::string::npos) {
        at = std::string::npos;
        return {};
    }
    const size_t end = text.find('"', start + open.size());
    at = end;
    return text.substr(start + open.size(), end - start - open.size());
}

}  // namespace

// The catalog is generated from the Mac's file (windows/scripts/gen-emoji-catalog.py); this reads
// that file again, so a change on the Mac without the generator run again fails here, on any OS.
// And the Icon tab's symbols, which core keeps by hand, against EmojiCatalog.symbols.
TEST(theCatalogMatchesTheMacsSourceFile) {
    std::ifstream file(KITE_MAC_PICKER_SOURCE, std::ios::binary);
    CHECK(file.good());
    if (!file) return;
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string swift = buffer.str();
    size_t at = 0;
    size_t i = 0;
    while (true) {
        const std::string name = Between(swift, at, "Category(name: \"");
        if (at == std::string::npos) break;
        const std::string symbol = Between(swift, at, "symbol: \"");
        const std::string emoji = Between(swift, at, "emoji: chars(\"");
        CHECK(i < EmojiCategories().size());
        if (i >= EmojiCategories().size()) break;
        const EmojiCategory& category = EmojiCategories()[i++];
        CHECK(category.name == name);
        CHECK(category.symbol == symbol);
        std::string joined;
        for (const std::string& e : category.emoji) joined += e;
        CHECK(joined == emoji);
    }
    CHECK(i == EmojiCategories().size());
    // static let symbols: [String] = [ "star.fill", ... ]
    size_t list = swift.find("static let symbols: [String] = [");
    CHECK(list != std::string::npos);
    if (list == std::string::npos) return;
    const size_t close = swift.find(']', swift.find('[', list + 30) + 1);
    std::vector<std::string> names;
    for (size_t q = swift.find('"', list); q != std::string::npos && q < close; q = swift.find('"', q + 1)) {
        const size_t e = swift.find('"', q + 1);
        names.push_back(swift.substr(q + 1, e - q - 1));
        q = e;
    }
    std::vector<std::string> ours(IconTabSymbols().begin(), IconTabSymbols().end());
    CHECK(names == ours);
}
