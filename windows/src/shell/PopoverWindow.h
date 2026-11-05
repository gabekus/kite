#pragma once
// The window a popover of Kite's lives in, in NSPopover's place: Change Space Icon…'s picker
// (shell/SpaceIconPickerView) and Choose a Theme's swatches (shell/ThemeSwatchesView). A popover
// reaches over the page, which is a child window, so it's a window of its own: a tool popup owned
// by the browser window (over it, minimized with it, never in the taskbar or Alt+Tab), never
// activated (the browser window keeps the keyboard, which the controller passes on), shown only
// when its view opens it (not again with its restored owner), drawn by DirectComposition in a
// target of its own on the window's compositor. Beside its arrow it's clear and passes the pointer
// to the window under it. It's made the first time its view opens. Which presses and focus changes
// close a popover is the controller's one rule (BrowserWindowController::Filter).

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1.h>
#include <dcomp.h>
#include <wrl/client.h>

#include <functional>
#include <optional>
#include <string>

namespace kite {

// The popover's own fill and edge, the picker's and the swatches' alike (NSPopover's material, one
// for both: the UI gate's Mac theme editor is the same grey as its picker), in each appearance.
inline D2D1_COLOR_F PopoverFill(bool dark) { return dark ? D2D1_COLOR_F{0.172f, 0.172f, 0.18f, 1} : D2D1_COLOR_F{0.965f, 0.965f, 0.965f, 1}; }
inline D2D1_COLOR_F PopoverEdge(bool dark) { return dark ? D2D1_COLOR_F{1, 1, 1, 0.15f} : D2D1_COLOR_F{0, 0, 0, 0.12f}; }

class PopoverWindow {
public:
    struct Callbacks {
        // Whether a point of the window (client px) is on the popover (its body or its arrow);
        // elsewhere the pointer goes to the window under it. None: all of it is.
        std::function<bool(POINT client)> onPopover;
        // The view's own messages (the pointer, the cursor, its scale); none sends a message on
        // to the default.
        std::function<std::optional<LRESULT>(UINT message, WPARAM wParam, LPARAM lParam)> message;
        // The window went with its owner (the browser window's close): its target with it.
        std::function<void()> destroyed;
    };

    explicit PopoverWindow(HWND owner) : owner_(owner) {}
    ~PopoverWindow();
    PopoverWindow(const PopoverWindow&) = delete;
    PopoverWindow& operator=(const PopoverWindow&) = delete;

    void SetCallbacks(Callbacks callbacks) { callbacks_ = std::move(callbacks); }
    HWND Owner() const { return owner_; }
    // The window, made the first time it's asked for. Empty on success.
    std::wstring Make();
    HWND Handle() const { return window_; }

    // Its DirectComposition target on `device`, `root` its root (once a device: after a lost GPU,
    // ReleaseTarget, then a new one). S_OK when it's there.
    HRESULT MakeTarget(IDCompositionDevice* device, IDCompositionVisual* root);
    bool HasTarget() const { return target_ != nullptr; }
    void ReleaseTarget() { target_.Reset(); }

    // At `topLeft` (screen px), `width` × `height`, over its owner and nothing else, never
    // activated; shown unless `show` is false (a quiet run's, which sizes it and keeps it hidden).
    void Place(POINT topLeft, UINT width, UINT height, bool show = true);
    void Hide();
    // The work area of the monitor at `screen` (px), which a popover stays inside, as AppKit keeps
    // one on its positioning view's screen.
    static RECT WorkArea(POINT screen);

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);

    HWND owner_;
    HWND window_ = nullptr;
    Callbacks callbacks_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
};

}  // namespace kite
