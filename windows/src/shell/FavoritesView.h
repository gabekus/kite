#pragma once
// The favorites grid between the address field and the space's page (the Mac's FavoritesTrayView,
// FavoriteTileView and FavoritePaneView, SidebarFavorites.swift). Core lays it out and says how
// each pane is filled (core/Favorites.h); SidebarView owns it, gives it the grid, the hover and
// the window's scale, takes its presses, and draws its favicons (DrawIcon, the rows' own).
//
// Each pane is four FadedLayers in a visual of its own, as the Mac's pane is a fill, a tint, a
// ring and a favicon view: a white wash, the favicon's colour, the colour's ring and the favicon,
// each drawn once at full strength and faded by its effect group to what FavoriteLookOf says. So
// a hover or a selection moving is opacities alone (Update and SetHover say so, for the caller to
// commit) and draws nothing; a favicon arriving draws only its pane's icon layer (and, once its
// colour is known, its tint and ring); only a new size, scale or appearance draws a pane's wash.
// Hovering a pane shows its tooltip (the tab's title, the Mac's toolTip): a comctl32 tooltip made
// on the first hover over a pane, as the top row's.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <wrl/client.h>

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/Favorites.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/FadedLayer.h"
#include "shell/Favicons.h"

namespace kite {

class FavoritesView {
public:
    // `favicons` may be null (a capture without --favicons): every pane shows the globe and no
    // colour. `tooltips` false (a capture) never makes a tooltip window.
    static std::unique_ptr<FavoritesView> Create(HWND window, Favicons* favicons, bool tooltips);
    ~FavoritesView();
    FavoritesView(const FavoritesView&) = delete;
    FavoritesView& operator=(const FavoritesView&) = delete;

    // The compositor whose chrome it draws in, its visual under `parent` (the sidebar's root);
    // null drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    bool DeviceLost() const { return deviceLost_; }

    // What it shows, laid out for the sidebar's width, in the selected space's appearance. True
    // when a compositor property changed (a pane's fill, tint or ring) that the caller commits;
    // what has to draw is NeedsDraw's.
    bool Update(FavoritesTray tray, bool dark);
    const FavoritesTray& Tray() const { return tray_; }
    // The window's scale.
    void Layout(UINT dpi);
    // The pane under the pointer (its tab), or none. True when an opacity changed.
    bool SetHover(const std::optional<std::string>& tabID);
    // Icons arrived (Favicons::TakeResults): the panes whose favicon or colour is now there draw
    // those again. True when one does.
    bool IconsArrived();
    // Whether a pane shows the icon at `url` (the sidebar keeps its bitmap on the GPU).
    bool ShowsIcon(const std::string& url) const;

    // The window's mouse message (client px), for the tooltips; inactive (the sidebar hidden)
    // they go.
    void RelayMouse(UINT message, WPARAM wParam, LPARAM lParam);
    void SetTooltipsActive(bool active);
    bool HasTooltips() const { return tooltip_ != nullptr; }

    // Draws a favicon into `box` (points), as the sidebar's rows do; true when it drew the icon
    // itself, not the globe or a symbol.
    using DrawIcon = std::function<bool(ID2D1DeviceContext*, const FaviconSource&, D2D1_RECT_F box)>;
    bool NeedsDraw() const;
    // Draws the layers that changed; with `readBack`, all of them, kept for ComposeInto. The caller
    // commits. Empty on success.
    std::wstring Draw(const DrawIcon& drawIcon, bool readBack = false);
    // After a read-back draw: the panes over `sidebar` (its pixels from its top-left), at their
    // opacities, as DirectComposition shows them.
    void ComposeInto(Pixels& sidebar) const;
    // How many layers have drawn (the smoke test checks a hover or a selection draws none).
    size_t SurfaceDraws() const { return surfaceDraws_; }
    // A pane's centre in client px (the sidebar at the window's left, `left` points in).
    std::optional<POINT> PaneCentre(size_t index, float left) const;
    // The look each pane is at now, in the grid's order (for the smoke test).
    std::vector<FavoriteLook> Looks() const;

private:
    FavoritesView(HWND window, Favicons* favicons, bool tooltips) : window_(window), favicons_(favicons), tooltipsAllowed_(tooltips) {}

    struct PaneGpu {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;  // the four layers' parent, at `at`
        FadedLayer fill, tint, ring, icon;
        POINT at{};        // its place in the sidebar, px
        BarRect frame;     // the frame its layers were drawn for
        bool shapeDirty = true;  // the wash (its size)
        bool colorDirty = true;  // the tint and the ring (their colour)
        bool iconDirty = true;
        bool drewIcon = false;   // its icon layer shows the icon, not the globe
        std::optional<ThemeColor> drawnColor;
        std::optional<FavoriteLook> placed;  // the opacities set on its layers
    };
    struct PaneRef {
        const FavoritePane* pane;
        size_t index;  // in the grid's order of panes
    };
    std::vector<PaneRef> Panes() const;
    void ReleaseGpu();
    // The favicon's colour, lightened (FavoritePaneView.color): none until its 16px icon is there.
    std::optional<ThemeColor> ColorOf(const FavoritePane& pane);
    FavoriteLook LookOf(const FavoritePane& pane) const;
    std::wstring DrawPane(const FavoritePane& pane, PaneGpu& gpu, const DrawIcon& drawIcon, bool readBack);
    // Sets each pane's place and opacities; true when an opacity changed.
    bool Place();
    void MakeTooltips();
    void UpdateTooltips();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }
    UINT IconPixels() const;

    HWND window_;
    Favicons* favicons_;
    bool tooltipsAllowed_;
    HWND tooltip_ = nullptr;
    bool tooltipsActive_ = true;
    size_t tools_ = 0;

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionVisual> container_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    std::map<std::string, PaneGpu> gpu_;  // by tab id
    bool deviceLost_ = false;
    bool placed_ = false;
    size_t surfaceDraws_ = 0;

    FavoritesTray tray_;
    bool dark_ = true;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    std::optional<std::string> hover_;
    // Each favicon's colour once its 16px icon is known (none: grey, or it didn't decode).
    std::map<std::string, std::optional<ThemeColor>> colors_;
};

}  // namespace kite
