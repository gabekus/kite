// What a space's icon shows (core/SpaceIcon.h): the Mac's icon prefixes, its picture names
// (SpacesTests.anImageIconIsAFileNameInTheIconsFolder's names) and the symbols' stand-ins.

#include <cmath>
#include <set>
#include <string>
#include <string_view>

#include "Check.h"
#include "core/OKLab.h"
#include "core/Sidebar.h"
#include "core/SpaceBar.h"
#include "core/SpaceIcon.h"
#include "core/SymbolShape.h"

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

TEST(aSymbolWindowsHasNoStandInForShowsTheDot) {
    // The Mac draws any SF Symbol; Windows has stand-ins for the Icon tab's (and two more), so
    // another name (from automation or a hand-edited session) shows the icon-less dot.
    const SpaceIconLook look = SpaceIconLookOf("symbol:hare.fill", Theme{});
    CHECK(look.kind == Kind::Dot && look.text == "hare.fill" && !look.glyph);
    CHECK(!SymbolGlyphFor("") && !SymbolGlyphFor("star"));
}

TEST(aHeaderKeepsTheSlotOfAnIconThatShowsTheDot) {
    // SpaceHeaderRowCell keeps the icon's slot for any icon: the header row has the raw icon for
    // that, and the look for what draws (nothing, for a dot), while the bar shows the dot.
    BrowserState state;
    Space space;
    space.id = "s";
    space.icon = "symbol:hare.fill";
    state.spaces = {space};
    state.SelectSpace("s");
    const auto rows = SidebarRows(state, 0);
    CHECK(rows.front().kind == SidebarRow::Kind::Header && rows.front().icon == "symbol:hare.fill");
    CHECK(rows.front().look.kind == Kind::Dot);
    CHECK(SpaceCells(state).front().Dot());
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

TEST(everySymbolTheIconTabOffersHasAPrivateUseGlyphForBothFonts) {
    const auto& names = IconTabSymbols();
    CHECK(names.size() == 56);
    CHECK(names.front() == "star.fill" && names.back() == "tram.fill");
    CHECK(std::set<std::string_view>(names.begin(), names.end()).size() == names.size());
    std::vector<std::string_view> all(names.begin(), names.end());
    all.push_back("briefcase");
    all.push_back("photo");
    for (std::string_view name : all) {
        const auto glyph = SymbolGlyphFor(name);
        CHECK(glyph);
        if (!glyph || glyph->drawn) continue;
        CHECK(glyph->fluent >= 0xE700 && glyph->fluent <= 0xF8FF && glyph->mdl2 >= 0xE700 && glyph->mdl2 <= 0xF8FF);
    }
    // That each is in its font is the PC's cmap check (the table's comment). Where the fonts differ:
    CHECK(SymbolGlyphFor("folder.fill") == (SymbolGlyph{u'\uE8D5', u'\uF12B'}));
    // Nine have no such object in either font, and the briefcase's glyph is a plain case: Kite
    // draws its own shape for each, and only those. The briefcase keeps its glyph as the fallback.
    std::vector<std::string_view> drawn;
    for (std::string_view name : all) {
        const auto glyph = SymbolGlyphFor(name);
        if (!glyph) continue;  // failed above
        if (glyph->drawn) drawn.push_back(name);
        CHECK(glyph->drawn == (SymbolShapeFor(name) != nullptr));
    }
    CHECK(drawn == DrawnSymbols());
    CHECK(SymbolGlyphFor("pawprint.fill") == (SymbolGlyph{0, 0, true}));
    CHECK(SymbolGlyphFor("briefcase") == (SymbolGlyph{u'', u'', true}));
    CHECK(SymbolGlyphFor("star.fill") == (SymbolGlyph{u'\uE735', u'\uE735'}));
}

TEST(aPictureIsTheMacsRoundedSquareOnThePixelGrid) {
    // The bar's 12.5: 15pt, 30px at 2x, centred in its 36x34 cell; corners 3.3pt.
    const PictureFrame bar = PictureFrameAt(18, 17, 12.5f, 2);
    CHECK(bar.pixels == 30 && bar.side == 15 && bar.left == 10.5f && bar.top == 9.5f);
    CHECK(std::abs(bar.radius - 3.3f) < 1e-5f);
    // The header's 15: 18pt in its 26pt box.
    const PictureFrame header = PictureFrameAt(26, 18, 15, 2);
    CHECK(header.pixels == 36 && header.side == 18 && header.left == 17 && header.top == 9);
    // At 125% the side is whole pixels (19 for 15pt) and the corner sits on a pixel.
    const PictureFrame odd = PictureFrameAt(18, 17, 12.5f, 1.25f);
    CHECK(odd.pixels == 19 && std::abs(odd.side * 1.25f - 19) < 1e-4f);
    CHECK(std::abs(odd.left * 1.25f - std::round(odd.left * 1.25f)) < 1e-4f);
}

TEST(aSymbolGreysByItsTintAndTheRestThroughTheFilter) {
    // SpaceIconImageView: a symbol's tint is labelColor at 45%; an emoji and a picture get
    // CIColorControls (saturation 0) and an alpha of 45%.
    CHECK(GreysByTint(Kind::Symbol));
    CHECK(!GreysByTint(Kind::Emoji) && !GreysByTint(Kind::Picture));
}
