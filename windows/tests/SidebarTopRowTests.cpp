// The sidebar's top row and hiding the sidebar (core/SidebarTopRow.h). The Mac has no Swift tests
// for these (SidebarHeaderView and updateSidebar are AppKit views): each case is named for the Mac
// code it checks, with the numbers from ArcMetrics.Sidebar and ArcMetrics.Motion. The compact
// layout (HeaderLayout) comes with resizing the sidebar.

#include <algorithm>
#include <cmath>
#include <iterator>

#include "Check.h"
#include "core/KeyBindings.h"
#include "core/Models.h"
#include "core/SidebarTopRow.h"
#include "core/SpaceSwipe.h"
#include "core/TitleBar.h"

using namespace kite;

namespace {

bool Near(double a, double b, double within = 0.01) { return std::fabs(a - b) <= within; }

const TopRowItem* Find(const std::vector<TopRowItem>& items, TopRowButton button) {
    for (const TopRowItem& item : items) {
        if (item.button == button) return &item;
    }
    return nullptr;
}

BrowserState WithTab() {
    BrowserState state = BrowserState::MakeDefault();
    state.OpenTab("https://example.com/");
    return state;
}

}  // namespace

TEST(sidebarHeaderLayoutPlacesTheToggleAndNavigationAtTheFarEnd) {
    // SidebarHeaderView.layout on Kite's 240pt sidebar: the toggle at kToggleX (Windows' 6, for
    // the Mac's 71 beside the traffic lights), then back, forward and reload, 32pt, 2 apart,
    // ending 6pt short of the edge, all on the row at y 7.5.
    const std::vector<TopRowItem> items = LayOutTopRow(240, TopRowModel{true, {}});
    CHECK(items.size() == 4);
    CHECK(items[0].button == TopRowButton::ToggleSidebar && items[0].frame == (BarRect{6, 7.5f, 38, 39.5f}));
    CHECK(items[1].button == TopRowButton::Back && items[1].frame == (BarRect{134, 7.5f, 166, 39.5f}));
    CHECK(items[2].button == TopRowButton::Forward && items[2].frame == (BarRect{168, 7.5f, 200, 39.5f}));
    CHECK(items[3].button == TopRowButton::Reload && items[3].frame == (BarRect{202, 7.5f, 234, 39.5f}));
    // The Mac's toggle sits right of the traffic lights; Windows has none on the left.
    CHECK(top_row_metrics::kMacToggleX == 71 && top_row_metrics::kToggleX == top_row_metrics::kNavTrailing);
    // The symbols and tooltips (SymbolButton's labels).
    CHECK(items[0].symbol == "sidebar.left" && items[0].tooltip == "Toggle Sidebar");
    CHECK(items[1].symbol == "arrow.left" && items[1].tooltip == "Back");
    CHECK(items[2].symbol == "arrow.right" && items[2].tooltip == "Forward");
    CHECK(items[3].symbol == "arrow.clockwise" && items[3].tooltip == "Reload");
    // Each frame is TopRowFrame's (the hit test's).
    for (const TopRowItem& item : items) CHECK(item.frame == TopRowFrame(240, item.button));
    // A wider sidebar keeps the toggle and moves navigation with the edge.
    const std::vector<TopRowItem> wide = LayOutTopRow(300, TopRowModel{true, {}});
    CHECK(wide[0].frame.left == 6 && wide[3].frame.right == 294 && wide[1].frame.left == 194);
}

TEST(sidebarHeaderApplyEnablesFromThePage) {
    // apply(): back and forward from the page's history, reload with a tab; the toggle always.
    std::vector<TopRowItem> items = LayOutTopRow(240, TopRowModel{false, {}});
    CHECK(items[0].enabled && !items[1].enabled && !items[2].enabled && !items[3].enabled);
    items = LayOutTopRow(240, TopRowModel{true, PageStatus{false, true, false}});
    CHECK(items[1].enabled && !items[2].enabled && items[3].enabled);
    items = LayOutTopRow(240, TopRowModel{true, PageStatus{false, false, true}});
    CHECK(!items[1].enabled && items[2].enabled);
    // SymbolButton's opacity 0.6, and a disabled button's 0.25 × 0.5.
    CHECK(Near(items[0].Opacity(), 0.6) && Near(items[1].Opacity(), 0.125) && Near(items[2].Opacity(), 0.6));
}

