#pragma once
// Windows' minimize, maximize (or restore) and close buttons, which Kite draws itself since its
// window has no caption (MainWindow): Windows 11's caption buttons, 46 × 32 at the top-right
// (core/TitleBar.h), with Segoe Fluent Icons' Chrome glyphs and WinUI's caption button colours.
// MainWindow's hitTest reports them to Windows as HTMINBUTTON, HTMAXBUTTON and HTCLOSE, so
// Windows 11 shows Snap Layouts over the maximize button; their presses come here as
// non-client messages (HandleMessage).
//
// One small DirectComposition surface in the window's chrome (Compositor::Chrome), over the
// backdrop, drawn with the compositor's Direct2D context: at once when the hover, press or
// window activation changes, and with the window's next pass when its size, maximized state
// or appearance does.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>

#include "core/TitleBar.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"

namespace kite {

class CaptionButtonsView {
public:
    static std::unique_ptr<CaptionButtonsView> Create(HWND window, std::wstring& error);
    ~CaptionButtonsView();
    CaptionButtonsView(const CaptionButtonsView&) = delete;
    CaptionButtonsView& operator=(const CaptionButtonsView&) = delete;

    // The window's compositor, whose chrome it draws in; null drops every GPU object.
    void UseCompositor(Compositor* compositor);
    // The window's size, DPI or maximized state changed. Draw follows.
    void Layout(UINT dpi);
    // Light glyphs (a dark theme) or dark ones, as the sidebar's text. Drawn with the next
    // Draw (the sidebar's, so both change at one commit).
    void SetDark(bool dark);

    // The window's non-client mouse messages over the buttons (hover, press, release, which
    // minimizes, maximizes, restores or closes) and its activation (an inactive window's glyphs
    // are dimmed). True when it took `message`, with `result`.
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);

    // Draws now if anything changed since the last draw; with `readBack`, always, also copying
    // the buttons (premultiplied BGRA) there and their top-left in the window (px) to `origin`,
    // for --capture. The caller commits the compositor. Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr, POINT* origin = nullptr);
    bool DeviceLost() const { return deviceLost_; }
    // Its own draw (a hover, a press) found the GPU gone: the window rebuilds and draws.
    std::function<void()> onDeviceLost;

private:
    explicit CaptionButtonsView(HWND window) : window_(window) {}

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    void SetHover(std::optional<CaptionButton> hovered);
    // The buttons in a surface `width` px wide, flush right.
    void DrawContent(ID2D1DeviceContext* context, UINT width);
    // Draws now and commits, after the pointer or the window's activation changed.
    void Refresh();

    HWND window_;
    Compositor* compositor_ = nullptr;

    // Each glyph laid out once in its button's box: minimize, maximize, restore, close.
    Microsoft::WRL::ComPtr<IDWriteTextLayout> glyphs_[4];

    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    int offsetX_ = -1;
    bool deviceLost_ = false;
    bool dirty_ = true;

    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool dark_ = true;
    bool active_ = true;
    bool maximized_ = false;
    std::optional<CaptionButton> hovered_, pressed_;
};

}  // namespace kite
