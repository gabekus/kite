#pragma once
// Unicode classification for text typed by people (URL input, names): UTF-8 decoding and the
// character classes Swift's Character offers, from generated tables (UnicodeTables.inc).

#include <cstdint>
#include <string_view>
#include <vector>

namespace kite::unicode {

// Code points of UTF-8 text; each invalid byte becomes U+FFFD.
std::vector<char32_t> Decode(std::string_view utf8);

// Unicode's White_Space property (Swift's Character.isWhitespace / CharacterSet.whitespacesAndNewlines).
bool IsWhitespace(char32_t c);
bool IsLetter(char32_t c);  // general category L*
bool IsNumber(char32_t c);  // general category N*
bool IsMark(char32_t c);    // general category M*: combines with the character before it

// Trims leading and trailing Unicode whitespace.
std::string_view Trim(std::string_view utf8);

}  // namespace kite::unicode
