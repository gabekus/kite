#pragma once
// Unicode classification for text typed by people (URL input, names): UTF-8 decoding and the
// character classes Swift's Character offers, from generated tables (UnicodeTables.inc).

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace kite::unicode {

// Code points of UTF-8 text; each invalid byte becomes U+FFFD.
std::vector<char32_t> Decode(std::string_view utf8);

// UTF-8 for code points (U+FFFD for a surrogate or anything past U+10FFFF).
std::string Encode(std::u32string_view codePoints);

// Unicode's White_Space property (Swift's Character.isWhitespace / CharacterSet.whitespacesAndNewlines).
bool IsWhitespace(char32_t c);
bool IsLetter(char32_t c);  // Alphabetic: Swift's Character.isLetter on a character starting with c
bool IsNumber(char32_t c);  // Numeric_Type isn't None: Swift's Character.isNumber, likewise

// Text split into characters the way Swift's String is: extended grapheme clusters (UAX #29),
// so "e" + U+0301 or a Hangul syllable written as jamo is one character. Follows GB3–GB9b;
// emoji ZWJ sequences and flag pairs (GB11–GB13) are split, which no caller can tell apart
// since none of their parts is a letter or a number. Indic conjuncts (GB9c, Unicode 15.1) are
// split too: a TLD like "क्ष" counts as two characters here and may count as one on the Mac.
std::vector<std::u32string> Characters(std::string_view utf8);

// Trims leading and trailing Unicode whitespace.
std::string_view Trim(std::string_view utf8);

// Lowercased scalar by scalar with Unicode's full Lowercase_Mapping, as Swift's
// String.lowercased() does (no Final_Sigma context: "ΑΣ" becomes "ασ", not "ας").
std::string Lowercased(std::string_view utf8);

}  // namespace kite::unicode
