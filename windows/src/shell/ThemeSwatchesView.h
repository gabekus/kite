#pragma once
// Choose a Theme's popover on the Create a Space page: the Mac's ThemeEditor, presented pointing
// off the row's trailing edge (ThemeEditor.present(pointing: true)), as far as Windows has it: the
// editor's row of preset swatches with its chevrons (core/SpaceCreation.h's theme_swatches_metrics).
// The colour grid, intensity and grain come with the theme editor. A swatch sets the space's
// colours (its intensity kept), and the popover stays open, as an NSPopover with .transient does;
// it closes as one does: Escape, a press anywhere else, the window losing the keyboard, moving or
// minimizing, or the page closing.
//
// In NSPopover's place, a window of its own owned by the browser window (it reaches over the page,
// which is a child window), never activated, drawn with DirectComposition in its own target on the
// window's compositor: one surface, drawn when it opens and when its appearance changes. A press
// picks on release over the same swatch, as a plain SwiftUI Button; nothing hovers.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/SpaceCreation.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"

namespace kite {

class ThemeSwatchesView {
public:
    struct Callbacks {
        // Swatch `preset` (Theme::Presets()) pressed and let go.
        std::function<void(size_t preset)> pick;
    };
    // A hidden window owned by `owner` (the browser window). `offscreen`: a quiet run's (a test, a
    // capture), whose popover opens and takes the messages sent to its window, which never shows.
    static std::unique_ptr<ThemeSwatchesView> Create(HWND owner, Callbacks callbacks, bool offscreen, std::wstring& error);
    ~ThemeSwatchesView();
    ThemeSwatchesView(const ThemeSwatchesView&) = delete;
    ThemeSwatchesView& operator=(const ThemeSwatchesView&) = delete;

    // The compositor to draw with; null drops every GPU object (it closes).
    void UseCompositor(Compositor* compositor);

    // Opens it off `row` (the Choose a Theme row, the owner's client points) at the owner's `dpi`,
    // in the space's appearance, its presets' accents `accents`. Empty on success.
    std::wstring Open(const BarRect& row, UINT dpi, bool dark, std::vector<ThemeColor> accents);
    void Close();
    bool IsOpen() const { return open_; }
    // The appearance changed (a light preset picked under it): it draws again.
    void SetDark(bool dark);

    // For the tests: its window, where swatch `index`'s middle is in that window's client px, and
    // how many times its surface has drawn.
    HWND Window() const { return window_; }
    std::optional<POINT> SwatchPoint(size_t index) const;
    size_t Draws() const { return draws_; }
    // For --capture: the popover as it shows off `row`, drawn without its window, and its top-left
    // in the owner's client px.
    std::wstring Render(const BarRect& row, UINT dpi, bool dark, std::vector<ThemeColor> accents, Pixels& out, POINT& origin);
    bool DeviceLost() const { return deviceLost_; }

private:
    ThemeSwatchesView(HWND owner, Callbacks callbacks, bool offscreen) : owner_(owner), callbacks_(std::move(callbacks)), offscreen_(offscreen) {}
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);

    // The window's size and its body's top-left in it, px, and the body's in the owner's client
    // area, for `row` at `scale`.
    struct Frame {
        SwatchesPlacement placement;  // points
        float margin = 0;             // points around the body (the arrow's side, the edge)
        UINT width = 0, height = 0;   // px
        POINT origin{};               // the window's top-left, owner client px
    };
    Frame FrameFor(const BarRect& row, float scale) const;
    void Paint(ID2D1DeviceContext* context, const Frame& frame);
    std::wstring DrawInto(IDCompositionVirtualSurface* surface, const Frame& frame, Pixels* readBack, HRESULT& hr);
    std::optional<size_t> SwatchAt(LPARAM client) const;

    HWND owner_;
    Callbacks callbacks_;
    bool offscreen_ = false;
    HWND window_ = nullptr;
    Compositor* compositor_ = nullptr;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> chevronFormat_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    bool deviceLost_ = false;

    bool open_ = false;
    bool dark_ = true;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    BarRect row_;
    std::vector<ThemeColor> accents_;
    ThemeSwatchesLayout layout_;
    Frame frame_;
    std::optional<size_t> pressed_;
    size_t draws_ = 0;
};

}  // namespace kite