TEST(sidebarHeaderApplyShowsTheXWhileLoading) {
    // reload.symbol: xmark while the page loads; its tooltip stays "Reload" (no Developer Mode).
    const std::vector<TopRowItem> items = LayOutTopRow(240, TopRowModel{true, PageStatus{true, false, false}});
    CHECK(items[3].symbol == "xmark" && items[3].tooltip == "Reload" && items[3].enabled);
    CHECK((LayOutTopRow(240, TopRowModel{true, {}})[3].symbol == "arrow.clockwise"));
}

TEST(sidebarHeaderReadModelUsesTheSelectedTabsPage) {
    // readModel: the selected tab's PageStatus, or an empty one when no tab is selected.
    const PageStatus loading{true, true, true};
    BrowserState empty = BrowserState::MakeDefault();
    for (Space& space : empty.spaces) {
        space.tabs.clear();
        space.pinnedItems.clear();
        space.selectedTabID.reset();
    }
    CHECK(!empty.SelectedTab());
    CHECK((TopRowModelOf(empty, loading) == TopRowModel{}));
    CHECK(TopRowModelOf(WithTab(), loading) == (TopRowModel{true, loading}));
    CHECK((TopRowModelOf(false, loading) == TopRowModel{}));
    CHECK(TopRowModelOf(true, loading) == (TopRowModel{true, loading}));
}

TEST(symbolButtonTakesPressesEnabledOrNot) {
    // The row's buttons are hit whether or not they're enabled (a disabled one swallows its press);
    // the gaps between them and the row's ends aren't.
    const std::vector<TopRowItem> items = LayOutTopRow(240, TopRowModel{true, {}});
    CHECK(TopRowItemAt(items, 22, 23) == std::optional<size_t>(0));
    CHECK(TopRowItemAt(items, 150, 23) == std::optional<size_t>(1));  // back, disabled
    CHECK(TopRowItemAt(items, 233.9f, 39.4f) == std::optional<size_t>(3));
    CHECK(!TopRowItemAt(items, 167, 23));   // between back and forward
    CHECK(!TopRowItemAt(items, 100, 23));   // between the toggle and back
    CHECK(!TopRowItemAt(items, 150, 7));    // above the row
    CHECK(!TopRowItemAt(items, 150, 39.5f));  // under it
    CHECK(!TopRowItemAt(items, 234, 23));   // past reload
    // The window's hit test asks the same without laying the row out.
    for (const float x : {3.0f, 22.0f, 100.0f, 150.0f, 167.0f, 184.0f, 218.0f, 233.9f, 234.0f}) {
        for (const float y : {7.0f, 7.5f, 23.0f, 39.4f, 39.5f}) {
            const std::optional<size_t> at = TopRowItemAt(items, x, y);
            const std::optional<TopRowButton> button = TopRowButtonAt(240, x, y);
            CHECK(at.has_value() == button.has_value());
            if (at && button) CHECK(items[*at].button == *button);
        }
    }
}

TEST(sidebarActionsRunTheMenusCommands) {
    // toggleSidebar, goBack, goForward, and the reload button's reload (which stops a loading page).
    CHECK(TopRowCommand(TopRowButton::ToggleSidebar) == "toggleSidebar");
    CHECK(TopRowCommand(TopRowButton::Back) == "goBack");
    CHECK(TopRowCommand(TopRowButton::Forward) == "goForward");
    CHECK(TopRowCommand(TopRowButton::Reload) == "reloadPage");
    // Each is a shortcut command the window has.
    for (const char* id : {"toggleSidebar", "goBack", "goForward", "reloadPage"}) {
        bool found = false;
        for (const ShortcutCommand& command : ShortcutCommands()) found = found || command.id == id;
        CHECK(found);
    }
}

