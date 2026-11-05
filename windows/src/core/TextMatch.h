#pragma once
// Matching what's typed against a page's texts the way Swift's String does: by Character
// (grapheme cluster), lowercased, compared by canonical equivalence. Shared by the command
// bar's tab search (TabSearch.swift) and history's (History.search); moved out of
// CommandBar.cpp, where W7a wrote it, so both rank with the same code.

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kite::text_match {

// Swift's trimmingCharacters(in: .whitespacesAndNewlines).lowercased().
std::string TrimmedLowercase(std::string_view text);
// Every occurrence of `from` replaced, as Foundation's replacingOccurrences(of:with:).
std::string ReplaceAll(std::string text, std::string_view from, std::string_view to);
bool IsAscii(std::string_view text);

// Text folded for comparing (lowercased, decomposed) with where its Characters start:
// comparing code points and starts compares Characters the way Swift does.
struct Folded {
    std::u32string text;
    std::vector<bool> starts;

    explicit Folded(std::string_view utf8);
    bool IsWordStart(size_t at) const;
    // `part`'s Characters are this text's, from `at`.
    bool MatchesAt(size_t at, const Folded& part) const;
};

// What's typed, lowercased and decomposed, as ASCII bytes or as Characters.
struct Query {
    Folded folded;
    std::string ascii;       // the same, when it's all ASCII
    bool isAscii;
    bool allWordCharacters;  // every Character a letter or number: it can start a word

    // `lowered`: already trimmed and lowercased.
    explicit Query(std::string_view lowered);
};

// One text to match (a title, host or address). Most are ASCII, which lowercasing,
// decomposition and grapheme breaking leave as they are (but for CR LF, one Character):
// those are compared in place, byte by byte, with nothing allocated. Anything else is
// folded once and compared by Characters. Holds `raw`, which must outlive it.
class Field {
public:
    explicit Field(std::string_view raw);

    bool HasPrefix(const Query& q) const;
    bool Contains(const Query& q) const;
    // Some word of the field (a run of letters and numbers) starts with what's typed.
    bool WordHasPrefix(const Query& q) const;

private:
    bool AsciiMatchesAt(size_t at, std::string_view lowered) const;
    bool AsciiBoundary(size_t at) const;
    const Folded& Text() const;

    std::string_view raw_;
    bool ascii_;
    mutable std::optional<Folded> folded_;
};

// `text` lowercased and decomposed, back in UTF-8: a Field matches a Query only if the query's
// FoldedBytes occur in the field's, so a byte search over these finds every candidate (and a
// few more, which the Field then turns down).
std::string FoldedBytes(std::string_view text);

}  // namespace kite::text_match
