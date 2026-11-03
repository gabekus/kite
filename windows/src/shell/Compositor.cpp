// See Compositor.h.

#include "shell/Compositor.h"

#include <algorithm>

#include "shell/Errors.h"

using Microsoft::WRL::ComPtr;

namespace kite {

std::unique_ptr<Compositor> Compositor::Create(HWND hwnd, Renderer& renderer, std::wstring& error) {
    std::unique_ptr<Compositor> compositor(new Compositor(renderer));
    RECT client{};
    GetClientRect(hwnd, &client);
    compositor->width_ = static_cast<UINT>(std::max<LONG>(client.right - client.left, 1));
    compositor->height_ = static_cast<UINT>(std::max<LONG>(client.bottom - client.top, 1));

    ComPtr<IDXGIDevice> dxgiDevice;
    HRESULT hr = renderer.Device()->QueryInterface(IID_PPV_ARGS(dxgiDevice.GetAddressOf()));
    ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(hr)) hr = dxgiDevice->GetAdapter(adapter.GetAddressOf());
    ComPtr<IDXGIFactory2> factory;
    if (SUCCEEDED(hr)) hr = adapter->GetParent(IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"getting the DXGI factory", hr);
        return nullptr;
    }

    // Flip model with premultiplied alpha, so the window's backdrop material shows through
    // the theme's tint where it isn't opaque.
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = compositor->width_;
    desc.Height = compositor->height_;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    if (FAILED(hr = factory->CreateSwapChainForComposition(renderer.Device(), &desc, nullptr, compositor->swapChain_.GetAddressOf()))) {
        error = HResultMessage(L"CreateSwapChainForComposition", hr);
        return nullptr;
    }

    if (FAILED(hr = DCompositionCreateDevice(dxgiDevice.Get(), IID_PPV_ARGS(compositor->device_.GetAddressOf())))) {
        error = HResultMessage(L"DCompositionCreateDevice", hr);
        return nullptr;
    }
    if (FAILED(hr = compositor->device_->CreateTargetForHwnd(hwnd, TRUE, compositor->target_.GetAddressOf())) ||
        FAILED(hr = compositor->device_->CreateVisual(compositor->root_.GetAddressOf())) ||
        FAILED(hr = compositor->root_->SetContent(compositor->swapChain_.Get())) ||
        FAILED(hr = compositor->target_->SetRoot(compositor->root_.Get())) ||
        FAILED(hr = compositor->device_->Commit())) {
        error = HResultMessage(L"building the composition tree", hr);
        return nullptr;
    }
    return compositor;
}

std::wstring Compositor::Draw(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base) {
    width = std::max(width, 1u);
    height = std::max(height, 1u);
    HRESULT hr = S_OK;
    if (width != width_ || height != height_) {
        if (FAILED(hr = swapChain_->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) {
            return HResultMessage(L"ResizeBuffers", hr);
        }
        width_ = width;
        height_ = height;
    }
    ComPtr<ID3D11Texture2D> buffer;
    if (FAILED(hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(buffer.GetAddressOf())))) return HResultMessage(L"GetBuffer", hr);
    ComPtr<ID3D11RenderTargetView> view;
    if (FAILED(hr = renderer_.Device()->CreateRenderTargetView(buffer.Get(), nullptr, view.GetAddressOf()))) {
        return HResultMessage(L"CreateRenderTargetView", hr);
    }
    renderer_.DrawTheme(view.Get(), width, height, uniforms, base);
    // Sync interval 1: one frame per vblank at the display's own rate, no cap of ours.
    if (FAILED(hr = swapChain_->Present(1, 0))) return HResultMessage(L"Present", hr);
    return {};
}

void Compositor::WaitForFrame() {
    device_->Commit();
    device_->WaitForCommitCompletion();
}

}  // namespace kite
