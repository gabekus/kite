// See SidebarTopRow.h.

#include "core/SidebarTopRow.h"

#include <cmath>

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
    // outline's outer edge 78.5...96.14 by 17.02...30.5 with a 1.15pt stroke and corners about 2.5;
    // the divider 84.08...85.23; three lines 80.83...82.9, 0.81 tall, centred on y 20.4, 22.41 and
    // 24.29.
    static const SymbolShape shape = [] {
        constexpr float cx = 87, cy = 23.5f;
        constexpr float left = 78.5f - cx, right = 96.14f - cx, top = 17.02f - cy, bottom = 30.5f - cy;
        constexpr float stroke = 1.15f, radius = 2.5f;
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

namespace {

// A stroke from `a` to `p`, `half` its thickness either side, with round caps centred on its ends:
// a rectangle reaching `half` past each end, its four corners rounded to `half`, which turns its
// short ends into half circles.
void Stroke(ShapeBuilder& b, ShapePoint a, ShapePoint p, float half) {
    const float dx = p.x - a.x, dy = p.y - a.y, length = std::sqrt(dx * dx + dy * dy);
    const float ux = dx / length * half, uy = dy / length * half;  // along it
    const float nx = -uy, ny = ux;                                   // across it
    a = ShapePoint{a.x - ux, a.y - uy};
    p = ShapePoint{p.x + ux, p.y + uy};
    b.RoundedPolygon({{a.x + nx, a.y + ny, half}, {p.x + nx, p.y + ny, half}, {p.x - nx, p.y - ny, half}, {a.x - nx, a.y - ny, half}});
}

// Reload's and the X's stroke: 2.36 px at 2× in the Mac's arrow.clockwise.
constexpr float kStrokeHalf = 1.18f / 2;

}  // namespace

const SymbolShape& ReloadShape() {
    // Measured from the Mac's reload at 2× (its button 404...468 by 15...79 px, centre 436, 47):
    // the ring 423...448.8 across and down to 63, so centred on 435.9, 50.1 with its stroke's
    // middle 11.72 px out; its right end just above three o'clock (the end's top at 48.3); the top
    // running on, nearly level, to the chevron's point at 441.3, 38.1, whose legs run at 45° to their
    // ends' centres at 435.9, 32.7 and 435, 44.4 (the lower a little longer, the chevron turned with
    // the ring), all with round caps.
    static const SymbolShape shape = [] {
        constexpr float cx = -0.05f, cy = 1.55f, r = 5.86f, h = kStrokeHalf;
        constexpr float start = -3, end = 270;  // degrees, clockwise on screen from +x
        constexpr float pi = 3.14159265f;
        ShapeBuilder b;
        // The arc as a band: out along the outer edge, back along the inner one.
        b.Arc(cx, cy, r + h, start, end).Arc(cx, cy, r - h, end, start).Close();
        // Its round end at three o'clock.
        b.Circle(cx + r * std::cos(start * pi / 180), cy + r * std::sin(start * pi / 180), h);
        // The tail from the top to the chevron's point, and the chevron.
        const ShapePoint top{cx, cy - r}, point{2.65f, -4.45f};
        Stroke(b, top, point, h);
        Stroke(b, ShapePoint{point.x - 2.71f, point.y - 2.71f}, point, h);
        Stroke(b, ShapePoint{point.x - 3.16f, point.y + 3.16f}, point, h);
        return b.Build();
    }();
    return shape;
}

const SymbolShape& StopShape() {
    // An X 11pt across, a quarter point low (as SF's symbols sit, the arrows half a point), its
    // strokes reload's.
    static const SymbolShape shape = [] {
        constexpr float reach = 5.5f - kStrokeHalf, y = 0.25f;
        ShapeBuilder b;
        Stroke(b, ShapePoint{-reach, y - reach}, ShapePoint{reach, y + reach}, kStrokeHalf);
        Stroke(b, ShapePoint{-reach, y + reach}, ShapePoint{reach, y - reach}, kStrokeHalf);
        return b.Build();
    }();
    return shape;
}

const SymbolShape* TopRowShape(const std::string& symbol) {
    if (symbol == "sidebar.left") return &SidebarToggleShape();
    if (symbol == "arrow.clockwise") return &ReloadShape();
    if (symbol == "xmark") return &StopShape();
    return nullptr;
}

std::optional<SymbolInk> MacSymbolInk(const std::string& symbol) {
    // The Mac's render at 2× (review/w9d-mac/rest.png): back 143...156.5 by 18.5...29.5 in a button
    // centred on 150, 23.5, forward the same in 184's.
    if (symbol == "arrow.left" || symbol == "arrow.right") return SymbolInk{-0.25f, 0.5f, 13.5f, 11};
    return std::nullopt;
}

}  // namespace kite
