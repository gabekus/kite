#pragma once
// Draws a space's SF Symbol or picture icon (core/SpaceIcon.h), for the space bar's cells and the
// page's header: the Mac's SpaceIconImageView (SidebarListRows.swift) for those two kinds. Emoji
// and the dot are drawn by their views, as before.
//
// A symbol is its glyph in Segoe Fluent Icons (Segoe MDL2 Assets where Fluent isn't installed),
// filled from the glyph's outline in the colour it's given, centred on its ink, at a size made so
// the briefcase inks as wide as the Mac's semibold one (15pt at 12.5, measured in its 2x
// capture): the same factor for every symbol, so they keep their sizes relative to each other.
// A picture is core's PictureFrameAt (the Mac's rounded square), the stored PNG's centred square
// scaled to its pixels; a picture whose file can't be read shows the "photo" symbol. Greying (the
// bar's) is the caller's.
//
// Pictures are decoded on the UI thread, by Prepare, outside any surface's draw: Kite stores them
// as 128px PNGs (SpaceIconImages.pixelSize), so that's a fraction of a millisecond, once per
// picture, size and device. Each view keeps one painter, used at one icon size.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>

#include "core/SpaceIcon.h"

namespace kite {

class SpaceIconPainter {
public:
    // `pictures` is the profile's SpaceIcons folder.
    static std::unique_ptr<SpaceIconPainter> Create(IDWriteFactory* dwrite, std::filesystem::path pictures, std::wstring& error);
    ~SpaceIconPainter();
    SpaceIconPainter(const SpaceIconPainter&) = delete;
    SpaceIconPainter& operator=(const SpaceIconPainter&) = delete;

    // Decodes `look`'s picture (if it is one) for an icon size `size` at the window's `scale`,
    // for `context`'s device, unless it's already there. Call it before the draw that shows it
    // begins; Draw does it too, as a fallback. A file that can't be read is remembered as such.
    void Prepare(ID2D1DeviceContext* context, const SpaceIconLook& look, float size, float scale);
    // Draws `look` (a symbol or a picture; anything else draws nothing) centred on `centre`, in
    // `context`'s points at the window's `scale`, for an icon size `size` (the Mac's 12.5 in the
    // bar, 15 in the header): a symbol in `symbol`, filled with `brush`. `dark` is the
    // appearance, for the missing picture's placeholder.
    void Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre, float size,
              float scale, D2D1_COLOR_F symbol, bool dark);
    // Keeps only the pictures named here (the icons shown now).
    void Retain(const std::set<std::string>& names);
    // Drops what belongs to the device: the pictures' bitmaps, and the glyphs' outlines (their
    // factory's).
    void ReleaseDevice();

private:
    SpaceIconPainter() = default;

    // A glyph's outline at a kOutlineEm em, and its ink's bounds.
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
    // A picture at one size: no bitmap when its file can't be read.
    struct Picture {
        UINT pixels = 0;
        Microsoft::WRL::ComPtr<ID2D1Bitmap> bitmap;
        Microsoft::WRL::ComPtr<ID2D1BitmapBrush> brush;
    };

    // Outlines and bitmaps are their factory's: a context from another (a new device) drops them.
    void UseFactoryOf(ID2D1DeviceContext* context);
    // The font that has `glyph` (Fluent first) and its outline; null when neither has it.
    std::pair<Face*, const Outline*> OutlineOf(const SymbolGlyph& glyph);
    const Outline* OutlineIn(Face& face, char16_t codePoint);
    void DrawSymbol(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SymbolGlyph& glyph, D2D1_POINT_2F centre, float size,
                    D2D1_COLOR_F color);
    // The file `name` decoded, its centred square scaled to `pixels` on a side; null when it
    // can't be read.
    Microsoft::WRL::ComPtr<ID2D1Bitmap> Decode(ID2D1DeviceContext* context, const std::string& name, UINT pixels, float scale);

    Microsoft::WRL::ComPtr<ID2D1Factory> d2d_;
    Microsoft::WRL::ComPtr<IWICImagingFactory> wic_;
    bool comInitialized_ = false;
    std::filesystem::path folder_;  // absolute, with the \\?\ prefix
    std::optional<Face> fluent_, mdl2_;
    std::map<std::string, Picture> pictures_;
};

}  // namespace kite
