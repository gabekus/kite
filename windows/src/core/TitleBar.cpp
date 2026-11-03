// See TitleBar.h.

#include "core/TitleBar.h"

#include <cmath>

#include "core/Sidebar.h"

namespace kite {

namespace T = title_bar;

float CaptionEdgeFromRight(int buttons, float scale) {
    return std::round(static_cast<float>(buttons) * T::kButtonWidth * scale) / scale;
}

float CaptionButtonLeft(float width, CaptionButton button, float scale) {
    const int fromRight = button == CaptionButton::Minimize ? 3 : button == CaptionButton::Maximize ? 2 : 1;
    return width - CaptionEdgeFromRight(fromRight, scale);
}

TitleBarArea TitleBarAreaAt(float width, float sidebarWidth, float x, float y, float scale) {
    if (x < 0 || y < 0 || x >= width) return TitleBarArea::Client;
    if (y < T::kButtonHeight && x >= CaptionButtonLeft(width, CaptionButton::Minimize, scale)) {
        if (x < CaptionButtonLeft(width, CaptionButton::Maximize, scale)) return TitleBarArea::Minimize;
        if (x < CaptionButtonLeft(width, CaptionButton::Close, scale)) return TitleBarArea::Maximize;
        return TitleBarArea::Close;
    }
    // The sidebar's top row, over its address field (nothing in it takes clicks yet: the Mac's
    // toggle and back, forward and reload buttons come later and will be cut out of it).
    if (x < sidebarWidth) return y < sidebar_metrics::kUrlFieldTop ? TitleBarArea::Drag : TitleBarArea::Client;
    return y < T::kContentTop ? TitleBarArea::Drag : TitleBarArea::Client;
}

std::optional<CaptionButton> CaptionButtonOf(TitleBarArea area) {
    switch (area) {
    case TitleBarArea::Minimize: return CaptionButton::Minimize;
    case TitleBarArea::Maximize: return CaptionButton::Maximize;
    case TitleBarArea::Close: return CaptionButton::Close;
    default: return std::nullopt;
    }
}

}  // namespace kite
