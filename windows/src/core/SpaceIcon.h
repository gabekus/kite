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

// A symbol's glyph in each icon font (a private-use code point); 0 where that font has none.
struct SymbolGlyph {
    char16_t fluent = 0, mdl2 = 0;
    bool operator==(const SymbolGlyph&) const = default;
};
// The glyph standing in for an SF Symbol: every name the Mac's Icon tab offers (EmojiCatalog.symbols)
// and the picture placeholder's "photo". None for any other name, which, as on the Mac when
// NSImage has no such symbol, draws nothing.
std::optional<SymbolGlyph> SymbolGlyphFor(std::string_view name);
// The Icon tab's symbols, in its order (EmojiCatalog.symbols).
const std::vector<std::string_view>& IconTabSymbols();

// A bare file name in the SpaceIcons folder (Space.isValidIconImageName): not empty, at most 128
// characters, no leading dot, no path separator or colon.
bool IsValidIconImageName(std::string_view name);

// What one space's icon shows.
struct SpaceIconLook {
    enum class Kind { Dot, Emoji, Symbol, Picture };
    Kind kind = Kind::Dot;
    std::string text;   // the emoji, the symbol's name, or the picture's file name
    std::optional<SymbolGlyph> glyph;  // a symbol's, when there is one
    ThemeColor accent;  // a symbol's colour when lit (the theme's accent)
    bool operator==(const SpaceIconLook&) const = default;
};
// `icon` as Space.icon holds it, in a space themed `theme`. An `image:` name that isn't valid is
// a picture whose file can't be found (the Mac's placeholder).
SpaceIconLook SpaceIconLookOf(const std::string& icon, const Theme& theme);

}  // namespace kite
