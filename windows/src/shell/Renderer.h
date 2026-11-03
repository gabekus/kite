#pragma once
// The GPU side of Kite's chrome: one D3D11 device and the compiled shaders (shaders/*.hlsl),
// drawing either into the window's swap chain (Compositor) or offscreen in float for the
// GPU-vs-reference backdrop test. The Mac's ShaderLibrary + ThemeView.

#include <windows.h>  // first: the DirectX headers need its types

#include <d3d11.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/ThemeBackdrop.h"
#include "shell/Capture.h"

namespace kite {

class Renderer {
public:
    // A hardware device (on a machine without a GPU driver, such as a CI runner, that's the
    // Microsoft Basic Render Driver), else WARP, Windows' software rasterizer. nullptr with
    // `error` set when neither works.
    static std::unique_ptr<Renderer> Create(std::wstring& error);
    ~Renderer();
    Renderer(const Renderer&) = delete;
    Renderer& operator=(const Renderer&) = delete;

    // Signalled when Windows removes or resets the GPU (a driver update, a TDR, a hybrid GPU
    // switching), so the window can rebuild its renderer even while it isn't drawing. Null on
    // Windows before 10 1607, where a lost device shows up at the next Present instead.
    HANDLE DeviceRemovedEvent() const { return deviceRemoved_; }

    ID3D11Device* Device() const { return device_.Get(); }
    // Whether it draws on the CPU: the WARP device, or the Microsoft Basic Render Driver a
    // GPU-less VM (like a CI runner) offers as its "hardware" adapter.
    bool IsSoftware() const { return software_; }
    // The adapter's name, e.g. for the backdrop test's report.
    const std::wstring& AdapterName() const { return adapterName_; }
    // The largest texture side: 16384 px at feature level 11, 8192 at 10.x.
    UINT MaxTextureSize() const { return maxTextureSize_; }
    // Unbinds everything and submits pending work, so released swap chain buffers really are
    // released (D3D11 destroys objects lazily) before ResizeBuffers.
    void Flush();

    // Clears `target` to `base` (premultiplied) and draws the theme over it, as Core Animation
    // composites the Mac's ThemeView over the window's material.
    void DrawTheme(ID3D11RenderTargetView* target, UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base);

    // The same drawing into an offscreen 32-bit float texture, read back as unclamped RGBA
    // floats, row by row: the shader's exact output, for the GPU-vs-reference test. nullopt
    // with `error` on failure.
    std::optional<std::vector<float>> RenderTheme(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base,
                                                  std::wstring& error);

    // Copies a BGRA8 texture of this device (a swap chain buffer) back to the CPU.
    std::optional<Pixels> ReadBack(ID3D11Texture2D* texture, std::wstring& error);

private:
    Renderer() = default;
    bool Init(std::wstring& error);
    bool ReadRows(ID3D11Texture2D* texture, UINT bytesPerPixel, uint8_t* out, std::wstring& error);

    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> fullscreenVertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> themePixel_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> themeUniforms_;
    Microsoft::WRL::ComPtr<ID3D11BlendState> premultipliedOver_;
    bool software_ = false;
    std::wstring adapterName_;
    UINT maxTextureSize_ = D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION;
    HANDLE deviceRemoved_ = nullptr;
    DWORD deviceRemovedCookie_ = 0;
};

}  // namespace kite
