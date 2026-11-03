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
    CHECK(IsMark(0x0301) && !IsMark(U'e'));
    CHECK(IsWhitespace(0x3000) && IsWhitespace(0xA0) && IsWhitespace(0x2028) && !IsWhitespace(0x200B));
}

TEST(trimsUnicodeWhitespaceOnly) {
    CHECK(Trim("\xE3\x80\x80 a b\xC2\xA0\n") == "a b");
    CHECK(Trim("\xC3\xA9") == "\xC3\xA9");
    CHECK(Trim("  ").empty());
}
