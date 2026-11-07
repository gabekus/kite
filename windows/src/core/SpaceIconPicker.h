#pragma once
// Arc's Change Space Icon popover, platform-free: its tabs, the emoji grid with its search and
// category bar, the Icon tab's grid, where each part sits, what a point in it hits, and what a
// pick does. Port of the Mac's SpaceIconPicker and EmojiCatalog (SpaceIconPicker.swift),
// ArcMetrics.SpaceIconPicker and SpaceIconImages.discard. The shell draws it in a window of its
// own under the header's icon (shell/SpaceIconPickerView).
//
// The Mac's third tab, Image (a picture of your own: choose a file, drop one, paste), is Kite's
// own and isn't on Windows yet: the tab shows, disabled, so the control keeps the Mac's shape.

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "core/Models.h"
#include "core/SpaceIcon.h"

namespace kite {

// ArcMetrics.SpaceIconPicker and the picker's SwiftUI layout, in points.
namespace icon_picker_metrics {
constexpr float kWidth = 272;
constexpr float kInset = 12;
constexpr size_t kEmojiColumns = 7;
constexpr float kEmojiPitch = 33.5f;  // also every cell's frame width, the Icon tab's too
constexpr float kRowPitch = 33;
constexpr float kEmojiGridHeight = 165;
constexpr size_t kIconColumns = 8;
constexpr float kIconPitch = 31;
constexpr float kEmojiFontSize = 22;     // Text(e).font(.system(size: 22))
constexpr float kSymbolSize = 16;        // the Icon tab's, semibold, in labelColor
constexpr float kBarSymbolSize = 14;     // the category bar's and the bin's
constexpr float kCategoryHeight = 30;    // each category button's minHeight
constexpr float kCategoryBottom = 6;
constexpr float kCategoryDimmed = 0.6f;  // a category that isn't the current one
constexpr float kSpacing = 8;            // the tabs and the bin (HStack(spacing: 8))
constexpr float kSearchTop = 10;
constexpr float kIconGridTop = 12;
constexpr float kDividerThickness = 1;
// AppKit's own controls and the popover's frame, which the Mac doesn't size itself: AppKit's
// regular segmented control and rounded-border field, SF's trash at 14pt, NSPopover's arrow and
// corners. The UI gate (review/w9e-mac) measured the arrow: NSPopover's window is its content
// plus 13pt on every side (298x294 for the Emoji tab's 272x268), its top at the arrow's tip, and
// the tabs 25pt under it. The arrow's width and the corners aren't in the in-process capture.
constexpr float kTabsHeight = 22;
constexpr float kSearchHeight = 22;
constexpr float kSearchBezelInset = 1;  // the rounded-border field draws its bezel 1pt in from its frame
constexpr float kRemoveWidth = 15;
constexpr float kArrowHeight = 13, kArrowWidth = 22;
constexpr float kCornerRadius = 10;
// How far from the screen's edge AppKit keeps a popover.
constexpr float kScreenMargin = 4;
}  // namespace icon_picker_metrics

enum class IconPickerTab { Emoji, Icon, Image };
inline constexpr IconPickerTab kIconPickerTabs[] = {IconPickerTab::Emoji, IconPickerTab::Icon, IconPickerTab::Image};
// The segment's word ("Emoji", "Icon", "Image").
std::string_view IconPickerTabTitle(IconPickerTab tab);
// Whether Windows has the tab yet: not Image (pictures of your own come later).
bool IconPickerTabAvailable(IconPickerTab tab);
// The tab the picker opens on, the one the space's icon came from (the Mac's init): a symbol's
// Icon, an emoji's (or none's) Emoji. A picture's would be Image; until Windows has it, Emoji.
IconPickerTab IconPickerOpeningTab(std::string_view icon);

// One of the emoji grid's categories (EmojiCatalog.Category): its name (the button's help),
// the SF Symbol of its button in the bar along the bottom with that symbol's stand-in glyph in
// Segoe Fluent Icons and Segoe MDL2 Assets (picked by eye from each font's glyphs, checked
// against both fonts' cmaps), and its emoji, each one Character as the Mac splits them.
struct EmojiCategory {
    std::string name, symbol;
    SymbolGlyph glyph;
    std::vector<std::string> emoji;
};
const std::vector<EmojiCategory>& EmojiCategories();
// Every category's emoji in order: the grid with no search.
const std::vector<std::string>& AllEmoji();
// An emoji's Unicode name, lowercased, for search (EmojiCatalog.name: ICU's Any-Name transform,
// "\N{NAME}" for each code point, so "☺️" is "\n{white smiling face}\n{variation selector-16}").
// Empty for text with a code point the catalog doesn't have (anything not in the grid).
std::string EmojiName(std::string_view emoji);
// The grid's emoji for what's typed in Search (the Mac's `emoji`): all of them for nothing but
// spaces, else those whose name holds it, trimmed of spaces and tabs and lowercased.
std::vector<std::string> EmojiMatching(std::string_view query);
// The bin's stand-in for SF's "trash" (Remove Icon), as the categories' glyphs.
SymbolGlyph RemoveIconGlyph();

// The picker's own state (its @State): which tab, what's in Search, the category last chosen
// in the bar, and how far the emoji grid is scrolled.
struct IconPickerState {
    std::string spaceID;
    IconPickerTab tab = IconPickerTab::Emoji;
    std::string query;
    size_t category = 0;
    float scroll = 0;  // points, the emoji grid's
    bool operator==(const IconPickerState&) const = default;
};
// The picker as it opens for space `spaceID`: on its icon's tab, nothing searched, the first
// category. None for no such space.
std::optional<IconPickerState> OpenIconPicker(const BrowserState& state, const std::string& spaceID);

// A rectangle in the popover's content (its top-left at the content's, under the arrow), in points.
struct PickerRect {
    float left = 0, top = 0, right = 0, bottom = 0;
    float Width() const { return right - left; }
    float Height() const { return bottom - top; }
    bool Contains(float x, float y) const { return x >= left && x < right && y >= top && y < bottom; }
    bool operator==(const PickerRect&) const = default;
};

// Where the parts of the picker sit for `tab`, with the bin (`removable`, the space has an icon)
// or without.
struct IconPickerLayout {
    float width = 0, height = 0;  // the content's
    PickerRect tabs;              // the segmented control
    std::vector<PickerRect> segments;  // its segments, in kIconPickerTabs' order
    std::optional<PickerRect> remove;  // the bin
    std::optional<PickerRect> search;  // the emoji tab's field
    PickerRect grid;                   // the emoji tab's scroll view, or the Icon tab's grid
    std::optional<PickerRect> divider; // the emoji tab's, over its category bar
    std::vector<PickerRect> categories;  // the emoji tab's category buttons
    size_t columns = 0;
    float pitch = 0;      // the columns'
    float gridLeft = 0;   // the first column's left in `grid` (the grid is centred in it)
    bool operator==(const IconPickerLayout&) const = default;
};
IconPickerLayout LayOutIconPicker(IconPickerTab tab, bool removable);

// What the grid shows for `state`: the matching emoji, or the Icon tab's symbols (empty on the
// Image tab). Each cell's icon is what a pick sets: the emoji, or "symbol:" and the name.
std::vector<std::string> IconPickerCells(const IconPickerState& state);
size_t IconPickerRows(size_t cells, size_t columns);
// The emoji grid's furthest scroll for `cells` emoji: its rows past the scroll view's height.
float IconPickerMaxScroll(size_t cells);
// Cell `index`'s frame in the content, the grid scrolled `scroll` points (the Mac's cell(): the
// emoji's pitch wide and a row tall, centred on its column, so the Icon tab's overlap).
PickerRect IconPickerCellFrame(const IconPickerLayout& layout, size_t index, float scroll);
// The grid's rows that show any of the scroll view at `scroll` (the emoji tab's lazy grid draws
// only those), as [first, end).
std::pair<size_t, size_t> IconPickerVisibleRows(const IconPickerLayout& layout, size_t cells, float scroll);

// What a point in the content is over.
struct IconPickerHit {
    enum class Target { None, Tab, Remove, Search, Cell, Category };
    Target target = Target::None;
    size_t index = 0;  // Tab: which (kIconPickerTabs), Cell: which cell, Category: which
    bool operator==(const IconPickerHit&) const = default;
};
// Over the grid, only where the scroll view shows it; where two cells' frames overlap (the Icon
// tab's), the later one, drawn over the other. A disabled tab (Image) takes nothing.
IconPickerHit IconPickerHitTest(const IconPickerLayout& layout, const IconPickerState& state, size_t cells, float x, float y);

// The picker's actions, as its controls change its state.
// A segment: that tab. The emoji grid that comes back is a new scroll view, at its top.
void SelectIconPickerTab(IconPickerState& state, IconPickerTab tab);
// What's in Search changed: the grid is the matching emoji (returned: the cells), its scroll
// kept where it fits.
std::vector<std::string> SetIconPickerQuery(IconPickerState& state, std::string query);
// A category's button: Search cleared and that category chosen; when the choice changed (the
// Mac's onChange), the grid scrolls its first emoji to the top, as far as it goes.
void SelectIconPickerCategory(IconPickerState& state, size_t category);
// The wheel over the emoji grid, `distance` points down (negative: up), within the rows of its
// `cells` (IconPickerCells' count, which the caller has).
void ScrollIconPicker(IconPickerState& state, float distance, size_t cells);

// A pick (the Mac's pick): space `spaceID` gets `icon` (BrowserState::SetSpaceIcon), and the
// picture the old icon showed, if it was one and no space shows it now, is the file to delete
// from the SpaceIcons folder (SpaceIconImages.discard). The space's icon after it, and that file.
struct IconPick {
    std::string icon;
    std::optional<std::string> discard;
};
std::optional<IconPick> PickSpaceIcon(BrowserState& state, const std::string& spaceID, std::string_view icon);
// SpaceIconImages.discard on its own: the file behind `oldIcon` once nothing in `spaces` shows it.
std::optional<std::string> PictureToDiscard(const std::string& oldIcon, const std::vector<Space>& spaces);

// Where the popover goes (NSPopover.show relative to the header's icon, preferredEdge maxY of a
// flipped view): under `anchor` (its frame in screen points), its arrow's tip at the middle of the
// anchor's bottom, the popover centred on it, then moved sideways to stay kScreenMargin inside
// `screen` (the arrow stays on the anchor, inside the rounded corners). Its frame takes the
// arrow's height above the content.
struct IconPickerPlacement {
    float left = 0, top = 0;  // the frame's, screen points
    float width = 0, height = 0;
    float arrowX = 0;  // the arrow's tip, from the frame's left
    bool operator==(const IconPickerPlacement&) const = default;
};
IconPickerPlacement PlaceIconPicker(const PickerRect& anchor, float contentWidth, float contentHeight, const PickerRect& screen);

// An Icon tab symbol's ink as the Mac draws it (16pt semibold), which its Segoe stand-in is fitted
// to: the ink's box (Segoe's is scaled so its sides' geometric mean is this box's), the ink's
// middle from the cell's, and how much heavier it's drawn (its outline stroked this wide, in
// points) where Segoe's stand-in is lighter than SF's at the same box. Measured in the UI gate
// (review/w9e-mac picker-icon, the 28 symbols its capture shows: columns 5-8); the other 28 take
// those's medians (`measured` false). Matched by box, area, weight and centre; no SF Symbol traced.
struct IconTabInk {
    float width = 0, height = 0;  // the ink's box, points
    float dx = 0, dy = 0;         // its middle from the cell's
    float stroke = 0;             // extra weight: the outline stroked this wide too
    bool measured = false;
};
IconTabInk IconTabInkFor(std::string_view symbol);

// The category bar's and the bin's symbols (regular 14pt on the Mac): their size as a fraction of
// the bar's (briefcase) factor at 14pt, and an outline stroke for weight, per symbol. The UI gate
// measured the lightbulb, heart, flag, car and trash; the rest take 0.78 and no stroke.
struct BarGlyphFit {
    float scale = 0.78f;
    float stroke = 0;
};
BarGlyphFit BarGlyphFitFor(std::string_view symbol);

}  // namespace kite