TEST(validateMenuItemTitlesTheToggleForWhatItWillDo) {
    // Arc's Show/Hide Sidebar item, titled for what it will do.
    CHECK(std::string(ToggleSidebarTitle(true)) == "Hide Sidebar");
    CHECK(std::string(ToggleSidebarTitle(false)) == "Show Sidebar");
}

TEST(theSystemMenusItemShowsTheShortcutAsBound) {
    // Its key equivalent: Ctrl+S by default, a user's key once rebound, none once removed.
    const auto ctrlS = MenuShortcut(ShortcutTable(KeyBindings{}), "toggleSidebar");
    CHECK(ctrlS && ctrlS->DisplayString() == "Ctrl+S");
    KeyBindings rebound;
    rebound.SetShortcut(KeyShortcut("b", {KeyShortcut::Modifier::Control, KeyShortcut::Modifier::Shift}), "toggleSidebar");
    const auto user = MenuShortcut(ShortcutTable(rebound), "toggleSidebar");
    CHECK(user && user->DisplayString() == "Ctrl+Shift+B");
    KeyBindings removed;
    removed.SetShortcut(std::nullopt, "toggleSidebar");
    CHECK(!MenuShortcut(ShortcutTable(removed), "toggleSidebar"));
    // A command with extra keys shows its own shortcut, not an extra (Refresh: Ctrl+R, not F5).
    const auto reload = MenuShortcut(ShortcutTable(KeyBindings{}), "reloadPage");
    CHECK(reload && reload->DisplayString() == "Ctrl+R");
}

TEST(hideSidebarIsCtrlS) {
    // The Mac's View › Hide Sidebar, ⌘S (MainMenu.swift), with Arc's Use Both priority.
    const auto table = ShortcutTable(KeyBindings{});
    const ShortcutTarget* target = FindShortcut(table, KeyShortcut("s", {KeyShortcut::Modifier::Control}));
    CHECK(target && target->command->id == "toggleSidebar" && target->command->title == "Hide Sidebar");
    CHECK(target && target->priority == KeyShortcutPriority::PromptAfterConsumedByWebView);
    // A user's override still wins (overrideTakesTheShortcutFromOtherCommands).
    KeyBindings bindings;
    bindings.SetShortcut(std::nullopt, "toggleSidebar");
    const KeyShortcut ctrlS("s", {KeyShortcut::Modifier::Control});
    CHECK(!FindShortcut(ShortcutTable(bindings), ctrlS));
}

TEST(updateSidebarMovesTheCardsEdgeAndTheSidebar) {
    // contentLeading: the sidebar's width shown, the content inset hidden; sidebarLeading: 0 or a
    // sidebar's width off the left edge.
    CHECK(CardLeft(true, 240) == 240 && CardLeft(false, 240) == 10);
    CHECK(SidebarLeft(true, 240) == 0 && SidebarLeft(false, 240) == -240);
}

TEST(sidebarToggleSlidesOnArcsCurve) {
    // ArcMetrics.Motion: 0.08 s on (0.25, 0.46, 0.45, 0.94), both ways.
    CHECK(sidebar_toggle::kDuration == 0.08);
    const std::vector<CubicSegment> hide = SidebarSlideSegments(0, -240);
    CHECK(!hide.empty() && hide.front().begin == 0);
    // The compositor's segments follow the curve within a hundredth of a point, from 0 to -240.
    for (int i = 0; i <= 80; ++i) {
        const double t = sidebar_toggle::kDuration * i / 80;
        const double expected = -240 * TimingCurveAt(0.25, 0.46, 0.45, 0.94, t / sidebar_toggle::kDuration);
        const auto it = std::upper_bound(hide.begin(), hide.end(), t, [](double time, const CubicSegment& s) { return time < s.begin; });
        const CubicSegment& s = *std::prev(it);
        const double u = t - s.begin;
        CHECK(Near(s.constant + u * (s.linear + u * (s.quadratic + u * s.cubic)), expected, 0.6));
        CHECK(Near(SidebarSlideAt(0, -240, t), expected, 1e-3));
    }
    // It's mostly there early (an ease-out): over half way by a third of the time.
    CHECK(SidebarSlideAt(0, -240, sidebar_toggle::kDuration / 3) < -120);
    CHECK(SidebarSlideAt(0, -240, 1) == -240 && SidebarSlideAt(0, -240, -1) == 0);
}

