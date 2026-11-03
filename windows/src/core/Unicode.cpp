// See Unicode.h.

#include "core/Unicode.h"

#include <algorithm>
#include <iterator>

namespace kite::unicode {
namespace {

struct CodePointRange {
    char32_t first, last;
};

struct LowercaseMapping {
    char32_t from, to;
};

struct ValuedRange {
    char32_t first, last;
    unsigned value;
};

struct Decomposition {
    char32_t code;
    unsigned offset, length;  // into kDecompositionPool
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

bool IsLetter(char32_t c) { return c < 0x80 ? (c | 0x20) >= U'a' && (c | 0x20) <= U'z' : InTable(kAlphabetic, c); }
bool IsNumber(char32_t c) { return c < 0x80 ? c >= U'0' && c <= U'9' : InTable(kNumeric, c); }

namespace {

enum class Break { Other, CR, LF, Control, Extend, ZWJ, SpacingMark, Prepend, RegionalIndicator, L, V, T, LV, LVT };

Break BreakClass(char32_t c) {
    if (c == 0x0D) return Break::CR;
    if (c == 0x0A) return Break::LF;
    if (c == 0x200D) return Break::ZWJ;
    if (c >= 0xAC00 && c <= 0xD7A3) return (c - 0xAC00) % 28 == 0 ? Break::LV : Break::LVT;  // Hangul syllables
    if (InTable(kGcbControl, c)) return Break::Control;
    if (InTable(kGcbExtend, c)) return Break::Extend;
    if (InTable(kGcbSpacingMark, c)) return Break::SpacingMark;
    if (InTable(kGcbPrepend, c)) return Break::Prepend;
    if (InTable(kGcbRegionalIndicator, c)) return Break::RegionalIndicator;
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

std::vector<bool> CharacterStarts(std::u32string_view text) {
    std::vector<bool> starts(text.size() + 1, true);
    Break previous = Break::Control;  // never joins: the first scalar starts a character
    // The rules that look further back than one scalar:
    enum class Emoji { None, Pictographic, PictographicZWJ } emoji = Emoji::None;  // GB11
    enum class Conjunct { None, Consonant, Linked } conjunct = Conjunct::None;      // GB9c
    size_t regionalRun = 0;  // regional indicators just before (GB12, GB13)
    for (size_t i = 0; i < text.size(); ++i) {
        const char32_t c = text[i];
        // ASCII (most of any title or address) has none of the properties but the controls.
        const bool ascii = c < 0x80;
        const Break current = ascii ? (c == 0x0D ? Break::CR : c == 0x0A ? Break::LF : c < 0x20 || c == 0x7F ? Break::Control : Break::Other)
                                    : BreakClass(c);
        const bool pictographic = !ascii && InTable(kExtendedPictographic, c);
        const bool consonant = !ascii && InTable(kInCBConsonant, c);
        bool joins = i > 0 && Joins(previous, current);
        // GB9c: Consonant [Extend Linker]* Linker [Extend Linker]* × Consonant.
        if (i > 0 && consonant && conjunct == Conjunct::Linked) joins = true;
        // GB11: ExtPict Extend* ZWJ × ExtPict.
        if (i > 0 && pictographic && emoji == Emoji::PictographicZWJ) joins = true;
        // GB12, GB13: flags pair up regional indicators, two at a time.
        if (i > 0 && current == Break::RegionalIndicator && regionalRun % 2 == 1) joins = true;
        starts[i] = !joins;

        if (pictographic) emoji = Emoji::Pictographic;
        else if (current == Break::Extend && emoji == Emoji::Pictographic) emoji = Emoji::Pictographic;
        else if (current == Break::ZWJ && emoji == Emoji::Pictographic) emoji = Emoji::PictographicZWJ;
        else emoji = Emoji::None;
        if (consonant) conjunct = Conjunct::Consonant;
        else if (conjunct != Conjunct::None && !ascii && InTable(kInCBLinker, c)) conjunct = Conjunct::Linked;
        else if (conjunct != Conjunct::None && (ascii || !InTable(kInCBExtend, c))) conjunct = Conjunct::None;
        regionalRun = current == Break::RegionalIndicator ? regionalRun + 1 : 0;
        previous = current;
    }
    return starts;
}

std::vector<std::u32string> Characters(std::string_view utf8) {
    const std::vector<char32_t> scalars = Decode(utf8);
    const std::u32string_view text(scalars.data(), scalars.size());
    const std::vector<bool> starts = CharacterStarts(text);
    std::vector<std::u32string> out;
    for (size_t i = 0; i < text.size(); ++i) {
        if (starts[i]) out.emplace_back();
        out.back().push_back(text[i]);
    }
    return out;
}

namespace {

unsigned CombiningClass(char32_t c) {
    auto it = std::upper_bound(std::begin(kCombiningClass), std::end(kCombiningClass), c,
                               [](char32_t value, const ValuedRange& r) { return value < r.first; });
    return it != std::begin(kCombiningClass) && c <= std::prev(it)->last ? std::prev(it)->value : 0;
}

void AppendDecomposed(char32_t c, std::u32string& out) {
    if (c >= 0xAC00 && c <= 0xD7A3) {  // Hangul syllables: L V (T), by arithmetic (Unicode §3.12)
        const char32_t index = c - 0xAC00;
        out += static_cast<char32_t>(0x1100 + index / 588);
        out += static_cast<char32_t>(0x1161 + (index % 588) / 28);
        if (index % 28) out += static_cast<char32_t>(0x11A7 + index % 28);
        return;
    }
    auto it = std::lower_bound(std::begin(kDecompositions), std::end(kDecompositions), c,
                               [](const Decomposition& d, char32_t value) { return d.code < value; });
    if (it == std::end(kDecompositions) || it->code != c) {
        out += c;
        return;
    }
    out.append(kDecompositionPool + it->offset, it->length);
}

}  // namespace

namespace {

// Canonical decomposition in place of `text`'s code points, then canonical ordering.
std::u32string DecomposeScalars(std::u32string_view text) {
    std::u32string out;
    out.reserve(text.size());
    for (char32_t c : text) AppendDecomposed(c, out);
    // Canonical ordering: each run of combining marks sorted by class, stably.
    for (size_t i = 0; i < out.size();) {
        if (CombiningClass(out[i]) == 0) {
            ++i;
            continue;
        }
        size_t end = i;
        while (end < out.size() && CombiningClass(out[end]) != 0) ++end;
        std::stable_sort(out.begin() + static_cast<std::ptrdiff_t>(i), out.begin() + static_cast<std::ptrdiff_t>(end),
                         [](char32_t a, char32_t b) { return CombiningClass(a) < CombiningClass(b); });
        i = end;
    }
    return out;
}

void AppendLowercased(char32_t c, std::u32string& out) {
    if (c == 0x130) {  // İ: the one mapping to two scalars (SpecialCasing)
        out += U"i\u0307";
        return;
    }
    if (c < 0x80) {
        out += (c >= U'A' && c <= U'Z') ? c + 32 : c;
        return;
    }
    auto it = std::lower_bound(std::begin(kLowercase), std::end(kLowercase), c,
                               [](const LowercaseMapping& m, char32_t value) { return m.from < value; });
    out += it != std::end(kLowercase) && it->from == c ? it->to : c;
}

bool IsAscii(std::string_view utf8) {
    return std::all_of(utf8.begin(), utf8.end(), [](char b) { return static_cast<unsigned char>(b) < 0x80; });
}

}  // namespace

std::string Decomposed(std::string_view utf8) {
    if (IsAscii(utf8)) return std::string(utf8);  // ASCII has no decompositions or marks
    const std::vector<char32_t> scalars = Decode(utf8);
    return Encode(DecomposeScalars(std::u32string_view(scalars.data(), scalars.size())));
}

std::u32string Folded(std::string_view utf8) {
    std::u32string lowered;
    lowered.reserve(utf8.size());
    for (size_t i = 0; i < utf8.size();) {
        char32_t c = 0;
        i += DecodeOne(utf8, i, c);
        AppendLowercased(c, lowered);
    }
    return DecomposeScalars(lowered);
}

std::string Encode(std::u32string_view codePoints) {
    std::string out;
    out.reserve(codePoints.size());
    for (char32_t c : codePoints) {
        if ((c >= 0xD800 && c <= 0xDFFF) || c > 0x10FFFF) c = 0xFFFD;
        if (c < 0x80) {
            out += static_cast<char>(c);
        } else if (c < 0x800) {
            out += static_cast<char>(0xC0 | (c >> 6));
            out += static_cast<char>(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out += static_cast<char>(0xE0 | (c >> 12));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (c >> 18));
            out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        }
    }
    return out;
}

std::string Lowercased(std::string_view utf8) {
    if (IsAscii(utf8)) {
        std::string out(utf8);
        for (char& b : out) {
            if (b >= 'A' && b <= 'Z') b = static_cast<char>(b + 32);
        }
        return out;
    }
    std::u32string lowered;
    lowered.reserve(utf8.size());
    for (char32_t c : Decode(utf8)) AppendLowercased(c, lowered);
    return Encode(lowered);
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
