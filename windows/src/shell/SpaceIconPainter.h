#pragma once
// Draws a space's SF Symbol or picture icon (core/SpaceIcon.h), for the space bar's cells and the
// page's header: the Mac's SpaceIconImageView (SidebarListRows.swift) for those two kinds. Emoji
// and the dot are drawn by their views, as before. SidebarView owns the one painter and lends it
// to the bar.
//
// A symbol is its glyph in Segoe Fluent Icons (Segoe MDL2 Assets where Fluent isn't installed),
// filled from the glyph's outline in the colour it's given, centred on its ink, at a size made so
// Segoe's briefcase glyph inks as wide as the Mac's semibold briefcase (14.65pt at 12.5): the
// same factor for every symbol, so they keep their sizes relative to each other. The nine neither
// font has, and the briefcase, are Kite's own shapes (core/SymbolShape.h), placed by core's
// PlaceDrawnSymbol, which need neither font.
// A picture is core's PictureFrameAt (the Mac's rounded square), the stored PNG's centred square
// scaled to its pixels; a picture whose file can't be read shows the "photo" symbol. Greying (the
// bar's) is the caller's.
//
// Pictures are read and decoded on a worker thread (nothing that touches the disk runs on the UI
// thread), which posts `message` to the window when they're ready; the caller's TakeResults moves
// them in and the views showing them draw again. What's loaded and what a draw shows is core's
// PictureLoads (tested there); this keeps the pixels and bitmaps. A file over 1 MB or 2048px on a
// side isn't decoded (Kite stores 128px PNGs: SpaceIconImages.pixelSize), and shows the
// placeholder. A --capture run decodes in place, so its one frame has the pictures.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "core/PictureLoads.h"
#include "core/SpaceIcon.h"
#include "core/SymbolShape.h"
#include "shell/Capture.h"

namespace kite {

// A drawn symbol's geometry (core/SymbolShape.h: its layers joined and cut in order, in the shape's
// points), on `d2d`; null when it can't be made.
Microsoft::WRL::ComPtr<ID2D1Geometry> MakeShapeGeometry(ID2D1Factory* d2d, const SymbolShape& shape);

class SpaceIconPainter {
public:
    struct Pictures {
        std::filesystem::path folder;  // the profile's SpaceIcons folder
        UINT message = 0;              // posted to the window when pictures are ready
        bool synchronous = false;      // a --capture run: decode in place
    };
    static std::unique_ptr<SpaceIconPainter> Create(IDWriteFactory* dwrite, HWND window, const Pictures& pictures, std::wstring& error);
    // Tells the worker to stop; it isn't waited for (one read of at most 1 MB may still finish
    // at exit, as Favicons' fetches may).
    ~SpaceIconPainter();
    SpaceIconPainter(const SpaceIconPainter&) = delete;
    SpaceIconPainter& operator=(const SpaceIconPainter&) = delete;

    // Asks for `look`'s picture (if it is one) for an icon size `size` at the window's `scale`,
    // and makes its bitmap for `context`'s device once it's decoded. Call it before the draw that
    // shows it begins; Draw does it too, as a fallback.
    void Prepare(ID2D1DeviceContext* context, const SpaceIconLook& look, float size, float scale);
    // On `message`: moves the decoded pictures in. The names whose drawing changed (a picture
    // arrived, or turned out unreadable), for the views to draw again.
    std::set<std::string> TakeResults();
    // Wakes the worker for what this draw's Prepares asked (the sidebar calls it once its draw,
    // pages and bar, is done).
    void SendRequests();
    // Draws `look` (a symbol or a picture; anything else draws nothing) centred on `centre`, in
    // `context`'s points at the window's `scale`, for an icon size `size` (the Mac's 12.5 in the
    // bar, 15 in the header): a symbol in `symbol`, filled with `brush`. `dark` is the
    // appearance, for the missing picture's placeholder.
    void Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SpaceIconLook& look, D2D1_POINT_2F centre, float size,
              float scale, D2D1_COLOR_F symbol, bool dark);
    // Keeps only the pictures named here (the spaces' icons now).
    void Retain(const std::set<std::string>& names);
    // Drops what belongs to the device: the pictures' bitmaps (their decoded pixels stay), and
    // the glyphs' outlines and drawn shapes (their factory's). The views call it from their
    // ReleaseGpu.
    void ReleaseDevice();

    struct Shared;  // the worker's queue (SpaceIconPainter.cpp)

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
    // A picture at one size (core's PictureLoads says what shows).
    struct Sized {
        Pixels pixels;  // decoded, premultiplied BGRA
        Microsoft::WRL::ComPtr<ID2D1Bitmap> bitmap;  // the device's, made from `pixels`
        Microsoft::WRL::ComPtr<ID2D1BitmapBrush> brush;
    };
    using SizedKey = std::pair<std::string, UINT>;  // name, pixels on a side

    // Outlines are their factory's: a context from another (a new device) drops them.
    void UseFactoryOf(ID2D1DeviceContext* context);
    // The font that has `glyph` (Fluent first) and its outline; null when neither has it.
    std::pair<Face*, const Outline*> OutlineOf(const SymbolGlyph& glyph);
    const Outline* OutlineIn(Face& face, char16_t codePoint);
    void DrawSymbol(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, const SymbolGlyph& glyph, D2D1_POINT_2F centre, float size,
                    D2D1_COLOR_F color);
    // A drawn symbol's geometry (its layers joined and cut in order), made once per factory;
    // null when it can't be made (tried again with the next factory).
    ID2D1Geometry* ShapeGeometry(const SymbolShape& shape);
    // A decode's answer for `name`: `pixels` for each of `sides`, or none when it can't be read.
    // True when what shows changed.
    bool Arrived(const std::string& name, const std::vector<UINT>& sides, std::vector<Pixels> pixels);
    static double Now();
    void Request(const std::string& name, UINT side);

    Microsoft::WRL::ComPtr<ID2D1Factory> d2d_;
    std::optional<Face> fluent_, mdl2_;
    std::map<const SymbolShape*, Microsoft::WRL::ComPtr<ID2D1Geometry>> shapes_;  // null: couldn't be made
    std::shared_ptr<Shared> shared_;
    bool synchronous_ = false;
    bool requested_ = false;  // jobs queued since the last SendRequests
    Microsoft::WRL::ComPtr<IUnknown> captureWic_;  // a capture's WIC factory (IWICImagingFactory)
    bool captureCom_ = false;
    PictureLoads loads_;
    std::map<SizedKey, Sized> sized_;
};

}  // namespace kite