TEST(aToggleCaughtMidSlideTurnsBackFromWhereItIs) {
    // A second toggle mid-slide animates from the presented place to the other end, over the
    // whole duration (Core Animation's implicit animation from the presentation value).
    const float at = SidebarSlideAt(0, -240, 0.03);
    CHECK(at < 0 && at > -240);
    const std::vector<CubicSegment> back = SidebarSlideSegments(at, 0);
    CHECK(Near(back.front().constant, at, 1e-4));
    CHECK(Near(SidebarSlideAt(at, 0, sidebar_toggle::kDuration), 0));
    CHECK(SidebarSlideAt(at, 0, 0.04) > at && SidebarSlideAt(at, 0, 0.04) < 0);
}

TEST(sidebarLeftIsDrawnToTheMacsInk) {
    // The outline's outer edge where the Mac's 15pt sidebar.left inks it in its button (centre
    // 87, 23.5): 78.5...96.14 by 17.02...30.5, the right pane empty, the divider and the left pane's
    // three lines inked.
    const SymbolShape& shape = SidebarToggleShape();
    const ShapeBounds b = BoundsOf(shape);
    CHECK(Near(b.left, 78.5 - 87, 0.02) && Near(b.right, 96.14 - 87, 0.02));
    CHECK(Near(b.top, 17.02 - 23.5, 0.02) && Near(b.bottom, 30.5 - 23.5, 0.02));
    CHECK(Covers(shape, 78.5f - 87 + 0.5f, 0));        // the outline's left side
    CHECK(Covers(shape, 84.65f - 87, 0));              // the divider
    CHECK(!Covers(shape, 90.5f - 87, 0));              // inside the right pane
    CHECK(Covers(shape, 81.8f - 87, 22.41f - 23.5f));  // the middle line
    CHECK(!Covers(shape, 81.8f - 87, 23.4f - 23.5f));  // between two lines
    CHECK(!Covers(shape, 81.8f - 87, 26 - 23.5f));     // under the lines
}

TEST(theStandInsSitWhereTheMacsSymbolsInk) {
    // Measured from the Mac's 2× render: arrows 13.5 × 11 half a point low and a quarter left of
    // their buttons' centres, reload 13 × 16 on its centre; xmark not yet measured.
    const std::optional<SymbolInk> back = MacSymbolInk("arrow.left");
    CHECK(back && back->width == 13.5f && back->height == 11 && back->centerX == -0.25f && back->centerY == 0.5f);
    CHECK(MacSymbolInk("arrow.right").has_value());
    const std::optional<SymbolInk> reload = MacSymbolInk("arrow.clockwise");
    CHECK(reload && reload->width == 13 && reload->height == 16);
    CHECK(!MacSymbolInk("xmark") && !MacSymbolInk("sidebar.left"));
}

TEST(theTopRowsButtonsAreCutOutOfTheWindowsDrag) {
    // SymbolButton's mouseDownCanMoveWindow false: the buttons are the client's; the row between
    // and around them still drags the window.
    CHECK(TitleBarAreaAt(1280, 240, 22, 23) == TitleBarArea::Client);    // the toggle
    CHECK(TitleBarAreaAt(1280, 240, 150, 23) == TitleBarArea::Client);   // back
    CHECK(TitleBarAreaAt(1280, 240, 233.9f, 8) == TitleBarArea::Client);  // reload's corner
    CHECK(TitleBarAreaAt(1280, 240, 100, 23) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 167, 23) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 3, 23) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 150, 5) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 150, 42) == TitleBarArea::Drag);
}

TEST(aHiddenSidebarLeavesTheWholeBandToDrag) {
    // Hidden (a sidebar width of 0): the band above the card drags from the window's left edge,
    // where the toggle was, and under it is the card's.
    CHECK(TitleBarAreaAt(1280, 0, 22, 23) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 0, 150, 31.9f) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 0, 150, 32) == TitleBarArea::Client);
    CHECK(TitleBarAreaAt(1280, 0, 1240, 10) == TitleBarArea::Close);
}
