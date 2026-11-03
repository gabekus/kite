#pragma once
// The GPU side of Kite's chrome: one D3D11 device and the compiled shaders (shaders/*.hlsl),
// drawing either into the window's swap chain (Compositor) or offscreen at any size, for
// captures and the GPU-vs-reference backdrop test. The Mac's ShaderLibrary + ThemeView.

#include <windows.h>  // first: the DirectX headers need its types

#include <d3d11.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

#include "core/ThemeBackdrop.h"
#include "shell/Capture.h"

namespace kite {

class Renderer {
public:
    // A hardware device, or WARP (Windows' software rasterizer) where there's no GPU, as on
    // CI runners. nullptr with `error` set when neither works.
    static std::unique_ptr<Renderer> Create(std::wstring& error);

    ID3D11Device* Device() const { return device_.Get(); }
    bool IsSoftware() const { return software_; }

    // Clears `target` to `base` (premultiplied) and draws the theme over it, as Core Animation
    // composites the Mac's ThemeView over the window's material.
    void DrawTheme(ID3D11RenderTargetView* target, UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base);

    // The same drawing into an offscreen texture, read back. nullopt with `error` on failure.
    std::optional<Pixels> RenderTheme(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base,
                                      std::wstring& error);

private:
    Renderer() = default;
    bool Init(std::wstring& error);

    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> fullscreenVertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> themePixel_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> themeUniforms_;
    Microsoft::WRL::ComPtr<ID3D11BlendState> premultipliedOver_;
    bool software_ = false;
};

}  // namespace kite
