// core/Unicode: UTF-8 decoding, Swift's letter and number classes, grapheme clusters, trimming.

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
    // GB11: an emoji ZWJ sequence is one character; GB12/13: regional indicators pair up.
    CHECK(Characters("\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA7").size() == 1);  // 👨‍👧
    CHECK(Characters("\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xAC").size() == 2);  // 🇺🇸 + 🇬
    CHECK(Characters("a\xE2\x80\x8D\xF0\x9F\x91\xA7").size() == 2);  // ZWJ after a letter doesn't join an emoji
    // GB9c: क्ष is one character (consonant, virama, consonant); a virama alone doesn't join on.
    CHECK(Characters("\xE0\xA4\x95\xE0\xA5\x8D\xE0\xA4\xB7").size() == 1);
    CHECK(Characters("a\xE0\xA5\x8D\xE0\xA4\xB7").size() == 2);
}

TEST(trimsUnicodeWhitespaceOnly) {
    CHECK(Trim("\xE3\x80\x80 a b\xC2\xA0\n") == "a b");
    CHECK(Trim("\xC3\xA9") == "\xC3\xA9");
    CHECK(Trim("  ").empty());
}

TEST(decomposesCanonically) {
    CHECK(Decomposed("caf\xC3\xA9") == "cafe\xCC\x81");                      // é
    CHECK(Decomposed("\xE1\xBB\x87") == "e\xCC\xA3\xCC\x82");                 // ệ: dot below, then circumflex
    CHECK(Decomposed("e\xCC\x82\xCC\xA3") == "e\xCC\xA3\xCC\x82");             // marks put in canonical order
    CHECK(Decomposed("\xED\x95\x9C") == "\xE1\x84\x92\xE1\x85\xA1\xE1\x86\xAB");  // 한 → ᄒ ᅡ ᆫ
    CHECK(Decomposed("\xE2\x84\xAB") == "A\xCC\x8A");                         // Ångström sign
    CHECK(Decomposed("plain") == "plain");
}
