// See Unicode.h.

#include "core/Unicode.h"

#include <algorithm>
#include <iterator>

namespace kite::unicode {
namespace {

struct CodePointRange {
    char32_t first, last;
};

#include "core/UnicodeTables.inc"

template <size_t N>
bool InTable(const CodePointRange (&table)[N], char32_t c) {
    auto it = std::upper_bound(std::begin(table), std::end(table), c,
                               [](char32_t value, const CodePointRange& r) { return value < r.first; });
    return it != std::begin(table) && c <= std::prev(it)->last;
}

// Decodes one code point at `s[i]`, returning its length (1 for an invalid byte, decoded as U+FFFD).
size_t DecodeOne(std::string_view s, size_t i, char32_t& out) {
    auto byte = [&](size_t k) { return i + k < s.size() ? static_cast<unsigned char>(s[i + k]) : 0u; };
    auto cont = [&](size_t k, unsigned lo = 0x80, unsigned hi = 0xBF) { unsigned b = byte(k); return b >= lo && b <= hi; };
    unsigned c = byte(0);
    if (c < 0x80) { out = c; return 1; }
    if (c >= 0xC2 && c <= 0xDF && cont(1)) { out = ((c & 0x1F) << 6) | (byte(1) & 0x3F); return 2; }
    bool three = (c == 0xE0 && cont(1, 0xA0)) || (c == 0xED && cont(1, 0x80, 0x9F)) || (((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) && cont(1));
    if (three && cont(2)) { out = ((c & 0x0F) << 12) | ((byte(1) & 0x3F) << 6) | (byte(2) & 0x3F); return 3; }
    bool four = (c == 0xF0 && cont(1, 0x90)) || (c >= 0xF1 && c <= 0xF3 && cont(1)) || (c == 0xF4 && cont(1, 0x80, 0x8F));
    if (four && cont(2) && cont(3)) {
        out = ((c & 0x07) << 18) | ((byte(1) & 0x3F) << 12) | ((byte(2) & 0x3F) << 6) | (byte(3) & 0x3F);
        return 4;
    }
    out = 0xFFFD;
    return 1;
}

}  // namespace

std::vector<char32_t> Decode(std::string_view utf8) {
    std::vector<char32_t> out;
    out.reserve(utf8.size());
    for (size_t i = 0; i < utf8.size();) {
        char32_t c = 0;
        i += DecodeOne(utf8, i, c);
        out.push_back(c);
    }
    return out;
}

bool IsWhitespace(char32_t c) {
    switch (c) {
    case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: case 0x20: case 0x85: case 0xA0:
    case 0x1680: case 0x2028: case 0x2029: case 0x202F: case 0x205F: case 0x3000:
        return true;
    default:
        return c >= 0x2000 && c <= 0x200A;
    }
}

bool IsLetter(char32_t c) { return InTable(kAlphabetic, c); }
bool IsNumber(char32_t c) { return InTable(kNumeric, c); }

namespace {

enum class Break { Other, CR, LF, Control, Extend, ZWJ, SpacingMark, Prepend, L, V, T, LV, LVT };

Break BreakClass(char32_t c) {
    if (c == 0x0D) return Break::CR;
    if (c == 0x0A) return Break::LF;
    if (c == 0x200D) return Break::ZWJ;
    if (c >= 0xAC00 && c <= 0xD7A3) return (c - 0xAC00) % 28 == 0 ? Break::LV : Break::LVT;  // Hangul syllables
    if (InTable(kGcbControl, c)) return Break::Control;
    if (InTable(kGcbExtend, c)) return Break::Extend;
    if (InTable(kGcbSpacingMark, c)) return Break::SpacingMark;
    if (InTable(kGcbPrepend, c)) return Break::Prepend;
    if (InTable(kGcbL, c)) return Break::L;
    if (InTable(kGcbV, c)) return Break::V;
    if (InTable(kGcbT, c)) return Break::T;
    return Break::Other;
}

// UAX #29 GB3–GB9b: whether a and b stay in one character.
bool Joins(Break a, Break b) {
    if (a == Break::CR && b == Break::LF) return true;                                        // GB3
    if (a == Break::CR || a == Break::LF || a == Break::Control) return false;                // GB4
    if (b == Break::CR || b == Break::LF || b == Break::Control) return false;                // GB5
    if (a == Break::L && (b == Break::L || b == Break::V || b == Break::LV || b == Break::LVT)) return true;  // GB6
    if ((a == Break::LV || a == Break::V) && (b == Break::V || b == Break::T)) return true;   // GB7
    if ((a == Break::LVT || a == Break::T) && b == Break::T) return true;                     // GB8
    if (b == Break::Extend || b == Break::ZWJ || b == Break::SpacingMark) return true;        // GB9, GB9a
    return a == Break::Prepend;                                                                // GB9b
}

}  // namespace

std::vector<std::u32string> Characters(std::string_view utf8) {
    std::vector<std::u32string> out;
    Break previous = Break::Control;  // never joins: the first scalar starts a character
    for (char32_t c : Decode(utf8)) {
        Break current = BreakClass(c);
        if (out.empty() || !Joins(previous, current)) out.emplace_back();
        out.back().push_back(c);
        previous = current;
    }
    return out;
}

std::string_view Trim(std::string_view utf8) {
    size_t start = 0, end = utf8.size();
    while (start < end) {
        char32_t c = 0;
        size_t length = DecodeOne(utf8, start, c);
        if (!IsWhitespace(c)) break;
        start += length;
    }
    // Walk back over trailing whitespace: find the start of each last code point.
    while (end > start) {
        size_t begin = end - 1;
        while (begin > start && (static_cast<unsigned char>(utf8[begin]) & 0xC0) == 0x80) --begin;
        char32_t c = 0;
        size_t length = DecodeOne(utf8, begin, c);
        if (begin + length != end || !IsWhitespace(c)) break;
        end = begin;
    }
    return utf8.substr(start, end - start);
}

}  // namespace kite::unicode
