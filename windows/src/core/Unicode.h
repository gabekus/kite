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

// Text split into characters the way Swift's String is: extended grapheme clusters (UAX #29,
// Unicode 15.1, every rule GB3–GB13 including GB9c's Indic conjuncts), so "e" + U+0301, a
// Hangul syllable written as jamo, an emoji ZWJ sequence or a flag is one character.
std::vector<std::u32string> Characters(std::string_view utf8);
// The same, as where characters start: starts[i] for each code point, and starts[size()],
// which is always true.
std::vector<bool> CharacterStarts(std::u32string_view text);

// Canonical decomposition (NFD): canonically equivalent text ("é" and "e" + U+0301) comes
// out identical, so comparing it compares the way Swift's Character == does.
std::string Decomposed(std::string_view utf8);

// Trims leading and trailing Unicode whitespace.
std::string_view Trim(std::string_view utf8);

// Lowercased scalar by scalar with Unicode's full Lowercase_Mapping, as Swift's
// String.lowercased() does (no Final_Sigma context: "ΑΣ" becomes "ασ", not "ας").
std::string Lowercased(std::string_view utf8);

// Lowercased, then decomposed: the code points text is compared by when Swift compares the
// lowercased() strings' Characters (Character == is canonical equivalence). Callers split
// the folded text into Characters, so the decomposition applies to the whole text, not to
// each Character as Swift's does. The two differ only for contrived text, such as a
// precomposed Tibetan vowel inside a Devanagari conjunct, or marks out of canonical order
// right after a control character.
std::u32string Folded(std::string_view utf8);

}  // namespace kite::unicode
