#pragma once
// The sidebar's top row and hiding the sidebar, platform-free: the Mac's SidebarHeaderView top
// row (SidebarHeader.swift: the toggle, then back, forward and reload at the far end; the
// compact layout with a More menu), HeaderLayout (SidebarView.swift), ArcMetrics.Sidebar's top
// row and ArcMetrics.Motion's sidebar toggle, BrowserStore.PageStatus (what the shown page
// reports), and BrowserWindowController.updateSidebar's frames (the card's leading edge and the
// sidebar's). The shell draws the row (shell/SidebarTopRowView) and runs the slide.
//
// Windows has no traffic lights: the Mac's toggle sits just right of them (x 71, where the
// lights' 60pt cluster ends), so with nothing to its left on Windows it starts kToggleX in, the
// same 6pt the navigation buttons keep from the sidebar's other edge (docs/windows.md, "The
// sidebar's top row"). The row's y and everything else are the Mac's.

#include <optional>
#include <string>
#include <vector>

#include "core/Models.h"
#include "core/Sidebar.h"
#include "core/SpaceBar.h"
#include "core/SymbolShape.h"

namespace kite {

// ArcMetrics.Sidebar's top row, in points from the sidebar's top-left.
namespace top_row_metrics {
constexpr float kTopRowY = sidebar_metrics::kTopRowY;  // 7.5
constexpr float kTopRowHeight = sidebar_metrics::kTopRowHeight;  // 32
constexpr float kButtonSize = 32;        // navButtonSize
constexpr float kButtonSpacing = 2;      // navButtonSpacing
constexpr float kNavTrailing = 6;        // back, forward and reload end this far short of the sidebar's edge
constexpr float kMacToggleX = 71;        // the Mac's toggle, just right of the traffic lights
constexpr float kToggleX = kNavTrailing;  // Windows' (no traffic lights): the row's own end inset
// HeaderLayout: compact under 212 (28pt buttons, no gap, the toggle and reload behind More),
// medium from 212, regular from 228 (Arc's SidebarHeaderWidthLayout; medium only changes the
// favorites grid).
constexpr float kCompactBelow = 212;
constexpr float kMediumBelow = 228;
constexpr float kCompactButtonSize = 28;
constexpr float kCompactButtonSpacing = 0;
// SymbolButton(pointSize: 15) at opacity 0.6 over labelColor; back, forward and reload disabled
// at 0.25 × 0.5 (SwiftUI halves a disabled plain button on top of a toolbar button's 0.25).
constexpr float kSymbolSize = 15;
constexpr float kOpacity = 0.6f;
constexpr float kDisabledOpacity = 0.25f * 0.5f;
}  // namespace top_row_metrics

// ArcMetrics.Motion's sidebar hide and show: 0.08 s on a cubic Bézier, both ways.
namespace sidebar_toggle {
constexpr double kDuration = 0.08;
constexpr double kCurve[4] = {0.25, 0.46, 0.45, 0.94};
constexpr float kContentInset = 10;  // ArcMetrics.Content.inset: the card's leading edge with the sidebar hidden
}  // namespace sidebar_toggle

// What the shown page reports (the Mac's PageStatus, the part the top row reads): none for a tab
// with no page yet, or whose page closed (BrowserStore.clearPage).
struct PageStatus {
    bool isLoading = false;
    bool canGoBack = false;
    bool canGoForward = false;
    bool operator==(const PageStatus&) const = default;
};

// HeaderLayout(sidebarWidth:).
struct HeaderLayout {
    bool compact = false;
    float buttonSize = top_row_metrics::kButtonSize;
    float spacing = top_row_metrics::kButtonSpacing;
    static HeaderLayout For(float sidebarWidth);
    bool operator==(const HeaderLayout&) const = default;
};

enum class TopRowButton { ToggleSidebar, Back, Forward, Reload, More };

// The Mac's SidebarHeaderView.Model, the top row's part: whether a tab is selected (reload needs
// one) and its page's status. Not yet on Windows: View → Show Toolbar (which moves navigation to
// the bar over the page) and Developer Mode's reload options button.
struct TopRowModel {
    bool hasTab = false;
    PageStatus page;
    bool operator==(const TopRowModel&) const = default;
};
TopRowModel TopRowModelOf(const BrowserState& state, const PageStatus& selectedPage);

// One shown button: its frame in the sidebar's points, what it shows (an SF Symbol name), its
// tooltip, and whether it takes presses. A disabled one still shows, faded, and its tooltip.
struct TopRowItem {
    TopRowButton button = TopRowButton::ToggleSidebar;
    BarRect frame;
    std::string symbol;
    std::string tooltip;
    bool enabled = true;
    float Opacity() const { return enabled ? top_row_metrics::kOpacity : top_row_metrics::kDisabledOpacity; }
    bool operator==(const TopRowItem&) const = default;
};

// SidebarHeaderView.layout and apply: the shown buttons, left to right, for a sidebar `width`
// wide. Regular: the toggle at kToggleX, then back, forward and reload ending kNavTrailing short of
// the edge, 2pt apart. Compact: no toggle; back, forward and More, 28pt and touching, centred in
// the row's height. Reload is the X while the page loads (the tooltip stays "Reload", as the Mac's).
std::vector<TopRowItem> LayOutTopRow(float width, const TopRowModel& model);
// The button at (x, y) in the sidebar's points, enabled or not: a press on a disabled one does
// nothing, but it's still the button's (the Mac's mouseDownCanMoveWindow false).
std::optional<size_t> TopRowItemAt(const std::vector<TopRowItem>& items, float x, float y);
// What a click on an enabled button does: a shortcut command's id (the Mac's actions: the toggle,
// goBack, goForward, and the reload button's reload-or-stop). None for More (its menu comes with
// sidebar resizing, the only way to a compact sidebar).
std::optional<std::string> TopRowCommand(TopRowButton button);
const char* TopRowButtonName(TopRowButton button);

// Hiding and showing the sidebar (BrowserWindowController.updateSidebar): where the card's leading
// edge and the sidebar's sit, in window points.
inline float CardLeft(bool sidebarShown, float sidebarWidth) { return sidebarShown ? sidebarWidth : sidebar_toggle::kContentInset; }
inline float SidebarLeft(bool sidebarShown, float sidebarWidth) { return sidebarShown ? 0 : -sidebarWidth; }
// The sidebar's slide from `from` to `to` points (its leading edge), on kCurve over kDuration, as
// compositor segments of the time since it began; a toggle caught mid-slide goes the other way from
// where it is, over the full duration (Core Animation's implicit animation from the presentation
// value).
std::vector<CubicSegment> SidebarSlideSegments(float from, float to);
// Where that slide is `elapsed` seconds in.
float SidebarSlideAt(float from, float to, double elapsed);

// sidebar.left, which neither Segoe icon font has: a rounded rectangle with the sidebar's divider
// and three short lines in its pane, simple original geometry measured from the Mac's 15pt render
// (review/w9d-mac/rest.png at 2×), in points about the button's centre.
const SymbolShape& SidebarToggleShape();
// The ink box the Mac's 15pt symbol fills in its 32pt button, relative to the button's centre
// (measured from the same render), for the symbols drawn with Segoe stand-ins; none where the Mac's
// hasn't been measured yet (xmark and ellipsis, which the Mac's references add).
struct SymbolInk {
    float centerX = 0, centerY = 0, width = 0, height = 0;
};
std::optional<SymbolInk> MacSymbolInk(const std::string& symbol);

}  // namespace kite
