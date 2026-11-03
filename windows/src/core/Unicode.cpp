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

bool IsLetter(char32_t c) { return InTable(kLetters, c); }
bool IsNumber(char32_t c) { return InTable(kNumbers, c); }
bool IsMark(char32_t c) { return InTable(kMarks, c); }

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
