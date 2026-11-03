#pragma once
// The window's DirectComposition tree, on one device: behind the page's child window, the
// theme backdrop (a premultiplied-alpha swap chain) with the chrome over it (the sidebar);
// over the page, the overlay (the command bar), in a second target with topmost TRUE
// (docs/windows.md, Rendering). The backdrop draws only when something changed (the theme,
// the base colour or the size), so an idle window costs nothing, like the Mac's on-demand
// ThemeView. Whoever changes the tree commits it (Commit), once a pass.

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

    // Where the chrome's visuals go: over the backdrop, behind the page.
    IDCompositionVisual* Chrome() const { return chrome_.Get(); }
    // Where the overlay's visuals go: over everything in the window, the page included.
    IDCompositionVisual* Overlay() const { return overlay_.Get(); }
    IDCompositionDevice* Device() const { return device_.Get(); }
    Renderer& GetRenderer() const { return renderer_; }
    // Shows every change made to the tree and its surfaces since the last commit, at once.
    HRESULT Commit() { return device_->Commit(); }

    // The GPU was reset or removed (a driver update, a TDR, a hybrid GPU switching): this
    // compositor and its renderer can't draw again and have to be recreated.
    bool DeviceLost() const { return deviceLost_; }

private:
    explicit Compositor(Renderer& renderer) : renderer_(renderer) {}

    Renderer& renderer_;
    Microsoft::WRL::ComPtr<IDXGISwapChain2> swapChain_;
    Microsoft::WRL::ComPtr<IDCompositionDevice> device_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_, overlayTarget_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_, backdrop_, chrome_, overlay_;
    HANDLE frameLatency_ = nullptr;
    UINT width_ = 0, height_ = 0;
    bool presented_ = false;
    bool deviceLost_ = false;
    ThemeUniforms lastUniforms_{};
    Rgba lastBase_{};
};

}  // namespace kite
