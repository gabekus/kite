#pragma once
// Draws a space's SF Symbol or picture icon (core/SpaceIcon.h), for the space bar's cells and the
// page's header: the Mac's SpaceIconImageView (SidebarListRows.swift) for those two kinds. Emoji
// and the dot are drawn by their views, as before.
//
// A symbol is its glyph in Segoe Fluent Icons (Segoe MDL2 Assets where Fluent isn't installed),
// filled from the glyph's outline in the colour it's given, centred on its ink, at a size made so
// the briefcase inks as wide as the Mac's semibold one (15pt at 12.5, measured in its 2x
// capture): the same factor for every symbol, so they keep their sizes relative to each other.
// A picture is the Mac's rounded square: round(size x 1.2) on a side, corners 22% of that, the
// stored PNG's centred square scaled to its pixels; a picture whose file is gone shows the "photo"
// symbol at 0.8 of the size in secondaryLabelColor. Greying (the bar's) is the caller's.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "core/SpaceIcon.h"

namespace kite {

class SpaceIconPainter {
public:
    // `pictures` is the profile's SpaceIcons folder.
    static std::unique_ptr<SpaceIconPainter> Create(IDWriteFactory* dwrite, std::filesystem::path pictures, std::wstring& error);
    SpaceIconPainter(const SpaceIconPainter&) = delete;
    SpaceIconPainter& operator=(const SpaceIconPainter&) = delete;

    // Draws `look` (a symbol or a picture; anything else draws nothing) centred on `centre`, in
    // `context`'s points at the window's `scale`, for an icon size `size` (the Mac's 12.5 in the
    // bar, 15 in the header): a symbol in `symbol`, filled with `brush`. `dark` is the
    // appearance, for the missing picture's placeholder.
    void Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre, float size,
              float scale, D2D1_COLOR_F symbol, bool dark);
    // Drops what belongs to the device: the pictures' bitmaps, and the glyphs' outlines (their
    // factory's).
    void ReleaseDevice();

private:
    SpaceIconPainter() = default;

    // A glyph's outline at a 1pt em, and its ink's bounds.
    struct Outline {
        Microsoft::WRL::ComPtr<ID2D1PathGeometry> geometry;
        D2D1_RECT_F ink{};
    };
    struct Face {
        Microsoft::WRL::ComPtr<IDWriteFontFace> face;
        float emPerPoint = 1;  // font size per point of the Mac's symbol size (the briefcase's calibration)
        bool calibrated = false;
        std::map<char16_t, std::optional<Outline>> outlines;
    };
    // The font that has `glyph` (Fluent first) and its outline; null when neither has it.
    std::pair<Face*, const Outline*> OutlineOf(const SymbolGlyph& glyph);
    const Outline* OutlineIn(Face& face, char16_t codePoint);
    void DrawSymbol(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SymbolGlyph& glyph, D2D1_POINT_2F centre, float size,
                    D2D1_COLOR_F color);
    // The picture at `pixels` on a side, decoded and scaled for `context`'s device; null when
    // its file can't be read.
    ID2D1Bitmap* Picture(ID2D1DeviceContext* context, const std::string& name, UINT pixels, float scale);

    Microsoft::WRL::ComPtr<ID2D1Factory> d2d_;  // the outlines' factory: the contexts'
    std::filesystem::path folder_;
    std::optional<Face> fluent_, mdl2_;
    std::map<std::pair<std::string, UINT>, Microsoft::WRL::ComPtr<ID2D1Bitmap>> pictures_;
};

}  // namespace kite
