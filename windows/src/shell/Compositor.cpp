// See Compositor.h.

#include "shell/Compositor.h"

#include <algorithm>
#include <cstring>

#include "shell/Errors.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// docs/windows.md, Refresh rate: flip-discard with a frame-latency waitable object and a
// latency of one, so a live resize draws for the frame that's about to show, not three behind.
constexpr UINT kSwapChainFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

bool IsDeviceLost(HRESULT hr) { return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET; }

}  // namespace

std::unique_ptr<Compositor> Compositor::Create(HWND hwnd, Renderer& renderer, std::wstring& error) {
    std::unique_ptr<Compositor> compositor(new Compositor(renderer));
    RECT client{};
    GetClientRect(hwnd, &client);
    const LONG largest = static_cast<LONG>(renderer.MaxTextureSize());
    compositor->width_ = static_cast<UINT>(std::clamp<LONG>(client.right - client.left, 1, largest));
    compositor->height_ = static_cast<UINT>(std::clamp<LONG>(client.bottom - client.top, 1, largest));

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
    // the theme's tint where it isn't opaque. Composition swap chains always stretch.
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = compositor->width_;
    desc.Height = compositor->height_;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    desc.Flags = kSwapChainFlags;
    ComPtr<IDXGISwapChain1> swapChain;
    if (FAILED(hr = factory->CreateSwapChainForComposition(renderer.Device(), &desc, nullptr, swapChain.GetAddressOf()))) {
        error = HResultMessage(L"CreateSwapChainForComposition", hr);
        return nullptr;
    }
    if (FAILED(hr = swapChain.As(&compositor->swapChain_)) || FAILED(hr = compositor->swapChain_->SetMaximumFrameLatency(1))) {
        error = HResultMessage(L"setting the swap chain's frame latency", hr);
        return nullptr;
    }
    compositor->frameLatency_ = compositor->swapChain_->GetFrameLatencyWaitableObject();

    if (FAILED(hr = DCompositionCreateDevice(dxgiDevice.Get(), IID_PPV_ARGS(compositor->device_.GetAddressOf())))) {
        error = HResultMessage(L"DCompositionCreateDevice", hr);
        return nullptr;
    }
    // topmost FALSE: this tree sits behind the window's child windows, where the page (a CEF
    // child window, W6) goes; the overlay's, topmost TRUE, over them.
    Compositor& c = *compositor;
    if (FAILED(hr = c.device_->CreateTargetForHwnd(hwnd, FALSE, c.target_.GetAddressOf())) ||
        FAILED(hr = c.device_->CreateTargetForHwnd(hwnd, TRUE, c.overlayTarget_.GetAddressOf())) ||
        FAILED(hr = c.device_->CreateVisual(c.root_.GetAddressOf())) || FAILED(hr = c.device_->CreateVisual(c.backdrop_.GetAddressOf())) ||
        FAILED(hr = c.device_->CreateVisual(c.chrome_.GetAddressOf())) || FAILED(hr = c.device_->CreateVisual(c.overlay_.GetAddressOf())) ||
        FAILED(hr = c.backdrop_->SetContent(c.swapChain_.Get())) || FAILED(hr = c.root_->AddVisual(c.backdrop_.Get(), FALSE, nullptr)) ||
        FAILED(hr = c.root_->AddVisual(c.chrome_.Get(), TRUE, c.backdrop_.Get())) || FAILED(hr = c.target_->SetRoot(c.root_.Get())) ||
        FAILED(hr = c.overlayTarget_->SetRoot(c.overlay_.Get())) || FAILED(hr = c.device_->Commit())) {
        error = HResultMessage(L"building the composition tree", hr);
        return nullptr;
    }
    return compositor;
}

Compositor::~Compositor() {
    if (frameLatency_) CloseHandle(frameLatency_);
}

std::wstring Compositor::Draw(UINT width, UINT height, const ThemeUniforms& uniforms, const Rgba& base, Pixels* readBack) {
    if (deviceLost_) return L"the GPU device was lost";
    // At most the GPU's largest texture: past it (over 5461 points at 300%) the swap chain stops
    // growing and DirectComposition shows it at that size, top-left, leaving the rest of the
    // window to the material. A capture refuses that size instead (main.cpp).
    width = std::clamp(width, 1u, renderer_.MaxTextureSize());
    height = std::clamp(height, 1u, renderer_.MaxTextureSize());
    const bool unchanged = presented_ && width == width_ && height == height_ &&
                           std::memcmp(&uniforms, &lastUniforms_, sizeof(uniforms)) == 0 &&
                           std::memcmp(&base, &lastBase_, sizeof(base)) == 0;
    if (unchanged && !readBack) return {};

    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    if (width != width_ || height != height_) {
        renderer_.Flush();
        if (FAILED(hr = swapChain_->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, kSwapChainFlags))) {
            return fail(L"ResizeBuffers", hr);
        }
        width_ = width;
        height_ = height;
    }
    ComPtr<ID3D11Texture2D> buffer;
    if (FAILED(hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(buffer.GetAddressOf())))) return fail(L"GetBuffer", hr);
    ComPtr<ID3D11RenderTargetView> view;
    if (FAILED(hr = renderer_.Device()->CreateRenderTargetView(buffer.Get(), nullptr, view.GetAddressOf()))) {
        return fail(L"CreateRenderTargetView", hr);
    }
    // Wait for the frame queue to have room, so this frame is the next one shown. Bounded, so
    // a stalled compositor can't hang the UI thread.
    if (frameLatency_) WaitForSingleObjectEx(frameLatency_, 1000, FALSE);
    renderer_.DrawTheme(view.Get(), width, height, uniforms, base);
    std::wstring readBackError;
    if (readBack) {
        // The frame exactly as it's handed to DirectComposition.
        if (auto pixels = renderer_.ReadBack(buffer.Get(), readBackError)) *readBack = std::move(*pixels);
    }
    // Sync interval 1: one frame per vblank at the display's own rate, no cap of ours.
    if (FAILED(hr = swapChain_->Present(1, 0))) return fail(L"Present", hr);
    presented_ = true;
    lastUniforms_ = uniforms;
    lastBase_ = base;
    return readBackError;
}

}  // namespace kite
