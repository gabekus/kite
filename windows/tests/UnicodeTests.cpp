#include "Check.h"
#include "core/Unicode.h"

using namespace kite::unicode;

TEST(decodesUtf8AndReplacesInvalidBytes) {
    auto cps = Decode("a\xC3\xA9\xF0\x9F\x8F\xA0\xFF");
    CHECK(cps.size() == 4);
    CHECK(cps[0] == U'a' && cps[1] == 0xE9 && cps[2] == 0x1F3E0 && cps[3] == 0xFFFD);
}

TEST(classes) {
    CHECK(IsLetter(U'a') && IsLetter(0x00FC) && IsLetter(0x0440) && IsLetter(0x5929));
    CHECK(!IsLetter(U'1') && !IsLetter(0x2026) && !IsLetter(0x2192) && !IsLetter(0x1F3E0));
    CHECK(IsNumber(U'7') && IsNumber(0x0663));
    // Swift's classes are properties, not general categories: Roman numerals (Nl) and circled
    // letters (So, Other_Alphabetic) are letters; CJK numerals have a numeric type.
    CHECK(IsLetter(0x216B) && IsLetter(0x24B6) && IsNumber(0x4E00) && IsNumber(0x2155) && !IsLetter(0x0301));
    CHECK(IsWhitespace(0x3000) && IsWhitespace(0xA0) && IsWhitespace(0x2028) && !IsWhitespace(0x200B));
}

TEST(splitsIntoCharactersLikeSwift) {
    auto chars = Characters("e\xCC\x81x");  // e + U+0301, x
    CHECK(chars.size() == 2 && chars[0] == U"e\u0301" && chars[1] == U"x");
    // Hangul written as jamo (L V T) is one character, like the precomposed syllable.
    CHECK(Characters("\xE1\x84\x80\xE1\x85\xA1\xE1\x86\xA8").size() == 1);
    CHECK(Characters("\xED\x95\x9C\xEA\xB5\xAD").size() == 2);  // 한국
    CHECK(Characters("\r\n").size() == 1 && Characters("\n\xCC\x81").size() == 2);
    CHECK(Characters("a\xE2\x80\x8D").size() == 1);  // a + ZWJ
    CHECK(Characters("").empty());
}

TEST(trimsUnicodeWhitespaceOnly) {
    CHECK(Trim("\xE3\x80\x80 a b\xC2\xA0\n") == "a b");
    CHECK(Trim("\xC3\xA9") == "\xC3\xA9");
    CHECK(Trim("  ").empty());
}
