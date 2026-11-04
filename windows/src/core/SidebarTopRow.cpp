// See SidebarTopRow.h.

#include "core/SidebarTopRow.h"

#include "core/SpaceSwipe.h"

namespace kite {

namespace T = top_row_metrics;

TopRowModel TopRowModelOf(bool hasTab, const PageStatus& selectedPage) {
    // A space with no selected tab shows no page: nothing to go back to (readModel's PageStatus()).
    return TopRowModel{hasTab, hasTab ? selectedPage : PageStatus{}};
}

TopRowModel TopRowModelOf(const BrowserState& state, const PageStatus& selectedPage) {
    return TopRowModelOf(state.SelectedTab() != nullptr, selectedPage);
}

BarRect TopRowFrame(float width, TopRowButton button) {
    constexpr float top = T::kTopRowY + (T::kTopRowHeight - T::kButtonSize) / 2, bottom = top + T::kButtonSize;
    if (button == TopRowButton::ToggleSidebar) return BarRect{T::kToggleX, top, T::kToggleX + T::kButtonSize, bottom};
    // Navigation at the far end, placed from the end inwards: reload, forward, back.
    const int fromEnd = button == TopRowButton::Reload ? 0 : button == TopRowButton::Forward ? 1 : 2;
    const float right = width - T::kNavTrailing - static_cast<float>(fromEnd) * (T::kButtonSize + T::kButtonSpacing);
    return BarRect{right - T::kButtonSize, top, right, bottom};
}

std::vector<TopRowItem> LayOutTopRow(float width, const TopRowModel& model) {
    return {
        TopRowItem{TopRowButton::ToggleSidebar, TopRowFrame(width, TopRowButton::ToggleSidebar), "sidebar.left", "Toggle Sidebar", true},
        TopRowItem{TopRowButton::Back, TopRowFrame(width, TopRowButton::Back), "arrow.left", "Back", model.page.canGoBack},
        TopRowItem{TopRowButton::Forward, TopRowFrame(width, TopRowButton::Forward), "arrow.right", "Forward", model.page.canGoForward},
        TopRowItem{TopRowButton::Reload, TopRowFrame(width, TopRowButton::Reload), model.page.isLoading ? "xmark" : "arrow.clockwise",
                   "Reload", model.hasTab},
    };
}

std::optional<TopRowButton> TopRowButtonAt(float width, float x, float y) {
    for (const TopRowButton button : kTopRowButtons) {
        if (TopRowFrame(width, button).Contains(x, y)) return button;
    }
    return std::nullopt;
}

std::optional<size_t> TopRowItemAt(const std::vector<TopRowItem>& items, float x, float y) {
    for (size_t i = 0; i < items.size(); ++i) {
        if (items[i].frame.Contains(x, y)) return i;
    }
    return std::nullopt;
}

std::string TopRowCommand(TopRowButton button) {
    switch (button) {
    case TopRowButton::ToggleSidebar: return "toggleSidebar";
    case TopRowButton::Back: return "goBack";
    case TopRowButton::Forward: return "goForward";
    // reloadFromButton: a page still loading stops (Chromium::Act's Reload), else it reloads.
    case TopRowButton::Reload: return "reloadPage";
    }
    return {};
}

const char* TopRowButtonName(TopRowButton button) {
    switch (button) {
    case TopRowButton::ToggleSidebar: return "toggleSidebar";
    case TopRowButton::Back: return "back";
    case TopRowButton::Forward: return "forward";
    case TopRowButton::Reload: return "reload";
    }
    return "";
}

const char* ToggleSidebarTitle(bool sidebarShown) { return sidebarShown ? "Hide Sidebar" : "Show Sidebar"; }

std::vector<CubicSegment> SidebarSlideSegments(float from, float to) {
    const auto& c = sidebar_toggle::kCurve;
    std::vector<CubicSegment> segments = TimingCurveSegments(c[0], c[1], c[2], c[3], sidebar_toggle::kDuration);
    // From 0...1 of the way to points.
    const double distance = static_cast<double>(to) - from;
    for (CubicSegment& segment : segments) {
        segment.constant = from + segment.constant * distance;
        segment.linear *= distance;
        segment.quadratic *= distance;
        segment.cubic *= distance;
    }
    return segments;
}

float SidebarSlideAt(float from, float to, double elapsed) {
    if (elapsed >= sidebar_toggle::kDuration) return to;
    if (elapsed <= 0) return from;
    const auto& c = sidebar_toggle::kCurve;
    const double progress = TimingCurveAt(c[0], c[1], c[2], c[3], elapsed / sidebar_toggle::kDuration);
    return static_cast<float>(from + (static_cast<double>(to) - from) * progress);
}

const SymbolShape& SidebarToggleShape() {
    // Measured from the Mac's toggle at 2× (its button 71...103, 7.5...39.5, centre 87, 23.5): the
    // outline's outer edge 78.5...96.14 by 17.02...30.5 with a 1.15pt stroke and corners about 3.5;
    // the divider 84.08...85.23; three lines 80.83...82.9, 0.81 tall, centred on y 20.4, 22.41 and
    // 24.29.
    static const SymbolShape shape = [] {
        constexpr float cx = 87, cy = 23.5f;
        constexpr float left = 78.5f - cx, right = 96.14f - cx, top = 17.02f - cy, bottom = 30.5f - cy;
        constexpr float stroke = 1.15f, radius = 3.5f;
        ShapeBuilder b;
        b.RoundRect(left, top, right, bottom, radius);
        b.Cut().RoundRect(left + stroke, top + stroke, right - stroke, bottom - stroke, radius - stroke);
        b.Add().RoundRect(84.08f - cx, top + stroke * 0.5f, 85.23f - cx, bottom - stroke * 0.5f, 0);
        constexpr float lineLeft = 80.83f - cx, lineRight = 82.9f - cx, half = 0.81f / 2;
        for (float y : {20.4f, 22.41f, 24.29f}) b.RoundRect(lineLeft, y - cy - half, lineRight, y - cy + half, half);
        return b.Build();
    }();
    return shape;
}

std::optional<SymbolInk> MacSymbolInk(const std::string& symbol) {
    // The Mac's render at 2× (review/w9d-mac/rest.png): back 143...156.5 by 18.5...29.5 in a button
    // centred on 150, 23.5, forward the same in 184's, reload 211.5...224.5 by 15.5...31.5 in 218's.
    if (symbol == "arrow.left" || symbol == "arrow.right") return SymbolInk{-0.25f, 0.5f, 13.5f, 11};
    if (symbol == "arrow.clockwise") return SymbolInk{0, 0, 13, 16};
    return std::nullopt;
}

}  // namespace kite
