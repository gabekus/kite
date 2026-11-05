// See TextMatch.h.

#include "core/TextMatch.h"

#include <algorithm>

#include "core/Unicode.h"

namespace kite::text_match {
namespace {

char AsciiLower(char b) { return b >= 'A' && b <= 'Z' ? static_cast<char>(b + 32) : b; }
bool IsAsciiWordCharacter(char b) { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9'); }

}  // namespace

std::string TrimmedLowercase(std::string_view text) { return unicode::Lowercased(unicode::Trim(text)); }

std::string ReplaceAll(std::string text, std::string_view from, std::string_view to) {
    for (size_t at = text.find(from); at != std::string::npos; at = text.find(from, at + to.size())) {
        text.replace(at, from.size(), to);
    }
    return text;
}

bool IsAscii(std::string_view text) {
    return std::all_of(text.begin(), text.end(), [](char b) { return static_cast<unsigned char>(b) < 0x80; });
}

std::string FoldedBytes(std::string_view text) {
    if (IsAscii(text)) {
        std::string out(text);
        for (char& b : out) b = AsciiLower(b);
        return out;
    }
    return unicode::Encode(unicode::Folded(text));
}

Folded::Folded(std::string_view utf8) : text(unicode::Folded(utf8)), starts(unicode::CharacterStarts(text)) {}

bool Folded::IsWordStart(size_t at) const {
    const auto word = [&](size_t i) { return unicode::IsLetter(text[i]) || unicode::IsNumber(text[i]); };
    if (!starts[at] || !word(at)) return false;
    if (at == 0) return true;
    size_t previous = at - 1;
    while (previous > 0 && !starts[previous]) --previous;  // the previous Character's first scalar
    return !word(previous);
}

bool Folded::MatchesAt(size_t at, const Folded& part) const {
    if (at + part.text.size() > text.size()) return false;
    return std::equal(part.text.begin(), part.text.end(), text.begin() + static_cast<std::ptrdiff_t>(at)) &&
           std::equal(part.starts.begin(), part.starts.end(), starts.begin() + static_cast<std::ptrdiff_t>(at));
}

Query::Query(std::string_view lowered) : folded(lowered) {
    isAscii = std::all_of(folded.text.begin(), folded.text.end(), [](char32_t c) { return c < 0x80; });
    if (isAscii) {
        for (char32_t c : folded.text) ascii += static_cast<char>(c);
    }
    allWordCharacters = true;
    for (size_t i = 0; i < folded.text.size(); ++i) {
        if (folded.starts[i] && !unicode::IsLetter(folded.text[i]) && !unicode::IsNumber(folded.text[i])) allWordCharacters = false;
    }
}

Field::Field(std::string_view raw) : raw_(raw), ascii_(IsAscii(raw)) {}

bool Field::HasPrefix(const Query& q) const {
    if (ascii_) return q.isAscii && AsciiMatchesAt(0, q.ascii) && AsciiBoundary(q.ascii.size());
    return Text().MatchesAt(0, q.folded) && Text().starts[q.folded.text.size()];
}

bool Field::Contains(const Query& q) const {
    if (ascii_) {
        if (!q.isAscii) return false;
        for (size_t at = 0; at + q.ascii.size() <= raw_.size(); ++at) {
            if (AsciiMatchesAt(at, q.ascii) && AsciiBoundary(at) && AsciiBoundary(at + q.ascii.size())) return true;
        }
        return false;
    }
    const Folded& text = Text();
    for (size_t at = 0; at + q.folded.text.size() <= text.text.size(); ++at) {
        if (text.starts[at] && text.MatchesAt(at, q.folded) && text.starts[at + q.folded.text.size()]) return true;
    }
    return false;
}

bool Field::WordHasPrefix(const Query& q) const {
    if (!q.allWordCharacters) return false;
    if (ascii_) {
        if (!q.isAscii) return false;
        for (size_t at = 0; at < raw_.size(); ++at) {
            const bool starts = IsAsciiWordCharacter(raw_[at]) && (at == 0 || !IsAsciiWordCharacter(raw_[at - 1]));
            if (starts && AsciiMatchesAt(at, q.ascii)) return true;
        }
        return false;
    }
    const Folded& text = Text();
    for (size_t at = 0; at + q.folded.text.size() <= text.text.size(); ++at) {
        if (text.IsWordStart(at) && text.MatchesAt(at, q.folded) && text.starts[at + q.folded.text.size()]) return true;
    }
    return false;
}

bool Field::AsciiMatchesAt(size_t at, std::string_view lowered) const {
    if (at + lowered.size() > raw_.size()) return false;
    for (size_t i = 0; i < lowered.size(); ++i) {
        if (AsciiLower(raw_[at + i]) != lowered[i]) return false;
    }
    return true;
}

// Between two Characters: anywhere in ASCII but inside CR LF.
bool Field::AsciiBoundary(size_t at) const { return at == 0 || at >= raw_.size() || !(raw_[at - 1] == '\r' && raw_[at] == '\n'); }

const Folded& Field::Text() const {
    if (!folded_) folded_.emplace(raw_);
    return *folded_;
}

}  // namespace kite::text_match
