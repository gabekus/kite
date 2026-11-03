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

}  // namespace

bool IsDeviceLost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == static_cast<HRESULT>(D2DERR_RECREATE_TARGET);
}

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
    // One Direct2D device for the chrome's surfaces, on the same GPU device.
    if (FAILED(hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), nullptr,
                                      reinterpret_cast<void**>(c.d2dFactory_.GetAddressOf()))) ||
        FAILED(hr = c.d2dFactory_->CreateDevice(dxgiDevice.Get(), c.d2dDevice_.GetAddressOf())) ||
        FAILED(hr = c.d2dDevice_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, c.d2dContext_.GetAddressOf()))) {
        error = HResultMessage(L"creating the chrome's Direct2D device", hr);
        return nullptr;
    }
    // Grayscale, as the Mac draws text on its translucent chrome (ClearType needs an opaque
    // background).
    c.d2dContext_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    return compositor;
}

std::wstring Compositor::DrawSurface(IDCompositionVirtualSurface* surface, UINT width, UINT height, UINT dpi, const Content& content,
                                     Pixels* readBack, HRESULT& hr) {
    const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    const D2D1_BITMAP_PROPERTIES1 targetProps =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), static_cast<float>(dpi),
                                static_cast<float>(dpi));
    ID2D1DeviceContext* context = d2dContext_.Get();
    // Into `target` (a DirectComposition surface's update, or the capture's texture) at
    // `offset` px.
    auto render = [&](IDXGISurface* target, POINT offset) -> HRESULT {
        Microsoft::WRL::ComPtr<ID2D1Bitmap1> bitmap;
        HRESULT made = context->CreateBitmapFromDxgiSurface(target, &targetProps, bitmap.GetAddressOf());
        if (FAILED(made)) return made;
        context->SetTarget(bitmap.Get());
        context->SetDpi(static_cast<float>(dpi), static_cast<float>(dpi));
        context->BeginDraw();
        context->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(offset.x) / scale, static_cast<float>(offset.y) / scale));
        // A surface's update can sit in a shared atlas: draw only inside it.
        context->PushAxisAlignedClip(D2D1_RECT_F{0, 0, static_cast<float>(width) / scale, static_cast<float>(height) / scale},
                                     D2D1_ANTIALIAS_MODE_ALIASED);
        context->Clear(D2D1_COLOR_F{0, 0, 0, 0});
        content(context);
        context->PopAxisAlignedClip();
        made = context->EndDraw();
        context->SetTarget(nullptr);
        return made;
    };
    Microsoft::WRL::ComPtr<IDXGISurface> update;
    POINT offset{};
    if (FAILED(hr = surface->BeginDraw(nullptr, IID_PPV_ARGS(update.GetAddressOf()), &offset))) {
        return HResultMessage(L"starting to draw a surface", hr);
    }
    hr = render(update.Get(), offset);
    const HRESULT ended = surface->EndDraw();
    if (FAILED(hr)) return HResultMessage(L"drawing a surface", hr);
    if (FAILED(hr = ended)) return HResultMessage(L"finishing a surface", hr);
    if (!readBack) return {};

    // The same drawing into a texture of its own, read back as DirectComposition shows it.
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<IDXGISurface> target;
    if (FAILED(hr = renderer_.Device()->CreateTexture2D(&desc, nullptr, texture.GetAddressOf())) || FAILED(hr = texture.As(&target)) ||
        FAILED(hr = render(target.Get(), POINT{}))) {
        return HResultMessage(L"drawing a surface for the capture", hr);
    }
    std::wstring error;
    auto pixels = renderer_.ReadBack(texture.Get(), error);
    if (!pixels) return error;
    *readBack = std::move(*pixels);
    return {};
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
