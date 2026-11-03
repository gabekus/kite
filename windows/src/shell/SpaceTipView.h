#pragma once
// The tip over a hovered space's cell: the Mac's SpaceTip (SidebarView.swift) in a window of its
// own, as SpaceTipWindow puts it (a borderless panel, a child of the browser window, that never
// takes the mouse or activates, so a wide tip over the first cell reaches past the window's left
// edge as Arc's does). What it says and where its parts sit is core's (SpaceTipOf,
// LayOutSpaceTip, SpaceTipOrigin); this draws it with Direct2D on the compositor's device, in a
// DirectComposition target of its own window, and fades it in over 0.15 s.
//
// SidebarView owns it and says when: 0.4 s after the pointer comes onto a cell, gone as it leaves.

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

class SpaceTipView {
public:
    // A hidden window owned by `owner` (the browser window), so it stays over it and goes with it
    // when it's minimized.
    static std::unique_ptr<SpaceTipView> Create(HWND owner, IDWriteFactory* dwrite, std::wstring& error);
    ~SpaceTipView();
    SpaceTipView(const SpaceTipView&) = delete;
    SpaceTipView& operator=(const SpaceTipView&) = delete;

    // The compositor to draw with; null drops everything of the old one's (its device went).
    void UseCompositor(Compositor* compositor);

    // Shows `tip` for space `spaceID` over `cell` (window points, the owner's client area) at the
    // owner's `dpi`, fading in. Empty on success.
    std::wstring Show(const std::string& spaceID, const SpaceTip& tip, const BarRect& cell, UINT dpi);
    // Hides it at once (SpaceTipWindow.hide orders the panel out without a fade).
    void Hide();

    // For --capture: `tip` over `cell` drawn at `dpi` as the window would show it at rest, without
    // a window, and its top-left in the owner's client px.
    std::wstring Render(const SpaceTip& tip, const BarRect& cell, UINT dpi, Pixels& out, POINT& origin);

    bool DeviceLost() const { return deviceLost_; }

private:
    SpaceTipView(HWND owner, IDWriteFactory* dwrite) : owner_(owner), dwrite_(dwrite) {}
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);

    // The tip's text measured and laid out (points).
    struct Measured {
        SpaceTipLayout layout;
        Microsoft::WRL::ComPtr<IDWriteTextLayout> name, chipText;
        std::vector<Microsoft::WRL::ComPtr<IDWriteTextLayout>> keys;
    };
    Measured Measure(const SpaceTip& tip) const;
    void Paint(ID2D1DeviceContext* context, const SpaceTip& tip, const Measured& measured);
    // The profile chip's face (face.smiling), centred on `centre`.
    void DrawFace(ID2D1DeviceContext* context, D2D1_POINT_2F centre, const SpaceTip& tip);
    // Draws `tip` into `surface`, `width` × `height` px (and into `readBack`).
    std::wstring DrawInto(IDCompositionVirtualSurface* surface, UINT width, UINT height, UINT dpi, const SpaceTip& tip,
                          const Measured& measured, Pixels* readBack, HRESULT& hr);
    bool MakeTree(HRESULT& hr);

    HWND owner_ = nullptr;
    HWND window_ = nullptr;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> nameFormat_, chipFormat_, keyFormat_;
    float nameCap_ = 0, chipCap_ = 0, keyCap_ = 0;  // each format's cap height, in points
    Compositor* compositor_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionEffectGroup> fade_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1PathGeometry> smile_;  // the face's smile, about its centre (the device's factory)
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle> roundCaps_;
    std::optional<std::string> showing_;
    bool deviceLost_ = false;
};

}  // namespace kite
