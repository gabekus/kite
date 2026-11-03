#pragma once
// The sidebar, drawn to ArcMetrics.Sidebar: the address field, then the selected space's page
// (its header, pinned tabs and folders, the divider, New Tab and today's tabs). The Mac's
// SidebarColumnView, SidebarHeaderView's address field and SidebarSpaceList's rows
// (SidebarColumn.swift, SidebarHeader.swift, SidebarList.swift, SidebarListCells.swift,
// SidebarListRows.swift). What it lists comes from core (SidebarRows).
//
// It's one DirectComposition surface in the window's chrome (Compositor::Chrome), over the
// backdrop and behind the page, drawn with Direct2D and DirectWrite only when what it shows
// changes. For now it's static: no hover, clicks, scrolling, top row, favorites or space bar.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "core/Models.h"
#include "core/Sidebar.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/Favicons.h"

namespace kite {

class SidebarView {
public:
    // `favicons` may be null (a capture): every tab shows the globe.
    static std::unique_ptr<SidebarView> Create(HWND window, Favicons* favicons, std::wstring& error);
    ~SidebarView();
    SidebarView(const SidebarView&) = delete;
    SidebarView& operator=(const SidebarView&) = delete;

    // The window's compositor, whose chrome it draws in; null drops every GPU object (before
    // the compositor is rebuilt after a lost device).
    void UseCompositor(Compositor* compositor);

    // What it shows: the selected space's page and the address, in that space's appearance.
    // When anything changed, it draws on the next pass of the message loop.
    void Update(const BrowserState& state);
    // The window's size or DPI changed: `width` is the sidebar's, in points. Draw follows.
    void Layout(float width, UINT dpi);
    // Icons arrived (Favicons::TakeResults): the rows that wait for them draw again.
    void Invalidate();

    // Draws now if anything changed since the last draw; with `readBack`, always, also
    // copying the sidebar (premultiplied BGRA, at the window's top-left) there for --capture.
    // The caller commits the compositor. Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr);
    bool DeviceLost() const { return deviceLost_; }

    // The window's messages: its posted redraw. True when it handled `message`.
    bool HandleMessage(UINT message);
    static constexpr UINT kRedrawMessage = WM_APP + 3;

private:
    SidebarView(HWND window, Favicons* favicons) : window_(window), favicons_(favicons) {}

    struct Model {
        bool dark = true;
        std::string address;
        std::vector<SidebarRow> rows;
        bool operator==(const Model&) const = default;
    };

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    void DrawContent(ID2D1DeviceContext* context);
    void DrawRow(ID2D1DeviceContext* context, const SidebarRow& row, float top);
    void DrawText(ID2D1DeviceContext* context, const std::string& text, IDWriteTextFormat* format, float x, float baseline,
                  float maxWidth, D2D1_COLOR_F color);
    void DrawGlyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color);
    void DrawFavicon(ID2D1DeviceContext* context, const SidebarRow& row, D2D1_RECT_F box);
    float Baseline(IDWriteTextFormat* format);
    D2D1_COLOR_F Primary(float alpha) const;

    HWND window_;
    Favicons* favicons_;
    Compositor* compositor_ = nullptr;

    // Device-independent.
    Microsoft::WRL::ComPtr<ID2D1Factory1> d2dFactory_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> addressFormat_, headerFormat_, tabFormat_, folderFormat_, emojiFormat_, iconFormat_;
    Microsoft::WRL::ComPtr<IDWriteInlineObject> ellipsis_;
    std::map<IDWriteTextFormat*, float> baselines_;  // each format's first baseline from its line's top

    // GPU.
    Microsoft::WRL::ComPtr<ID2D1Device> d2dDevice_;
    Microsoft::WRL::ComPtr<ID2D1DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    std::map<std::pair<std::string, UINT>, Microsoft::WRL::ComPtr<ID2D1Bitmap1>> faviconBitmaps_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    bool deviceLost_ = false;

    // State.
    Model model_;
    float width_ = 240;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool dirty_ = true;
    bool redrawPosted_ = false;
};

}  // namespace kite
