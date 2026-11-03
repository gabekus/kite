#pragma once
// What a space's icon is, for every place that shows one (the space bar's cells, the page's
// header): an emoji, one of the Icon tab's SF Symbols, a picture in the SpaceIcons folder, or
// none (the bar's dot). Port of the Mac's Space.icon prefixes and SpaceIconImageView's choice
// (Models.swift, SidebarListRows.swift). Windows draws an SF Symbol as the nearest glyph in
// Segoe Fluent Icons (Windows 11), or Segoe MDL2 Assets where that's missing (Windows 10), both
// in the system: SF Symbols themselves are Apple's and only draw on Apple's systems.

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Models.h"

namespace kite {

inline constexpr std::string_view kSymbolIconPrefix = "symbol:";
inline constexpr std::string_view kImageIconPrefix = "image:";

// A symbol's glyph in each icon font (a private-use code point). `standIn`: neither font has the
// symbol's object, so it's the nearest glyph until it's drawn as geometry (W9b4).
struct SymbolGlyph {
    char16_t fluent = 0, mdl2 = 0;
    bool standIn = false;
    bool operator==(const SymbolGlyph&) const = default;
};
// The glyph standing in for an SF Symbol: every name the Mac's Icon tab offers (EmojiCatalog.symbols),
// "briefcase" and the picture placeholder's "photo". None for any other name.
std::optional<SymbolGlyph> SymbolGlyphFor(std::string_view name);
// The Icon tab's symbols, in its order (EmojiCatalog.symbols).
const std::vector<std::string_view>& IconTabSymbols();

// A bare file name in the SpaceIcons folder (Space.isValidIconImageName): not empty, at most 128
// characters, no leading dot, no path separator or colon.
bool IsValidIconImageName(std::string_view name);

// Where a picture icon draws, centred on (x, y) points for an icon size `size` at the window's
// `scale` (SpaceIconImageView.layout): round(size x 1.2) points on a side (SpaceIconView.imageSide),
// a whole number of pixels with its corner on the pixel grid, its corners 22% of the side.
struct PictureFrame {
    float left = 0, top = 0, side = 0;  // points; `side` is `pixels` at the scale
    float radius = 0;
    unsigned pixels = 0;
    bool operator==(const PictureFrame&) const = default;
};
PictureFrame PictureFrameAt(float x, float y, float size, float scale);
// A picture whose file is gone: the "photo" symbol at 0.8 of the icon size in
// secondaryLabelColor (white at 55% on dark, black at 50% on light).
inline constexpr float kPlaceholderSize = 0.8f;
inline constexpr float kPlaceholderAlphaDark = 0.55f, kPlaceholderAlphaLight = 0.5f;

// What one space's icon shows.
struct SpaceIconLook {
    enum class Kind { Dot, Emoji, Symbol, Picture };
    Kind kind = Kind::Dot;
    std::string text;   // the emoji, the symbol's name, or the picture's file name
    std::optional<SymbolGlyph> glyph;  // a symbol's (always there)
    ThemeColor accent;  // a symbol's colour when lit (the theme's accent)
    bool operator==(const SpaceIconLook&) const = default;
};
// `icon` as Space.icon holds it, in a space themed `theme`. An `image:` name that isn't valid is
// a picture whose file can't be found (the Mac's placeholder). A symbol with no stand-in (any SF
// Symbol name but the 58, which the Mac draws and Windows can't) shows the icon-less dot, rather
// than the blank the Mac shows only for a name SF Symbols doesn't have.
SpaceIconLook SpaceIconLookOf(const std::string& icon, const Theme& theme);
// How a greyed icon greys (SpaceIconImageView.applyIcon): a symbol is tinted labelColor at 45%;
// an emoji or a picture keeps its drawing through a saturation-0 filter inside a 45% fade.
bool GreysByTint(SpaceIconLook::Kind kind);

}  // namespace kite
