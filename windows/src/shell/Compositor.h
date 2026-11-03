#pragma once
// The window's DirectComposition tree: today one visual holding a premultiplied-alpha swap
// chain with the theme backdrop; the sidebar and command bar become sibling visuals in later
// checkpoints (docs/windows.md, Rendering). It draws only when something changed (the theme,
// the base colour or the size), so an idle window costs nothing, like the Mac's on-demand
// ThemeView.

#include <windows.h>  // first: the DirectX headers need its types

#include <dcomp.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <memory>
#include <string>

#include "shell/Renderer.h"

namespace kite {

class Compositor {
public:
    // The window needs WS_EX_NOREDIRECTIONBITMAP, so DirectComposition is all it shows.
    static std::unique_ptr<Compositor> Create(HWND hwnd, Renderer& renderer, std::wstring& error);
    ~Compositor();
    Compositor(const Compositor&) = delete;
    Compositor& operator=(const Compositor&) = delete;

    // Draws a frame the size of the client area (px) and presents it, unless it would be the
    // frame already on screen. With `readBack`, also copies the presented frame into it (for
    // --capture), drawing it even when unchanged. Empty on success.
    std::wstring Draw(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base, Pixels* readBack = nullptr);

    // The GPU was reset or removed (a driver update, a TDR, a hybrid GPU switching): this
    // compositor and its renderer can't draw again and have to be recreated.
    bool DeviceLost() const { return deviceLost_; }

private:
    explicit Compositor(Renderer& renderer) : renderer_(renderer) {}

    Renderer& renderer_;
    Microsoft::WRL::ComPtr<IDXGISwapChain2> swapChain_;
    Microsoft::WRL::ComPtr<IDCompositionDevice> device_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_;
    HANDLE frameLatency_ = nullptr;
    UINT width_ = 0, height_ = 0;
    bool presented_ = false;
    bool deviceLost_ = false;
    ThemeUniforms lastUniforms_{};
    Rgba lastBase_{};
};

}  // namespace kite
