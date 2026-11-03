#pragma once
// The sidebar's bottom bar, drawn to ArcMetrics.Sidebar: Arc's Library button at the leading end,
// the + button at the trailing end, and between them a cell per space (the Mac's SpaceBarView and
// SpaceCellView, SidebarSpaceBar.swift). Core lays it out (core/SpaceBar.h); SidebarView owns it,
// gives it the session and the pointer, and puts it in the sidebar.
//
// It's DirectComposition visuals in the sidebar's chrome: the bar's surface (the end buttons,
// drawn only for a new width, scale or appearance), then, clipped to the strip's viewport, the
// hovered cell's backing (its own small visual that moves) and each cell's icon (an emoji, or a
// symbol or a picture as SpaceIconPainter draws them) twice, greyed and in colour, or its dot,
// each in its own small surface with an opacity. A space switch's slide relights the cells as the pages slide (SpaceSwipe::Highlight), as DirectComposition animations
// of those opacities on the same spring as the strip's, so no frame of it draws; hovering and
// scrolling move visuals and draw nothing. What a cell shows and what a press does are core's
// (core/SpaceBar.h). Not yet: the Library and the + menu (the buttons draw, and take no clicks),
// dragging a cell to reorder, the menu and the tip.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/SpaceBar.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/SpaceIconPainter.h"

namespace kite {

class SpaceBarView {
public:
    // `painter` (SidebarView's, which outlives the bar) draws its symbols and pictures; the
    // sidebar releases its device objects.
    static std::unique_ptr<SpaceBarView> Create(IDWriteFactory* dwrite, SpaceIconPainter* painter, std::wstring& error);
    ~SpaceBarView();
    SpaceBarView(const SpaceBarView&) = delete;
    SpaceBarView& operator=(const SpaceBarView&) = delete;

    // The compositor whose chrome it draws in (under `parent`); null drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    bool DeviceLost() const { return deviceLost_; }

    // What it shows: the spaces' cells at rest, in the selected space's appearance.
    void Update(std::vector<SpaceCell> cells, bool dark);
    // The sidebar's width (points) and the window's scale.
    void Layout(float width, UINT dpi);
    // The cells' light follows the pages as they settle from offset `from` to `to` (points), on
    // the compositor from the next commit (`segments` and `duration` are the strip's, core's
    // SettleSegments), with the pages `built` around `selected`, `pageWidth` apart.
    void Slide(const std::vector<CubicSegment>& segments, double duration, double from, double to, double pageWidth,
               const std::vector<size_t>& built, size_t selected);
    // Pictures arrived: the cells showing one draw again.
    void InvalidatePictures();
    // At rest: each cell as it is (the slide's end, or a slide cut short), from the next draw.
    void Land();
    // Scrolls the strip by `by` points (positive shows later spaces) when the spaces don't fit.
    // True when it moved.
    bool Scroll(float by);
    // The pointer's cell, by space id; none for none. As the Mac's tracking area, the backing
    // shows when the pointer comes onto a cell that isn't the space you're in, and stays until it
    // leaves.
    void SetHover(const std::optional<std::string>& spaceID);

    // What it shows and where, in the bar's points (core's, for hits and presses).
    const SpaceBarLayout& Geometry() const { return layout_; }
    const std::vector<SpaceCell>& Cells() const { return cells_; }
    // The space whose cell is at (x, y), in the bar's points.
    std::optional<std::string> SpaceAt(float x, float y) const;

    bool NeedsDraw() const;
    // Draws what changed for a window `clientHeight` px tall (the bar sits at its bottom, from
    // SpaceBarTop); with `readBack`, always, also composing the bar at rest (the sidebar's
    // width, from the bar's top px to the window's bottom) there. The caller commits. Empty on
    // success.
    std::wstring Draw(UINT clientHeight, Pixels* readBack = nullptr);

private:
    SpaceBarView() = default;

    // One layer of a cell (the greyed icon, the coloured one, or the dot): its visual, surface
    // and opacity.
    struct Layer {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;
        Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface;
        Microsoft::WRL::ComPtr<IDCompositionEffectGroup> effect;
        Pixels pixels;  // its last draw, read back, for a capture
    };
    struct CellGpu {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;  // at the cell's place in the strip
        Layer grey, lit;  // a dot is `lit` alone
        bool dirty = true;
    };

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    // `fresh`: a layer was made, so it needs its opacity.
    std::wstring DrawCell(size_t index, CellGpu& gpu, bool readBack, bool& fresh);
    std::wstring DrawLayer(Layer& layer, UINT width, UINT height, const Compositor::Content& content, bool readBack, HRESULT& hr,
                           bool& fresh);
    std::wstring DrawBacking(bool readBack);
    void DrawBar(ID2D1DeviceContext* context);
    // The cell's icon in the middle of the cell, into `context`: an emoji centred on its ink, a
    // symbol or a picture as SpaceIconPainter draws it (`greyed`: a symbol's grey tint).
    void DrawIcon(ID2D1DeviceContext* context, const SpaceCell& cell, bool greyed);
    void DrawDot(ID2D1DeviceContext* context);
    // The emoji or picture recorded for the greyed layer, before that layer's draw begins.
    Microsoft::WRL::ComPtr<ID2D1CommandList> RecordIcon(const SpaceCell& cell, HRESULT& hr);
    void PlaceCells();
    void ShowBacking();
    // The opacities each layer shows at rest, or along the slide.
    void ApplyOpacities();
    D2D1_COLOR_F Primary(float alpha) const;
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;

    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> emojiFormat_;
    SpaceIconPainter* painter_ = nullptr;

    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1Effect> saturation_;  // greys an emoji or a picture (the Mac's CIColorControls)
    // The Library button's archive box (lid, box, slot) and the + button, centred on 0,0.
    Microsoft::WRL::ComPtr<ID2D1PathGeometry> box_;
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle> roundCaps_, flatCaps_;
    // The bar (its surface: the buttons), then the cells' clip, the backing and the cells.
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_, cellsClip_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    LONG top_ = -1;  // px, the bar's place in the window
    Pixels barPixels_;
    Layer backing_;  // its visual sits in cellsClip_ while shown
    bool backingShown_ = false, backingDirty_ = true;
    std::vector<CellGpu> cellGpu_;
    bool deviceLost_ = false;

    // State.
    std::vector<SpaceCell> cells_;
    bool dark_ = true;
    float width_ = 240;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    SpaceBarLayout layout_;
    std::optional<std::string> hover_;
    std::optional<std::string> backingFor_;  // the hovered cell, when it wasn't selected as the pointer came
    bool dirty_ = true;   // the bar's surface
    bool placed_ = false;  // the cells' and the backing's visuals sit where the layout has them
    struct Relight {
        std::vector<CubicSegment> segments;
        double duration, from, to, pageWidth;
        std::vector<size_t> built;
        size_t selected;
    };
    std::optional<Relight> slide_;
    bool opacitiesApplied_ = false;
};

}  // namespace kite
