// See Renderer.h.

#include "shell/Renderer.h"

#include <cstring>
#include <iterator>

#include "shell/Errors.h"

#ifdef KITE_RUNTIME_SHADERS
// Builds without the Windows SDK's fxc (the MinGW cross-compile check) compile the HLSL when
// they start. Shipping builds (MSVC) embed bytecode compiled at build time instead.
#include <d3dcompiler.h>

#include "ThemeHlsl.inc"  // kThemeHlsl, generated from shaders/Theme.hlsl
#else
#include "ThemePixel.h"        // kThemePixelShader, compiled by fxc
#include "FullscreenVertex.h"  // kFullscreenVertexShader
#endif

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

#ifdef KITE_RUNTIME_SHADERS
ComPtr<ID3DBlob> Compile(const char* entry, const char* target, std::wstring& error) {
    ComPtr<ID3DBlob> code, messages;
    HRESULT hr = D3DCompile(kThemeHlsl, std::strlen(kThemeHlsl), "Theme.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.GetAddressOf(), messages.GetAddressOf());
    if (FAILED(hr)) {
        error = HResultMessage(L"compiling Theme.hlsl", hr);
        if (messages) {
            const char* text = static_cast<const char*>(messages->GetBufferPointer());
            error += L": " + std::wstring(text, text + messages->GetBufferSize());
        }
        return nullptr;
    }
    return code;
}
#endif

}  // namespace

std::unique_ptr<Renderer> Renderer::Create(std::wstring& error) {
    std::unique_ptr<Renderer> renderer(new Renderer());
    if (!renderer->Init(error)) return nullptr;
    return renderer;
}

bool Renderer::Init(std::wstring& error) {
    // BGRA for DirectComposition and Direct2D; feature level 10 is enough for these shaders.
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                        D3D_FEATURE_LEVEL_10_0};
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = E_FAIL;
    for (D3D_DRIVER_TYPE type : {D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP}) {
        hr = D3D11CreateDevice(nullptr, type, nullptr, flags, levels, static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
                               device_.ReleaseAndGetAddressOf(), nullptr, context_.ReleaseAndGetAddressOf());
        if (SUCCEEDED(hr)) {
            software_ = type == D3D_DRIVER_TYPE_WARP;
            break;
        }
    }
    if (FAILED(hr)) {
        error = HResultMessage(L"D3D11CreateDevice", hr);
        return false;
    }

#ifdef KITE_RUNTIME_SHADERS
    ComPtr<ID3DBlob> vs = Compile("FullscreenVertex", "vs_4_0", error);
    if (!vs) return false;
    ComPtr<ID3DBlob> ps = Compile("ThemePixel", "ps_4_0", error);
    if (!ps) return false;
    const void* vsCode = vs->GetBufferPointer();
    const SIZE_T vsSize = vs->GetBufferSize();
    const void* psCode = ps->GetBufferPointer();
    const SIZE_T psSize = ps->GetBufferSize();
#else
    const void* vsCode = kFullscreenVertexShader;
    const SIZE_T vsSize = sizeof(kFullscreenVertexShader);
    const void* psCode = kThemePixelShader;
    const SIZE_T psSize = sizeof(kThemePixelShader);
#endif
    if (FAILED(hr = device_->CreateVertexShader(vsCode, vsSize, nullptr, fullscreenVertex_.GetAddressOf()))) {
        error = HResultMessage(L"CreateVertexShader", hr);
        return false;
    }
    if (FAILED(hr = device_->CreatePixelShader(psCode, psSize, nullptr, themePixel_.GetAddressOf()))) {
        error = HResultMessage(L"CreatePixelShader", hr);
        return false;
    }

    D3D11_BUFFER_DESC uniforms{};
    uniforms.ByteWidth = sizeof(ThemeUniforms);
    uniforms.Usage = D3D11_USAGE_DEFAULT;
    uniforms.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    if (FAILED(hr = device_->CreateBuffer(&uniforms, nullptr, themeUniforms_.GetAddressOf()))) {
        error = HResultMessage(L"CreateBuffer", hr);
        return false;
    }

    // Premultiplied "over": the theme over the cleared base, as Core Animation blends layers.
    D3D11_BLEND_DESC blend{};
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(hr = device_->CreateBlendState(&blend, premultipliedOver_.GetAddressOf()))) {
        error = HResultMessage(L"CreateBlendState", hr);
        return false;
    }
    return true;
}

void Renderer::DrawTheme(ID3D11RenderTargetView* target, UINT width, UINT height, const ThemeUniforms& uniforms,
                         const Rgba& base) {
    const float clear[4] = {base.r, base.g, base.b, base.a};
    context_->ClearRenderTargetView(target, clear);
    context_->UpdateSubresource(themeUniforms_.Get(), 0, nullptr, &uniforms, 0, 0);

    D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
    context_->RSSetViewports(1, &viewport);
    context_->OMSetRenderTargets(1, &target, nullptr);
    context_->OMSetBlendState(premultipliedOver_.Get(), nullptr, 0xFFFFFFFF);
    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(fullscreenVertex_.Get(), nullptr, 0);
    context_->PSSetShader(themePixel_.Get(), nullptr, 0);
    ID3D11Buffer* buffers[] = {themeUniforms_.Get()};
    context_->PSSetConstantBuffers(0, 1, buffers);
    context_->Draw(3, 0);  // one full-screen triangle
    ID3D11RenderTargetView* none = nullptr;
    context_->OMSetRenderTargets(1, &none, nullptr);
}

std::optional<Pixels> Renderer::RenderTheme(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base,
                                            std::wstring& error) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;  // the swap chain's format: values are sRGB-encoded already
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> texture;
    HRESULT hr = device_->CreateTexture2D(&desc, nullptr, texture.GetAddressOf());
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTexture2D", hr);
        return std::nullopt;
    }
    ComPtr<ID3D11RenderTargetView> view;
    if (FAILED(hr = device_->CreateRenderTargetView(texture.Get(), nullptr, view.GetAddressOf()))) {
        error = HResultMessage(L"CreateRenderTargetView", hr);
        return std::nullopt;
    }
    DrawTheme(view.Get(), width, height, uniforms, base);

    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(hr = device_->CreateTexture2D(&desc, nullptr, staging.GetAddressOf()))) {
        error = HResultMessage(L"CreateTexture2D (staging)", hr);
        return std::nullopt;
    }
    context_->CopyResource(staging.Get(), texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(hr = context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
        error = HResultMessage(L"Map", hr);
        return std::nullopt;
    }
    Pixels pixels{width, height, std::vector<uint8_t>(static_cast<size_t>(width) * height * 4)};
    for (UINT y = 0; y < height; ++y) {
        std::memcpy(pixels.bgra.data() + static_cast<size_t>(y) * width * 4,
                    static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch, width * 4);
    }
    context_->Unmap(staging.Get(), 0);
    return pixels;
}

}  // namespace kite
