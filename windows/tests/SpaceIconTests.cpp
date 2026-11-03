// What a space's icon shows (core/SpaceIcon.h): the Mac's icon prefixes, its picture names
// (SpacesTests.anImageIconIsAFileNameInTheIconsFolder's names) and the symbols' stand-ins.

#include <set>
#include <string>
#include <string_view>

#include "Check.h"
#include "core/OKLab.h"
#include "core/SpaceIcon.h"

using namespace kite;
using Kind = SpaceIconLook::Kind;

TEST(anIconIsAnEmojiASymbolAPictureOrADot) {
    Theme theme = Theme::Presets()[3];
    CHECK(SpaceIconLookOf("", theme).kind == Kind::Dot);
    const SpaceIconLook emoji = SpaceIconLookOf("🏠", theme);
    CHECK(emoji.kind == Kind::Emoji && emoji.text == "🏠" && !emoji.glyph);
    const SpaceIconLook symbol = SpaceIconLookOf("symbol:briefcase", theme);
    CHECK(symbol.kind == Kind::Symbol && symbol.text == "briefcase" && symbol.glyph && symbol.accent == Accent(theme));
    const SpaceIconLook picture = SpaceIconLookOf("image:3F2A.png", theme);
    CHECK(picture.kind == Kind::Picture && picture.text == "3F2A.png");
}

TEST(aSymbolWindowsHasNoGlyphForDrawsNothing) {
    // NSImage(systemSymbolName:) is nil for a name SF Symbols doesn't have, and the view is blank.
    const SpaceIconLook look = SpaceIconLookOf("symbol:not.a.symbol", Theme{});
    CHECK(look.kind == Kind::Symbol && !look.glyph);
    CHECK(!SymbolGlyphFor(""));
}

TEST(aPictureNameIsABareFileName) {
    CHECK(IsValidIconImageName("3F2A.png"));
    for (std::string_view bad : {"../../etc/passwd", "a/b.png", "a\\b.png", ".hidden", "", "c:x.png"}) CHECK(!IsValidIconImageName(bad));
    // At most 128 characters, counted as Swift counts them (one per emoji, not per byte).
    CHECK(IsValidIconImageName(std::string(128, 'a')));
    CHECK(!IsValidIconImageName(std::string(129, 'a')));
    std::string emoji;
    for (int i = 0; i < 128; ++i) emoji += "🏠";
    CHECK(IsValidIconImageName(emoji));
    // A bad name is still a picture: the one that can't be found (the Mac's placeholder).
    const SpaceIconLook look = SpaceIconLookOf("image:a/b.png", Theme{});
    CHECK(look.kind == Kind::Picture && look.text.empty());
}

TEST(everySymbolTheIconTabOffersHasAGlyphInBothFonts) {
    const auto& names = IconTabSymbols();
    CHECK(names.size() == 56);
    CHECK(names.front() == "star.fill" && names.back() == "tram.fill");
    CHECK(std::set<std::string_view>(names.begin(), names.end()).size() == names.size());
    std::vector<std::string_view> all(names.begin(), names.end());
    all.push_back("briefcase");
    all.push_back("photo");
    for (std::string_view name : all) {
        const auto glyph = SymbolGlyphFor(name);
        CHECK(glyph && glyph->fluent >= 0xE700 && glyph->fluent <= 0xF8FF && glyph->mdl2 >= 0xE700 && glyph->mdl2 <= 0xF8FF);
    }
    // Where the fonts differ (checked against each one's cmap on the PC).
    CHECK(SymbolGlyphFor("folder.fill") == (SymbolGlyph{u'', u''}));
    CHECK(SymbolGlyphFor("briefcase") == (SymbolGlyph{u'', u''}));
}
