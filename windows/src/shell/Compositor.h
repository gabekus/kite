#pragma once
// The window's DirectComposition tree, on one device: behind the page's child window, the
// theme backdrop (a premultiplied-alpha swap chain) with the chrome over it (the sidebar and
// the caption buttons);
// over the page, the overlay (the command bar, over the find bar), in a second target with topmost TRUE
// (docs/windows.md, Rendering). The backdrop draws only when something changed (the theme,
// the base colour or the size), so an idle window costs nothing, like the Mac's on-demand
// ThemeView. Whoever changes the tree commits it (Commit), once a pass. The chrome's views
// (the sidebar, the caption buttons) draw their surfaces with its one Direct2D device context
// (DrawSurface).

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <string>

#include "shell/Renderer.h"

namespace kite {

// A GPU device removed or reset, or a Direct2D target to recreate: the compositor is rebuilt.
bool IsDeviceLost(HRESULT hr);

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
    // Over the page too, but under the overlay's: what belongs to the page (the find bar).
    IDCompositionVisual* PageOverlay() const { return pageOverlay_.Get(); }
    IDCompositionDevice* Device() const { return device_.Get(); }
    Renderer& GetRenderer() const { return renderer_; }
    // The Direct2D context the chrome's views draw with, on the renderer's device. Its
    // resources (brushes, bitmaps) are the views' own and go when they drop this compositor.
    ID2D1DeviceContext* D2D() const { return d2dContext_.Get(); }
    // Draws `content` (in points, at `dpi`) into all of `surface`, `width` × `height` px,
    // cleared first, then the same drawing into a texture read back as premultiplied BGRA when
    // `readBack` is given (for --capture). Empty on success, else what failed;
    // IsDeviceLost(hr) says whether the GPU went.
    using Content = std::function<void(ID2D1DeviceContext*)>;
    std::wstring DrawSurface(IDCompositionVirtualSurface* surface, UINT width, UINT height, UINT dpi, const Content& content,
                             Pixels* readBack, HRESULT& hr);
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
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_, backdrop_, chrome_, overlay_, overlayRoot_, pageOverlay_;
    Microsoft::WRL::ComPtr<ID2D1Factory1> d2dFactory_;
    Microsoft::WRL::ComPtr<ID2D1Device> d2dDevice_;
    Microsoft::WRL::ComPtr<ID2D1DeviceContext> d2dContext_;
    HANDLE frameLatency_ = nullptr;
    UINT width_ = 0, height_ = 0;
    bool presented_ = false;
    bool deviceLost_ = false;
    ThemeUniforms lastUniforms_{};
    Rgba lastBase_{};
};

}  // namespace kite
