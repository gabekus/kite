#pragma once
// The window's DirectComposition tree: today one visual holding a premultiplied-alpha swap
// chain with the theme backdrop; the sidebar, page and command bar become sibling visuals in
// later checkpoints (docs/windows.md, Rendering). It draws only when told to (a theme, size or
// scale change), so an idle window costs nothing, like the Mac's on-demand ThemeView.

#include <windows.h>  // first: the DirectX headers need its types

#include <dcomp.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <memory>
#include <string>

#include "shell/Renderer.h"

namespace kite {

class Compositor {
public:
    // The window needs WS_EX_NOREDIRECTIONBITMAP, so DirectComposition is all it shows.
    static std::unique_ptr<Compositor> Create(HWND hwnd, Renderer& renderer, std::wstring& error);

    // Draws a frame the size of the client area (px) and presents it. Empty on success.
    std::wstring Draw(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base);

    // Blocks until DirectComposition has taken the last commit, i.e. the frame is on screen.
    void WaitForFrame();

private:
    Compositor(Renderer& renderer) : renderer_(renderer) {}

    Renderer& renderer_;
    Microsoft::WRL::ComPtr<IDXGISwapChain1> swapChain_;
    Microsoft::WRL::ComPtr<IDCompositionDevice> device_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_;
    UINT width_ = 0, height_ = 0;
};

}  // namespace kite
