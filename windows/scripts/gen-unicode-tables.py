#!/usr/bin/env python3
"""Writes src/core/UnicodeTables.inc: code point ranges for the Unicode properties Swift's
Character uses, so URL input classifies text the way the Mac does without ICU or any other
library:

- Alphabetic (DerivedCoreProperties): Character.isLetter is its first scalar's isAlphabetic.
- Numeric_Type != None (DerivedNumericType): Character.isNumber is its first scalar's
  numericType != nil.
- Grapheme_Cluster_Break values (UAX #29), so text splits into Characters (extended
  grapheme clusters) like Swift's String.
- Extended_Pictographic and Indic_Conjunct_Break, for the grapheme rules GB9c and GB11.
- Canonical decompositions (recursive, Hangul syllables left to code) and
  Canonical_Combining_Class, so text compares by canonical equivalence (NFD) as Swift's
  Character does.
- Lowercase_Mapping (UnicodeData plus SpecialCasing's unconditional mappings), so
  lowercasing matches Swift's String.lowercased(), which maps scalar by scalar. The one
  mapping to more than one scalar (U+0130 to "i" + U+0307) is left to Unicode.cpp.

    python3 -m venv /tmp/ucd && /tmp/ucd/bin/pip install regex==2023.12.25
    /tmp/ucd/bin/python windows/scripts/gen-unicode-tables.py

regex 2023.12.25 carries Unicode 15.1.0, the same as Python 3.12's unicodedata; the script
refuses to run when the two disagree, and records the version in the output.
"""
import pathlib
import sys
import unicodedata

import regex

UNICODE_VERSION = "15.1.0"


def ranges(pattern):
    matcher = regex.compile(pattern)
    out, start, prev = [], None, None
    for cp in range(sys.maxunicode + 1):
        if 0xD800 <= cp <= 0xDFFF:
            hit = False  # surrogates never come out of UTF-8 decoding
        else:
            hit = matcher.fullmatch(chr(cp)) is not None
        if hit:
            if start is None:
                start = cp
            prev = cp
        elif start is not None:
            out.append((start, prev))
            start = None
    if start is not None:
        out.append((start, prev))
    return out


def table(name, rs):
    lines = [f"inline constexpr CodePointRange {name}[] = {{"]
    row = []
    for a, b in rs:
        row.append(f"{{0x{a:X}, 0x{b:X}}}")
        if len(row) == 6:
            lines.append("    " + ", ".join(row) + ",")
            row = []
    if row:
        lines.append("    " + ", ".join(row) + ",")
    lines.append("};")
    return "\n".join(lines)


def lowercase_table():
    lines = ["inline constexpr LowercaseMapping kLowercase[] = {"]
    row = []
    for cp in range(sys.maxunicode + 1):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        lower = chr(cp).lower()  # one scalar alone: no Final_Sigma context, as in Swift
        if lower == chr(cp):
            continue
        if len(lower) != 1:
            if cp != 0x130:
                sys.exit(f"U+{cp:04X} lowercases to {len(lower)} scalars; Unicode.cpp handles only U+0130")
            continue
        row.append(f"{{0x{cp:X}, 0x{ord(lower):X}}}")
        if len(row) == 6:
            lines.append("    " + ", ".join(row) + ",")
            row = []
    if row:
        lines.append("    " + ", ".join(row) + ",")
    lines.append("};")
    return "\n".join(lines)


def valued_ranges(name, values):
    """Runs of consecutive code points with the same non-zero value: {first, last, value}."""
    lines = [f"inline constexpr ValuedRange {name}[] = {{"]
    row, start, prev, current = [], None, None, None
    def flush():
        if start is not None:
            row.append(f"{{0x{start:X}, 0x{prev:X}, {current}}}")
    for cp in range(sys.maxunicode + 2):
        value = values(cp) if cp <= sys.maxunicode and not 0xD800 <= cp <= 0xDFFF else 0
        if start is not None and (value != current or cp != prev + 1):
            flush()
            start = None
            if len(row) >= 6:
                lines.append("    " + ", ".join(row) + ",")
                row = []
        if value and start is None:
            start, current = cp, value
        if value:
            prev = cp
    if row:
        lines.append("    " + ", ".join(row) + ",")
    lines.append("};")
    return "\n".join(lines)


