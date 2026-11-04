// See SidebarTopRow.h.

#include "core/SidebarTopRow.h"

#include "core/SpaceSwipe.h"

namespace kite {

namespace T = top_row_metrics;

HeaderLayout HeaderLayout::For(float sidebarWidth) {
    HeaderLayout layout;
    layout.compact = sidebarWidth < T::kCompactBelow;
    layout.buttonSize = layout.compact ? T::kCompactButtonSize : T::kButtonSize;
    layout.spacing = layout.compact ? T::kCompactButtonSpacing : T::kButtonSpacing;
    return layout;
}

TopRowModel TopRowModelOf(const BrowserState& state, const PageStatus& selectedPage) {
    TopRowModel model;
    model.hasTab = state.SelectedTab() != nullptr;
    // A space with no selected tab shows no page: nothing to go back to (readModel's PageStatus()).
    if (model.hasTab) model.page = selectedPage;
    return model;
}

std::vector<TopRowItem> LayOutTopRow(float width, const TopRowModel& model) {
    const HeaderLayout layout = HeaderLayout::For(width);
    std::vector<TopRowItem> items;
    // Arc's compact header drops the toggle into the More menu.
    if (!layout.compact) {
        items.push_back(TopRowItem{TopRowButton::ToggleSidebar,
                                   BarRect{T::kToggleX, T::kTopRowY, T::kToggleX + T::kButtonSize, T::kTopRowY + T::kButtonSize},
                                   "sidebar.left", "Toggle Sidebar", true});
    }
    // Navigation at the far end, placed from the end inwards.
    float end = width - T::kNavTrailing;
    const float size = layout.buttonSize;
    const float y = T::kTopRowY + (T::kTopRowHeight - size) / 2;
    std::vector<TopRowItem> trailing;
    const auto place = [&](TopRowButton button, std::string symbol, std::string tooltip, bool enabled) {
        end -= size;
        trailing.push_back(TopRowItem{button, BarRect{end, y, end + size, y + size}, std::move(symbol), std::move(tooltip), enabled});
        end -= layout.spacing;
    };
    if (layout.compact) place(TopRowButton::More, "ellipsis", "More", true);
    else place(TopRowButton::Reload, model.page.isLoading ? "xmark" : "arrow.clockwise", "Reload", model.hasTab);
    place(TopRowButton::Forward, "arrow.right", "Forward", model.page.canGoForward);
    place(TopRowButton::Back, "arrow.left", "Back", model.page.canGoBack);
    items.insert(items.end(), trailing.rbegin(), trailing.rend());
    return items;
}

std::optional<size_t> TopRowItemAt(const std::vector<TopRowItem>& items, float x, float y) {
    for (size_t i = 0; i < items.size(); ++i) {
        if (items[i].frame.Contains(x, y)) return i;
    }
    return std::nullopt;
}

std::optional<std::string> TopRowCommand(TopRowButton button) {
    switch (button) {
    case TopRowButton::ToggleSidebar: return "toggleSidebar";
    case TopRowButton::Back: return "goBack";
    case TopRowButton::Forward: return "goForward";
    // reloadFromButton: a page still loading stops (Chromium::Act's Reload), else it reloads.
    case TopRowButton::Reload: return "reloadPage";
    case TopRowButton::More: return std::nullopt;
    }
    return std::nullopt;
}

const char* TopRowButtonName(TopRowButton button) {
    switch (button) {
    case TopRowButton::ToggleSidebar: return "toggleSidebar";
    case TopRowButton::Back: return "back";
    case TopRowButton::Forward: return "forward";
    case TopRowButton::Reload: return "reload";
    case TopRowButton::More: return "more";
    }
    return "";
}

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
