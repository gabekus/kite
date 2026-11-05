#pragma once
// The favorites grid between the address field and the space's page (the Mac's FavoritesTrayView,
// FavoriteTileView, FavoritePaneView and FavoritesEmptyStateView, SidebarFavorites.swift). Core
// lays it out and says how each pane is filled (core/Favorites.h); SidebarView owns it, gives it
// the tray, the hover and the window's scale, takes its presses, and draws its favicons (DrawIcon,
// the rows' own).
//
// Each pane is up to four FadedLayers in a visual of its own, as the Mac's pane is a fill, a tint,
// a ring and a favicon view: a white wash, the favicon's colour, the colour's ring and the favicon,
// each drawn once at full strength and faded by its effect group to what FavoriteLookOf says (the
// tint and the ring are made only once the favicon has a colour). So a hover or a selection moving
// is opacities alone (Update and SetHover say so, for the caller to commit) and draws nothing; a
// favicon arriving draws only its pane's icon layer (and, once its colour is known, its tint and
// ring); only a new size, scale or appearance draws a pane's wash. With no favorites, until it's
// dismissed, the empty state: its outline and text in one layer, its close button in another that
// the pointer over the box fades in. Hovering a pane shows its tooltip (the tab's title, the Mac's
// toolTip), and the close button "Dismiss" (shell/RelayedTooltips).

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "core/Favorites.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/FadedLayer.h"
#include "shell/Favicons.h"
#include "shell/RelayedTooltips.h"

namespace kite {

class FavoritesView {
public:
    // `favicons` may be null (a capture without --favicons): every pane shows the globe and no
    // colour. `tooltips` false (a capture) never makes a tooltip window.
    static std::unique_ptr<FavoritesView> Create(HWND window, IDWriteFactory* dwrite, Favicons* favicons, bool tooltips, std::wstring& error);
    ~FavoritesView();
    FavoritesView(const FavoritesView&) = delete;
    FavoritesView& operator=(const FavoritesView&) = delete;

    // The compositor whose chrome it draws in, its visual under `parent` (the sidebar's root);
    // null drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    bool DeviceLost() const { return deviceLost_; }

    // What it shows, laid out for the sidebar's width, in the selected space's appearance, with the
    // sidebar's leading edge at rest `left` points in (its tooltips' places). True when a compositor
    // property changed (a pane's fill, tint or ring) that the caller commits; what has to draw is
    // NeedsDraw's.
    bool Update(FavoritesTray tray, bool dark, float left);
    const FavoritesTray& Tray() const { return tray_; }
    // The empty state's height in a sidebar `width` wide: its title's and subtitle's lines as
    // DirectWrite wraps them (FavoritesEmptyStateView.height(forWidth:)).
    float EmptyStateHeight(float width);
    // The window's scale.
    void Layout(UINT dpi);
    // The pane under the pointer (its place in the grid's order), and whether the pointer is over
    // the empty state (its close button shows). True when an opacity changed.
    bool SetHover(std::optional<size_t> pane, bool overEmptyState);
    // Icons arrived (Favicons::TakeResults): the panes whose favicon or colour is now there draw
    // those again. True when one does.
    bool IconsArrived();
    // Whether a pane shows the icon at `url` (the sidebar keeps its bitmap on the GPU).
    bool ShowsIcon(const std::string& url) const { return urls_.contains(url); }

    // The window's mouse message (client px), for the tooltips; inactive (the sidebar hidden)
    // they go.
    void RelayMouse(UINT message, WPARAM wParam, LPARAM lParam) { tooltips_.Relay(message, wParam, lParam); }
    void SetTooltipsActive(bool active) { tooltips_.SetActive(active); }
    bool HasTooltips() const { return tooltips_.Made(); }

