#pragma once
// Kite's text in DirectWrite: the one place a text format is made. Views ask for the Mac's system
// font at one of its weights and a size in DIPs (the Mac's points), and get Segoe UI Variable set
// on its weight and optical-size axes as core/TextWeight maps them (Windows 11; bold is Segoe UI
// Black), or Segoe UI at a named weight where there are no axes (Windows 10). Symbol and emoji fonts come from here too,
// untouched by the mapping: they stand in for SF Symbols and Apple Color Emoji, not SF Pro.
//
// Characters outside what the mapping was measured on (Latin, Greek, Cyrillic and their marks,
// punctuation and symbols) fall back to other fonts at the Mac's own weight (400, 500, 600 or 700)
// through each format's IDWriteFontFallback, not at the axis value or Windows 10 weight the Latin
// text takes: DirectWrite would otherwise pick Yu Gothic UI Semibold for a regular label.
//
// A format from here carries axis values (IDWriteTextFormat3) and that fallback, so a copy of one
// is made with CopyTextFormat, never from its family name and weight alone, which would drop them.

#include <windows.h>  // first: the DirectX headers need its types

#include <dwrite.h>
#include <wrl/client.h>

#include "core/TextWeight.h"

namespace kite::system_font {

enum class Face {
    Variable,  // Segoe UI Variable, with wght and opsz axes (Windows 11)
    Static,    // Segoe UI's named weights (Windows 10)
};

// The face this process draws Kite's text in, decided once from the system's fonts.
Face Current();
// A capture's --static-font: Windows 10's face on any machine. Only before the first format.
void UseStaticForTesting();

// The Mac's system font at `weight` and `size` DIPs.
HRESULT CreateTextFormat(IDWriteFactory* dwrite, MacWeight weight, float size, Microsoft::WRL::ComPtr<IDWriteTextFormat>& out);
// `format`'s family, weight, style, stretch and axis values at `size` (a field's own copy of
// its row's format, without the row's trimming or alignment).
HRESULT CopyTextFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, float size, Microsoft::WRL::ComPtr<IDWriteTextFormat>& out);
// The face's family as GDI names it, and the named weight nearest what `weight` at `size` draws,
// for a LOGFONT (an IME's composition window).
const wchar_t* GdiFaceName();
LONG GdiWeight(MacWeight weight, float size);
// The cap height in DIPs of what `weight` at `size` draws with, axis values applied.
float CapHeight(IDWriteFactory* dwrite, MacWeight weight, float size);

enum class IconFont {
    Symbols,  // Segoe Fluent Icons (Windows 11), else Segoe MDL2 Assets
    Emoji,    // Segoe UI Emoji
};
const wchar_t* IconFamily(IconFont font);
bool HasFluentIcons();
HRESULT CreateIconFormat(IDWriteFactory* dwrite, IconFont font, DWRITE_FONT_WEIGHT weight, float size,
                         Microsoft::WRL::ComPtr<IDWriteTextFormat>& out);

}  // namespace kite::system_font