def decomposition_tables():
    """kDecompositions: {code point, offset, length} into kDecompositionPool, the full
    canonical decomposition (NFD of the one scalar) wherever it differs from the scalar."""
    entries, pool = [], []
    for cp in range(sys.maxunicode + 1):
        if 0xD800 <= cp <= 0xDFFF or 0xAC00 <= cp <= 0xD7A3:
            continue  # Hangul syllables decompose arithmetically (Unicode.cpp)
        nfd = unicodedata.normalize("NFD", chr(cp))
        if nfd == chr(cp):
            continue
        entries.append((cp, len(pool), len(nfd)))
        pool.extend(ord(c) for c in nfd)
    lines = ["inline constexpr Decomposition kDecompositions[] = {"]
    for i in range(0, len(entries), 6):
        lines.append("    " + ", ".join(f"{{0x{a:X}, {b}, {c}}}" for a, b, c in entries[i:i + 6]) + ",")
    lines.append("};")
    lines.append("")
    lines.append("inline constexpr char32_t kDecompositionPool[] = {")
    for i in range(0, len(pool), 10):
        lines.append("    " + ", ".join(f"0x{c:X}" for c in pool[i:i + 10]) + ",")
    lines.append("};")
    return "\n".join(lines)


def main():
    if unicodedata.unidata_version != UNICODE_VERSION:
        sys.exit(f"Python's unicodedata is {unicodedata.unidata_version}; this script expects {UNICODE_VERSION}")
    # U+2FFFF..: a 15.1 addition (CJK Ext. I, U+2EBF0) must be there, a 16.0 one (U+1C89) not.
    if not regex.fullmatch(r"\p{Alphabetic}", "\U0002EBF0") or regex.fullmatch(r"\p{Alphabetic}", "Ᲊ"):
        sys.exit(f"the regex module isn't Unicode {UNICODE_VERSION}: pip install regex==2023.12.25")
    out = pathlib.Path(__file__).resolve().parent.parent / "src" / "core" / "UnicodeTables.inc"
    gcb = lambda value: ranges(rf"\p{{Grapheme_Cluster_Break={value}}}")
    parts = [
        f"// Generated by windows/scripts/gen-unicode-tables.py from Unicode {UNICODE_VERSION}. Don't edit.",
        "// Included by core/Unicode.cpp inside namespace kite::unicode.",
        "",
        table("kAlphabetic", ranges(r"\p{Alphabetic}")),
        "",
        table("kNumeric", ranges(r"[\p{Numeric_Type=Decimal}\p{Numeric_Type=Digit}\p{Numeric_Type=Numeric}]")),
        "",
        table("kGcbControl", gcb("Control")),
        "",
        table("kGcbExtend", gcb("Extend")),
        "",
        table("kGcbSpacingMark", gcb("SpacingMark")),
        "",
        table("kGcbPrepend", gcb("Prepend")),
        "",
        table("kGcbL", gcb("L")),
        "",
        table("kGcbV", gcb("V")),
        "",
        table("kGcbT", gcb("T")),
        "",
        table("kExtendedPictographic", ranges(r"\p{Extended_Pictographic}")),
        "",
        table("kGcbRegionalIndicator", gcb("Regional_Indicator")),
        "",
        table("kInCBConsonant", ranges(r"\p{InCB=Consonant}")),
        "",
        table("kInCBExtend", ranges(r"\p{InCB=Extend}")),
        "",
        table("kInCBLinker", ranges(r"\p{InCB=Linker}")),
        "",
        valued_ranges("kCombiningClass", lambda cp: unicodedata.combining(chr(cp))),
        "",
        decomposition_tables(),
        "",
        lowercase_table(),
        "",
    ]
    out.write_text("\n".join(parts))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
