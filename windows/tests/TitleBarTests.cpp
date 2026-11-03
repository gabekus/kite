// Kite for Windows' title bar geometry (core/TitleBar.h). Windows-only: the Mac's title bar is
// AppKit's, with the traffic lights in the sidebar's top row.

#include "Check.h"
#include "core/Sidebar.h"
#include "core/TitleBar.h"

using namespace kite;

TEST(theCaptionButtonsSitAtTheTopRightCorner) {
    // A 1280-point window: the buttons are the last 138 points of the top 32.
    CHECK(CaptionButtonLeft(1280, CaptionButton::Minimize) == 1142);
    CHECK(CaptionButtonLeft(1280, CaptionButton::Maximize) == 1188);
    CHECK(CaptionButtonLeft(1280, CaptionButton::Close) == 1234);
    CHECK(TitleBarAreaAt(1280, 240, 1142, 0) == TitleBarArea::Minimize);
    CHECK(TitleBarAreaAt(1280, 240, 1187.9f, 31.9f) == TitleBarArea::Minimize);
    CHECK(TitleBarAreaAt(1280, 240, 1188, 10) == TitleBarArea::Maximize);
    CHECK(TitleBarAreaAt(1280, 240, 1234, 10) == TitleBarArea::Close);
    CHECK(TitleBarAreaAt(1280, 240, 1279.9f, 0) == TitleBarArea::Close);
    // Under them is the card's corner, and past the window's edge nothing.
    CHECK(TitleBarAreaAt(1280, 240, 1270, 32) == TitleBarArea::Client);
    CHECK(TitleBarAreaAt(1280, 240, 1280, 10) == TitleBarArea::Client);
    // The smallest window keeps them in its corner.
    CHECK(TitleBarAreaAt(640, 240, 640 - 1, 1) == TitleBarArea::Close);
    CHECK(CaptionButtonOf(TitleBarArea::Maximize) == CaptionButton::Maximize);
    CHECK(!CaptionButtonOf(TitleBarArea::Drag));
}

TEST(theBandAboveTheCardAndTheSidebarsTopRowMoveTheWindow) {
    // The band left of the buttons, down to the card's top.
    CHECK(TitleBarAreaAt(1280, 240, 240, 0) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 1141.9f, 31.9f) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 700, title_bar::kContentTop) == TitleBarArea::Client);
    // The sidebar's top row, down to its address field, which takes clicks.
    CHECK(TitleBarAreaAt(1280, 240, 0, 0) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 120, sidebar_metrics::kUrlFieldTop - 0.1f) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 120, sidebar_metrics::kUrlFieldTop) == TitleBarArea::Client);
    CHECK(TitleBarAreaAt(1280, 240, 120, 400) == TitleBarArea::Client);
    CHECK(TitleBarAreaAt(1280, 240, -1, 5) == TitleBarArea::Client);
}

TEST(theSidebarsEdgeSplitsItsTopRowFromTheBand) {
    // Between the band's bottom and the address field: the sidebar's top row drags, the card
    // beside it is the card's.
    CHECK(TitleBarAreaAt(1280, 240, 239.9f, 40) == TitleBarArea::Drag);
    CHECK(TitleBarAreaAt(1280, 240, 240, 40) == TitleBarArea::Client);
    CHECK(TitleBarAreaAt(1280, 240, 240, 25) == TitleBarArea::Drag);
}

TEST(aFractionalWidthKeepsTheButtonsFlushRight) {
    // 1281 px at 150%: 854 points.
    const float width = 1281.0f / 1.5f;
    CHECK(TitleBarAreaAt(width, 240, width - 0.01f, 5) == TitleBarArea::Close);
    CHECK(TitleBarAreaAt(width, 240, width - title_bar::kButtonsWidth, 5) == TitleBarArea::Minimize);
    CHECK(TitleBarAreaAt(width, 240, width - title_bar::kButtonsWidth - 0.01f, 5) == TitleBarArea::Drag);
    CHECK(CaptionButtonOf(TitleBarArea::Minimize) == CaptionButton::Minimize);
    CHECK(CaptionButtonOf(TitleBarArea::Close) == CaptionButton::Close);
    CHECK(!CaptionButtonOf(TitleBarArea::Client));
}

TEST(at125PercentTheButtonsEdgesFallOnWholePixels) {
    // 46 points is 57.5 px: the edges sit 58, 115 and 173 px in from the right (rounded), the
    // same columns the buttons are drawn in.
    CHECK(CaptionEdgeFromRight(1, 1.25f) * 1.25f == 58);
    CHECK(CaptionEdgeFromRight(2, 1.25f) * 1.25f == 115);
    CHECK(CaptionEdgeFromRight(3, 1.25f) * 1.25f == 173);
    // A 1600-px client area (1280 points): the column 58 px in from the right is Close's.
    const float width = 1280;
    CHECK(TitleBarAreaAt(width, 240, (1600 - 58) / 1.25f, 5, 1.25f) == TitleBarArea::Close);
    CHECK(TitleBarAreaAt(width, 240, (1600 - 59) / 1.25f, 5, 1.25f) == TitleBarArea::Maximize);
    CHECK(TitleBarAreaAt(width, 240, (1600 - 173) / 1.25f, 5, 1.25f) == TitleBarArea::Minimize);
    CHECK(TitleBarAreaAt(width, 240, (1600 - 174) / 1.25f, 5, 1.25f) == TitleBarArea::Drag);
}
