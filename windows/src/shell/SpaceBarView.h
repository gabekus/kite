#pragma once
// The sidebar's bottom bar, drawn to ArcMetrics.Sidebar: Arc's Library button at the leading end,
// the + button at the trailing end, and between them a cell per space (the Mac's SpaceBarView and
// SpaceCellView, SidebarSpaceBar.swift). Core lays it out (core/SpaceBar.h); SidebarView owns it,
// gives it the session and the pointer, and puts it in the sidebar.
//
// It's DirectComposition visuals in the sidebar's chrome: the bar's surface (the end buttons and
// a hovered cell's backing), then each cell's icon twice, greyed and in colour, or its dot, each
// in its own small surface with an opacity. A space switch's slide relights the cells as the pages
// slide (SpaceSwipe::Highlight), as DirectComposition animations of those opacities on the same
// spring as the strip's, so no frame of it draws. Not yet: the Library and the + menu (the
// buttons draw, and take no clicks), dragging a cell to reorder, the menu and the tip.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/SpaceBar.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"

namespace kite {

class SpaceBarView {
public:
    static std::unique_ptr<SpaceBarView> Create(IDWriteFactory* dwrite, std::wstring& error);
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
    // The cells' light follows the pages as they settle from `from` points to rest, on the
    // compositor from the next commit (`segments` and `duration` are the strip's, core's
    // SettleSegments), with the pages `built` around `selected`, `pageWidth` apart.
    void Slide(const std::vector<CubicSegment>& segments, double duration, double from, double pageWidth,
               const std::vector<size_t>& built, size_t selected);
    // At rest: each cell as it is (the slide's end, or a slide cut short).
    void Land();
    // Scrolls the strip by `by` points (positive shows later spaces) when the spaces don't fit.
    // True when it moved.
    bool Scroll(float by);
    // The pointer's cell (its backing), by space id; none for none.
    void SetHover(const std::optional<std::string>& spaceID);

    // Where it sits: its top in the sidebar, in points, for a window `height` points tall.
    static float Top(float height) { return height - space_bar_metrics::kHeight; }
    // The space whose cell is at (x, y), in the bar's points.
    std::optional<std::string> SpaceAt(float x, float y) const;
    // Whether (x, y) in the bar's points is inside space `id`'s cell.
    bool InCell(const std::string& id, float x, float y) const;

    bool NeedsDraw() const;
    // Draws what changed for a window `clientHeight` px tall (the bar sits at its bottom); with
    // `readBack`, always, also composing the bar at rest (the sidebar's width, the bar's height
    // in px) there. The caller commits. Empty on success.
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
        UINT width = 0, height = 0;
        bool dirty = true;
    };
    // How a cell draws: a dot when it has no icon this view can draw.
    static bool ShowsDot(const SpaceCell& cell);

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    std::wstring DrawCell(size_t index, CellGpu& gpu, bool readBack);
    std::wstring DrawLayer(Layer& layer, UINT width, UINT height, const Compositor::Content& content, bool readBack, HRESULT& hr);
    void DrawBar(ID2D1DeviceContext* context);
    void DrawIcon(ID2D1DeviceContext* context, const SpaceCell& cell, float dx, bool greyed);
    void PlaceCells();
    // The opacities each layer shows at rest, or along the slide.
    void ApplyOpacities();
    D2D1_COLOR_F Primary(float alpha) const;
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;

    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> emojiFormat_, iconFormat_;

    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    // The bar (its surface: the buttons and the backing), then the cells' clip and the cells.
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_, cellsClip_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    LONG top_ = -1;  // px, the bar's place in the window
    Pixels barPixels_;
    std::vector<CellGpu> cellGpu_;
    bool deviceLost_ = false;

    // State.
    std::vector<SpaceCell> cells_;
    bool dark_ = true;
    float width_ = 240;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    SpaceBarLayout layout_;
    std::optional<std::string> hover_;
    bool dirty_ = true;   // the bar's surface
    bool placed_ = false;  // the cells' visuals sit where the layout has them
    struct Relight {
        std::vector<CubicSegment> segments;
        double duration, from, pageWidth;
        std::vector<size_t> built;
        size_t selected;
    };
    std::optional<Relight> slide_;
    bool opacitiesApplied_ = false;
};

}  // namespace kite
