#pragma once
// The sidebar's top row, drawn to ArcMetrics.Sidebar: the sidebar toggle, then back, forward and
// reload (the X while the page loads) at the far end (the Mac's SidebarHeaderView top row and its
// SymbolButtons, SidebarHeader.swift and SidebarKit.swift). Core lays it out and says what each
// button shows (core/SidebarTopRow.h); SidebarView owns it, gives it the session, the shown page's
// status and the pointer, and takes its presses.
//
// Each button is a FadedLayer in the sidebar (its symbol in labelColor in a surface the button's
// size), faded by its effect group to SymbolButton's 0.6, or 0.125 disabled: a button turning on or
// off changes an opacity (Update says so, for the caller to commit) and draws nothing, and only a
// new symbol (reload's X), appearance or scale draws that button's surface again. As on the Mac
// the buttons show no hover or press of their own. Hovering one shows its tooltip, Windows' own: a
// comctl32 tooltip made on the first hover over a button (so comctl32 isn't loaded before), with a
// tool for each button's rectangle and the window's mouse messages relayed to it (RelayMouse).
// sidebar.left is Kite's own geometry (core's SidebarToggleShape); the others are Segoe Fluent
// Icons' (Segoe MDL2 Assets' on Windows 10) stand-ins, scaled and placed to the Mac's ink.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "core/SidebarTopRow.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/FadedLayer.h"

namespace kite {

class SidebarTopRowView {
public:
    // `tooltips` false (a capture) never makes a tooltip window.
    static std::unique_ptr<SidebarTopRowView> Create(HWND window, IDWriteFactory* dwrite, bool tooltips, std::wstring& error);
    ~SidebarTopRowView();
    SidebarTopRowView(const SidebarTopRowView&) = delete;
    SidebarTopRowView& operator=(const SidebarTopRowView&) = delete;

    // The compositor whose chrome it draws in, its visuals under `parent` (the sidebar's); null
    // drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    bool DeviceLost() const { return deviceLost_; }

    // What it shows, in the selected space's appearance. True when a compositor property changed
    // (a button turned on or off) that the caller has to commit; a new symbol or appearance is
    // NeedsDraw's instead.
    bool Update(const TopRowModel& model, bool dark);
    // The sidebar's width (points) and the window's scale.
    void Layout(float width, UINT dpi);
    // The window's mouse message (client px, the sidebar at the window's left), for the tooltips:
    // the first move over a button makes them. Inactive (the sidebar hidden) they go.
    void RelayMouse(UINT message, WPARAM wParam, LPARAM lParam);
    void SetTooltipsActive(bool active);
    bool HasTooltips() const { return tooltip_ != nullptr; }
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
    explicit SidebarTopRowView(HWND window) : window_(window) {}

    struct ButtonGpu {
        FadedLayer layer;
        std::string symbol;  // what its surface shows
        POINT at{};          // its place in the sidebar, px
        bool dirty = true;
    };
    void ReleaseGpu();
    std::wstring DrawButton(const TopRowItem& item, ButtonGpu& gpu, bool readBack);
    // The symbol centred on `centre` (the button's centre, in the surface's points).
    void DrawSymbol(ID2D1DeviceContext* context, const std::string& symbol, D2D1_POINT_2F centre);
    // Sets each shown button's place and opacity; true when an opacity changed.
    bool Place();
    void MakeTooltips();
    void UpdateTooltips();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    HWND window_;
    bool tooltipsAllowed_ = true;
    HWND tooltip_ = nullptr;
    bool tooltipsActive_ = true;
    std::vector<UINT_PTR> tools_;  // the tooltip's tools, by button

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> iconFormat_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1Geometry> toggleShape_;
    bool toggleShapeTried_ = false;  // made once per device, kept even when it failed
    std::map<TopRowButton, ButtonGpu> gpu_;
    std::map<TopRowButton, float> opacities_;  // as last set on the visuals
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
