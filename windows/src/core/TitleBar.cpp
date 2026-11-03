// See TitleBar.h.

#include "core/TitleBar.h"

#include "core/Sidebar.h"

namespace kite {

namespace T = title_bar;

float CaptionButtonLeft(float width, CaptionButton button) {
    const int index = button == CaptionButton::Minimize ? 0 : button == CaptionButton::Maximize ? 1 : 2;
    return width - T::kButtonsWidth + static_cast<float>(index) * T::kButtonWidth;
}

TitleBarArea TitleBarAreaAt(float width, float sidebarWidth, float x, float y) {
    if (x < 0 || y < 0 || x >= width) return TitleBarArea::Client;
    if (y < T::kButtonHeight && x >= width - T::kButtonsWidth) {
        if (x < CaptionButtonLeft(width, CaptionButton::Maximize)) return TitleBarArea::Minimize;
        if (x < CaptionButtonLeft(width, CaptionButton::Close)) return TitleBarArea::Maximize;
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
