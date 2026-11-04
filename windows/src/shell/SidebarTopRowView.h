#pragma once
// The sidebar's top row, drawn to ArcMetrics.Sidebar: the sidebar toggle, then back, forward and
// reload (the X while the page loads) at the far end (the Mac's SidebarHeaderView top row and its
// SymbolButtons, SidebarHeader.swift and SidebarKit.swift). Core lays it out and says what each
// button shows (core/SidebarTopRow.h); SidebarView owns it, gives it the session and the shown
// page's status, and takes its presses.
//
// Each button is its own small DirectComposition visual in the sidebar (its symbol in labelColor
// in a surface the button's size), faded by an effect group to SymbolButton's 0.6, or 0.125
// disabled: a button turning on or off changes an opacity and draws nothing, and only a new symbol
// (reload's X), appearance, width or scale draws that button's surface again. As on the Mac the
// buttons show no hover or press of their own; hovering one shows its tooltip, Windows' own
// (a comctl32 tooltip on the window, its tools the buttons' rectangles), after the system's delay.
// sidebar.left is Kite's own geometry (core's SidebarToggleShape); the others are Segoe Fluent
// Icons' (Segoe MDL2 Assets' on Windows 10) stand-ins, scaled and placed to the Mac's ink.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/SidebarTopRow.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"

namespace kite {

class SidebarTopRowView {
public:
    // `tooltips` false (a capture) makes no tooltip window.
    static std::unique_ptr<SidebarTopRowView> Create(HWND window, IDWriteFactory* dwrite, bool tooltips, std::wstring& error);
    ~SidebarTopRowView();
    SidebarTopRowView(const SidebarTopRowView&) = delete;
    SidebarTopRowView& operator=(const SidebarTopRowView&) = delete;

    // The compositor whose chrome it draws in, its visuals under `parent` (the sidebar's); null
    // drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    bool DeviceLost() const { return deviceLost_; }

    // What it shows, in the selected space's appearance.
    void Update(const TopRowModel& model, bool dark);
    // The sidebar's width (points) and the window's scale.
    void Layout(float width, UINT dpi);
    // Whether the buttons' tooltips come (the sidebar on screen, at rest where it shows).
    void SetTooltipsActive(bool active);
    const std::vector<TopRowItem>& Items() const { return items_; }

    bool NeedsDraw() const;
    // Draws the buttons that changed; with `readBack`, all of them, kept for ComposeInto. The
    // caller commits. Empty on success.
    std::wstring Draw(bool readBack = false);
    // After a read-back draw: the buttons over `sidebar` (the sidebar's pixels from its top-left),
    // at their opacities, as DirectComposition shows them.
    void ComposeInto(Pixels& sidebar) const;
    // How many button surfaces have drawn (the smoke test checks a hover draws none).
    size_t SurfaceDraws() const { return surfaceDraws_; }

private:
    SidebarTopRowView(HWND window) : window_(window) {}

    struct ButtonGpu {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;
        Microsoft::WRL::ComPtr<IDCompositionEffectGroup> effect;
        Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface;
        std::string symbol;  // what its surface shows
        UINT width = 0, height = 0;
        POINT at{};          // its place in the sidebar, px
        bool dirty = true;
        Pixels pixels;  // its last read-back draw
    };
    void ReleaseGpu();
    std::wstring DrawButton(const TopRowItem& item, ButtonGpu& gpu, bool readBack);
    // The symbol centred on `centre` (the button's centre, in the surface's points).
    void DrawSymbol(ID2D1DeviceContext* context, const std::string& symbol, D2D1_POINT_2F centre);
    void Place();
    void UpdateTooltips();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    HWND window_;
    HWND tooltip_ = nullptr;
    bool tooltipsActive_ = true;
    std::vector<UINT_PTR> tools_;  // the tooltip's tools, by button

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> iconFormat_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1Geometry> toggleShape_;
    std::map<TopRowButton, ButtonGpu> gpu_;
    bool deviceLost_ = false;
    size_t surfaceDraws_ = 0;

    std::vector<TopRowItem> items_;
    TopRowModel model_;
    bool dark_ = true;
    float width_ = 240;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool placed_ = false;
};

}  // namespace kite
