#pragma once
// Kite for Windows' title bar, in points. The window has no caption: the backdrop runs up to
// its top edge, as the Mac's .fullSizeContentView runs it under the title bar, and Kite draws
// Windows' minimize, maximize and close buttons itself at the top-right (Windows 11's caption
// buttons, 46 × 32). The content card starts under them. The shell (MainWindow,
// CaptionButtonsView) maps this to pixels; Windows draws and hit-tests the resize borders.

#include <optional>

namespace kite {

namespace title_bar {
constexpr float kButtonWidth = 46;
constexpr float kButtonHeight = 32;
constexpr float kButtonsWidth = 3 * kButtonWidth;
constexpr float kGlyphSize = 10;  // Segoe Fluent Icons' Chrome glyphs
// The content card's top edge, under the buttons (the Mac's card is 10 in from the top; on
// Windows the buttons take that band).
constexpr float kContentTop = kButtonHeight;
}  // namespace title_bar

enum class CaptionButton { Minimize, Maximize, Close };

// What a point of the client area is, for WM_NCHITTEST: something Kite draws and handles
// (Client), where dragging moves the window (Drag: the band above the card and the sidebar's top
// row, the Mac's title bar area), or a caption button.
enum class TitleBarArea { Client, Drag, Minimize, Maximize, Close };

// At (x, y) points from the client area's top-left, in a client area `width` wide whose sidebar
// is `sidebarWidth` wide.
TitleBarArea TitleBarAreaAt(float width, float sidebarWidth, float x, float y);
std::optional<CaptionButton> CaptionButtonOf(TitleBarArea area);
// A button's left edge, in a client area `width` wide (its top is 0).
float CaptionButtonLeft(float width, CaptionButton button);

}  // namespace kite