    // Draws a favicon into `box` (points), as the sidebar's rows do; true when it drew the icon
    // itself, not the globe or a symbol.
    using DrawIcon = std::function<bool(ID2D1DeviceContext*, const FaviconSource&, D2D1_RECT_F box)>;
    bool NeedsDraw() const;
    // Draws the layers that changed; with `readBack`, all of them, kept for ComposeInto. Its visual
    // goes into the parent just above `above` (the address field's: under the pages and the space
    // bar, as the Mac's subviews). The caller commits. Empty on success.
    std::wstring Draw(const DrawIcon& drawIcon, IDCompositionVisual* above, bool readBack = false);
    // After a read-back draw: the panes over `sidebar` (its pixels from its top-left), at their
    // opacities, as DirectComposition shows them.
    void ComposeInto(Pixels& sidebar) const;
    // How many layers have drawn (the smoke test checks a hover or a selection draws none).
    size_t SurfaceDraws() const { return surfaceDraws_; }
    // A pane's centre in client px (the sidebar at the window's left, `left` points in).
    std::optional<POINT> PaneCentre(size_t index, float left) const;
    // The look each pane is at now, in the grid's order, and whether the close button shows.
    std::vector<FavoriteLook> Looks() const;
    bool CloseShown() const { return emptyHover_ && tray_.emptyState; }
    // Whether the empty state's layers have drawn (the smoke test's favorites-to-none).
    bool EmptyStateDrawn() const { return emptyBox_.surface && emptyClose_.surface; }

private:
    FavoritesView(HWND window, Favicons* favicons, bool tooltips) : favicons_(favicons), tooltips_(window, tooltips) {}

    struct PaneGpu {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;  // its layers' parent, at `at`
        FadedLayer fill, tint, ring, icon;
        POINT at{};  // its place in the sidebar, px, as set on the visual
        bool atSet = false;
        // What its layers were drawn for (none: never), and what to draw again.
        std::optional<std::pair<BarRect, FaviconSource>> drawn;
        FavoriteRedraw redraw{true, true, true};
        bool drewIcon = false;  // its icon layer shows the icon, not the globe
        std::optional<ThemeColor> drawnColor;
        std::optional<FavoriteLook> placed;  // the opacities set on its layers
    };
    void ReleaseGpu();
    // The favicon's colour, lightened (FavoritePaneView.color): none until its 16px icon is there.
    std::optional<ThemeColor> ColorOf(const FavoritePane& pane);
    FavoriteLook LookOf(size_t index) const;
    std::wstring DrawPane(size_t index, const DrawIcon& drawIcon, bool readBack);
    std::wstring DrawEmptyState(bool readBack);
    void DrawEmptyBox(ID2D1DeviceContext* context, D2D1_RECT_F box);
    // Sets each pane's place and opacities, and the close button's; true when an opacity changed.
    bool Place();
    void UpdateTooltips();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }
    UINT IconPixels() const;
    // A frame's whole-pixel corner (what's drawn into its layers is offset by the rest).
    POINT CornerOf(const BarRect& frame) const;

    Favicons* favicons_;
    RelayedTooltips tooltips_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> titleFormat_, subtitleFormat_;

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionVisual> container_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle> dashes_;
    Microsoft::WRL::ComPtr<ID2D1Geometry> closeShape_;  // core's CloseShape, made once per device
    bool closeShapeTried_ = false;
    std::map<std::string, PaneGpu> gpu_;  // by tab id
    std::vector<PaneGpu*> paneGpu_;       // each pane's (into gpu_), in panes_' order
    FadedLayer emptyBox_, emptyClose_;
    POINT emptyAt_{}, closeAt_{};
    bool emptyDirty_ = true;
    std::optional<float> closeOpacity_;  // as set on its effect
    bool deviceLost_ = false;
    bool placed_ = false;
    size_t surfaceDraws_ = 0;

    FavoritesTray tray_;
    std::vector<const FavoritePane*> panes_;  // into tray_, in the grid's order
    std::set<std::string> urls_;              // the favicons they show
    bool dark_ = true;
    float left_ = 0;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    std::optional<size_t> hover_;
    bool emptyHover_ = false;
    std::map<float, float> emptyHeights_;  // by width
    // Each favicon's colour once its 16px icon is known (none: grey, or it didn't decode).
    std::map<std::string, std::optional<ThemeColor>> colors_;
};

}  // namespace kite
