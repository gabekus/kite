// See OffscreenPage.h.

#include "shell/OffscreenPage.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "shell/Errors.h"
#include "FullscreenVertex.h"     // kFullscreenVertexShader (Theme.hlsl)
#include "OffscreenPagePixel.h"   // kOffscreenPagePixelShader (OffscreenPage.hlsl)

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

int64_t Qpc() {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

}  // namespace

std::unique_ptr<OffscreenPresenter> OffscreenPresenter::Create(LUID adapterLuid, std::wstring& error) {
    std::unique_ptr<OffscreenPresenter> p(new OffscreenPresenter());
    ComPtr<IDXGIFactory2> factory;
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateDXGIFactory2", hr);
        return nullptr;
    }
    // The same adapter as Kite's renderer (and Chromium's GPU process, which picks the same), so the
    // shared texture never crosses adapters.
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapters1(i, adapter.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        if (desc.AdapterLuid.LowPart == adapterLuid.LowPart && desc.AdapterLuid.HighPart == adapterLuid.HighPart) break;
        adapter.Reset();
    }
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    ComPtr<ID3D11Device> device;
    hr = D3D11CreateDevice(adapter.Get(), adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
                           device.GetAddressOf(), nullptr, p->context_.GetAddressOf());
    if (FAILED(hr) || FAILED(hr = device.As(&p->device_))) {
        error = HResultMessage(L"creating the page's D3D11 device", hr);
        return nullptr;
    }
    // CEF's thread draws with it, and a capture reads back from Kite's.
    ComPtr<ID3D11Multithread> multithread;
    if (SUCCEEDED(p->context_.As(&multithread))) multithread->SetMultithreadProtected(TRUE);
    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGIAdapter> deviceAdapter;
    if (FAILED(hr = device.As(&dxgiDevice)) || FAILED(hr = dxgiDevice->GetAdapter(deviceAdapter.GetAddressOf())) ||
        FAILED(hr = deviceAdapter->GetParent(IID_PPV_ARGS(p->factory_.GetAddressOf())))) {
        error = HResultMessage(L"getting the page device's factory", hr);
        return nullptr;
    }
    // The corners: cut out, anti-aliased, as the frame is copied (OffscreenPage.hlsl), so the
    // swap chain is premultiplied. KITE_OSR_CLIP=dcomp uses DirectComposition's rounded clip
    // on an opaque swap chain instead (a plain copy, but aliased corners), for comparison.
    p->maskCorners_ = GetEnvironmentVariableW(L"KITE_OSR_CLIP", nullptr, 0) == 0;
    if (p->maskCorners_) {
        D3D11_BUFFER_DESC cb{};
        cb.ByteWidth = 16;
        cb.Usage = D3D11_USAGE_DYNAMIC;
        cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        if (FAILED(hr = p->device_->CreateVertexShader(kFullscreenVertexShader, sizeof(kFullscreenVertexShader), nullptr,
                                                        p->vertex_.GetAddressOf())) ||
            FAILED(hr = p->device_->CreatePixelShader(kOffscreenPagePixelShader, sizeof(kOffscreenPagePixelShader), nullptr,
                                                       p->pixel_.GetAddressOf())) ||
            FAILED(hr = p->device_->CreateBuffer(&cb, nullptr, p->card_.GetAddressOf()))) {
            error = HResultMessage(L"creating the page's corner shader", hr);
            return nullptr;
        }
    }
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = desc.Height = 16;  // resized to the page's first frame
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    // Opaque with DirectComposition's clip, so DWM needn't blend the page.
    desc.AlphaMode = p->maskCorners_ ? DXGI_ALPHA_MODE_PREMULTIPLIED : DXGI_ALPHA_MODE_IGNORE;
    if (FAILED(hr = p->factory_->CreateSwapChainForComposition(p->device_.Get(), &desc, nullptr, p->swapChain_.GetAddressOf()))) {
        error = HResultMessage(L"creating the page's swap chain", hr);
        return nullptr;
    }
    p->width_ = p->height_ = 16;
    p->readBackDone_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    // The counters, for windows/tools/osrperf.
    const std::wstring name = L"Local\\KiteOsrSpike-" + std::to_wstring(GetCurrentProcessId());
    p->statsMapping_ = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(OffscreenStats), name.c_str());
    if (p->statsMapping_) {
        p->stats_ = static_cast<OffscreenStats*>(MapViewOfFile(p->statsMapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(OffscreenStats)));
    }
    if (!p->stats_) {
        static OffscreenStats fallback{};
        p->stats_ = &fallback;
    }
    std::memset(p->stats_, 0, sizeof(OffscreenStats));
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    p->stats_->qpcFrequency = static_cast<uint64_t>(frequency.QuadPart);
    p->stats_->version = 1;
    return p;
}

OffscreenPresenter::~OffscreenPresenter() {
    Attach(nullptr, nullptr);
    if (readBackDone_) CloseHandle(readBackDone_);
    if (statsMapping_) {
        UnmapViewOfFile(stats_);
        CloseHandle(statsMapping_);
    }
}

void OffscreenPresenter::Attach(IDCompositionDevice* device, IDCompositionVisual* parent) {
    if (parent_ && visual_) parent_->RemoveVisual(visual_.Get());
    visual_.Reset();
    clip_.Reset();
    parent_.Reset();
    dcomp_.Reset();
    contentSet_ = false;
    if (!device || !parent) return;
    if (FAILED(device->CreateVisual(visual_.GetAddressOf())) || FAILED(device->CreateRectangleClip(clip_.GetAddressOf()))) {
        visual_.Reset();
        clip_.Reset();
        return;
    }
    // Soft edges: the rounded clip is anti-aliased, as Core Animation's cornerRadius is.
    ComPtr<IDCompositionVisual2> visual2;
    if (SUCCEEDED(visual_.As(&visual2))) visual2->SetBorderMode(DCOMPOSITION_BORDER_MODE_SOFT);
    visual_->SetClip(clip_.Get());
    parent->AddVisual(visual_.Get(), FALSE, nullptr);
    parent_ = parent;
    dcomp_ = device;
}

void OffscreenPresenter::Place(const RECT& card, float radius, bool visible) {
    radius_ = radius;
    if (!visual_) return;
    // With the corners cut out of the frame, the clip only bounds it to the card mid-resize.
    if (maskCorners_) radius = 0;
    visual_->SetOffsetX(static_cast<float>(card.left));
    visual_->SetOffsetY(static_cast<float>(card.top));
    const float w = static_cast<float>(card.right - card.left), h = static_cast<float>(card.bottom - card.top);
    clip_->SetLeft(0.0f);
    clip_->SetTop(0.0f);
    clip_->SetRight(w);
    clip_->SetBottom(h);
    clip_->SetTopLeftRadiusX(radius);
    clip_->SetTopLeftRadiusY(radius);
    clip_->SetTopRightRadiusX(radius);
    clip_->SetTopRightRadiusY(radius);
    clip_->SetBottomLeftRadiusX(radius);
    clip_->SetBottomLeftRadiusY(radius);
    clip_->SetBottomRightRadiusX(radius);
    clip_->SetBottomRightRadiusY(radius);
    if (visible != contentSet_) {
        visual_->SetContent(visible ? swapChain_.Get() : nullptr);
        contentSet_ = visible;
    }
    dcomp_->Commit();
}

bool OffscreenPresenter::EnsureSwapChain(UINT width, UINT height) {
    if (width == width_ && height == height_) return true;
    context_->ClearState();
    context_->Flush();
    if (FAILED(swapChain_->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return false;
    width_ = width;
    height_ = height;
    return true;
}

bool OffscreenPresenter::EnsureTexture(ComPtr<ID3D11Texture2D>& texture, UINT width, UINT height) {
    if (texture) {
        D3D11_TEXTURE2D_DESC have{};
        texture->GetDesc(&have);
        if (have.Width == width && have.Height == height) return true;
        texture.Reset();
    }
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    return SUCCEEDED(device_->CreateTexture2D(&desc, nullptr, texture.GetAddressOf()));
}

bool OffscreenPresenter::Compose(ID3D11Texture2D* view) {
    D3D11_TEXTURE2D_DESC desc{};
    view->GetDesc(&desc);
    if (!EnsureSwapChain(desc.Width, desc.Height)) return false;
    ComPtr<ID3D11Texture2D> buffer;
    if (FAILED(swapChain_->GetBuffer(0, IID_PPV_ARGS(buffer.GetAddressOf())))) return false;
    // One GPU pass over the page's frame, no CPU in between: a copy, or a draw that cuts the
    // corners out.
    if (maskCorners_) {
        if (!DrawMasked(buffer.Get(), view, desc)) return false;
    } else {
        context_->CopyResource(buffer.Get(), view);
    }
    if (popupShown_ && popupValid_) {
        D3D11_TEXTURE2D_DESC popup{};
        popupCopy_->GetDesc(&popup);
        const LONG left = std::max<LONG>(popupRect_.left, 0), top = std::max<LONG>(popupRect_.top, 0);
        D3D11_BOX box{0, 0, 0, std::min<UINT>(popup.Width, desc.Width - std::min<UINT>(desc.Width, static_cast<UINT>(left))),
                      std::min<UINT>(popup.Height, desc.Height - std::min<UINT>(desc.Height, static_cast<UINT>(top))), 1};
        if (box.right > 0 && box.bottom > 0) {
            context_->CopySubresourceRegion(buffer.Get(), 0, static_cast<UINT>(left), static_cast<UINT>(top), 0, popupCopy_.Get(), 0, &box);
        }
    }
    if (readBackWanted_.exchange(false)) {
        // For --capture: the frame as it's handed to DirectComposition.
        D3D11_TEXTURE2D_DESC staging = desc;
        staging.Usage = D3D11_USAGE_STAGING;
        staging.BindFlags = 0;
        staging.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        staging.MiscFlags = 0;
        ComPtr<ID3D11Texture2D> copy;
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (SUCCEEDED(device_->CreateTexture2D(&staging, nullptr, copy.GetAddressOf()))) {
            context_->CopyResource(copy.Get(), buffer.Get());
            if (SUCCEEDED(context_->Map(copy.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
                Pixels pixels;
                pixels.width = desc.Width;
                pixels.height = desc.Height;
                pixels.bgra.resize(static_cast<size_t>(desc.Width) * desc.Height * 4);
                for (UINT y = 0; y < desc.Height; ++y) {
                    std::memcpy(pixels.bgra.data() + static_cast<size_t>(y) * desc.Width * 4,
                                static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch, desc.Width * 4);
                }
                // An opaque swap chain's alpha means nothing: opaque, as DirectComposition shows it.
                if (!maskCorners_) {
                    for (size_t i = 3; i < pixels.bgra.size(); i += 4) pixels.bgra[i] = 255;
                }
                context_->Unmap(copy.Get(), 0);
                readBack_ = std::move(pixels);
            }
        }
        SetEvent(readBackDone_);
    }
    buffer.Reset();
    // Sync interval 1: at most one frame per vblank, at the display's own rate. CEF's thread
    // only waits here when DXGI's queue is full (three frames ahead).
    if (FAILED(swapChain_->Present(1, 0))) return false;
    return true;
}

bool OffscreenPresenter::Paint(int browserID, bool popup, HANDLE sharedTexture) {
    if (browserID != shown_) {
        ++stats_->ignoredPaints;
        return false;
    }
    const int64_t start = Qpc();
    std::lock_guard lock(mutex_);
    if (popup) ++stats_->popupPaints;
    else ++stats_->viewPaints;
    // Chromium's pool texture: opened every frame (its handle can't be cached) and copied
    // before this returns, as CEF's OnAcceleratedPaint requires.
    ComPtr<ID3D11Texture2D> source;
    if (FAILED(device_->OpenSharedResource1(sharedTexture, IID_PPV_ARGS(source.GetAddressOf())))) {
        ++stats_->openFailures;
        return false;
    }
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    bool presented = false;
    if (popup) {
        if (EnsureTexture(popupCopy_, desc.Width, desc.Height)) {
            context_->CopyResource(popupCopy_.Get(), source.Get());
            popupValid_ = true;
            if (viewValid_) presented = Compose(viewCopy_.Get());
        }
    } else {
        stats_->lastWidth = desc.Width;
        stats_->lastHeight = desc.Height;
        if (popupShown_) {
            // Kept, so the popup's own frames can be composed over it.
            if (EnsureTexture(viewCopy_, desc.Width, desc.Height)) {
                context_->CopyResource(viewCopy_.Get(), source.Get());
                viewValid_ = true;
                presented = Compose(viewCopy_.Get());
            }
        } else {
            presented = Compose(source.Get());
        }
    }
    const int64_t end = Qpc();
    if (presented) {
        ++stats_->presents;
        stats_->lastPresentQpc = static_cast<uint64_t>(end);
        if (const int64_t input = pendingInput_.exchange(0)) {
            stats_->inputToPresentTicksTotal += static_cast<uint64_t>(end - input);
            ++stats_->inputToPresentCount;
        }
    }
    const uint64_t took = static_cast<uint64_t>(end - start);
    stats_->copyTicksTotal += took;
    stats_->copyTicksMax = std::max(stats_->copyTicksMax, took);
    return presented;
}

bool OffscreenPresenter::DrawMasked(ID3D11Texture2D* target, ID3D11Texture2D* view, const D3D11_TEXTURE2D_DESC& desc) {
    // Chromium's pool textures can be sampled; anything that can't is copied first.
    ID3D11Texture2D* source = view;
    if (!(desc.BindFlags & D3D11_BIND_SHADER_RESOURCE)) {
        if (!EnsureTexture(viewCopy_, desc.Width, desc.Height)) return false;
        context_->CopyResource(viewCopy_.Get(), view);
        source = viewCopy_.Get();
    }
    ComPtr<ID3D11RenderTargetView> rtv;
    ComPtr<ID3D11ShaderResourceView> srv;
    D3D11_SHADER_RESOURCE_VIEW_DESC srvDesc{};
    srvDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    srvDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    srvDesc.Texture2D.MipLevels = 1;
    if (FAILED(device_->CreateRenderTargetView(target, nullptr, rtv.GetAddressOf())) ||
        FAILED(device_->CreateShaderResourceView(source, &srvDesc, srv.GetAddressOf()))) {
        return false;
    }
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context_->Map(card_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    const float constants[4] = {static_cast<float>(desc.Width), static_cast<float>(desc.Height), radius_.load(), 0};
    std::memcpy(mapped.pData, constants, sizeof constants);
    context_->Unmap(card_.Get(), 0);
    const D3D11_VIEWPORT viewport{0, 0, static_cast<float>(desc.Width), static_cast<float>(desc.Height), 0, 1};
    context_->OMSetRenderTargets(1, rtv.GetAddressOf(), nullptr);
    context_->RSSetViewports(1, &viewport);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->IASetInputLayout(nullptr);
    context_->VSSetShader(vertex_.Get(), nullptr, 0);
    context_->PSSetShader(pixel_.Get(), nullptr, 0);
    context_->PSSetShaderResources(0, 1, srv.GetAddressOf());
    context_->PSSetConstantBuffers(0, 1, card_.GetAddressOf());
    context_->Draw(3, 0);
    ID3D11ShaderResourceView* none = nullptr;
    context_->PSSetShaderResources(0, 1, &none);
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    return true;
}

void OffscreenPresenter::PopupShown(bool shown) {
    std::lock_guard lock(mutex_);
    if (shown) ++stats_->popupShows;
    popupShown_ = shown;
    viewValid_ = popupValid_ = false;
    // The view paints again: kept for the popup, or without it.
    needsView_ = true;
}

void OffscreenPresenter::PopupRect(const RECT& rect) {
    std::lock_guard lock(mutex_);
    popupRect_ = rect;
}

void OffscreenPresenter::RequestReadBack() {
    readBack_.reset();
    ResetEvent(readBackDone_);
    readBackWanted_ = true;
}

std::optional<Pixels> OffscreenPresenter::TakeReadBack(DWORD timeoutMs, std::wstring& error) {
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;
    for (;;) {
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;
        const DWORD woke = MsgWaitForMultipleObjectsEx(1, &readBackDone_, static_cast<DWORD>(deadline - now), QS_ALLINPUT, 0);
        if (woke == WAIT_OBJECT_0) {
            std::lock_guard lock(mutex_);
            if (!readBack_) error = L"the page's frame couldn't be read back";
            return std::move(readBack_);
        }
        if (woke != WAIT_OBJECT_0 + 1) break;
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    error = L"the page presented no frame in time";
    return std::nullopt;
}

void OffscreenPresenter::InputForwarded() {
    ++stats_->inputsForwarded;
    int64_t none = 0;
    pendingInput_.compare_exchange_strong(none, Qpc());
}

void RoundCorners(Pixels& pixels, float radius) {
    if (radius <= 0) return;
    const int w = static_cast<int>(pixels.width), h = static_cast<int>(pixels.height);
    const int r = static_cast<int>(std::ceil(radius));
    for (int y = 0; y < std::min(r, h); ++y) {
        for (int x = 0; x < std::min(r, w); ++x) {
            // Coverage of the pixel's centre by the quarter circle, a pixel wide ramp.
            const float dx = radius - (static_cast<float>(x) + 0.5f), dy = radius - (static_cast<float>(y) + 0.5f);
            const float coverage = std::clamp(radius - std::sqrt(dx * dx + dy * dy) + 0.5f, 0.0f, 1.0f);
            const int xs[2] = {x, w - 1 - x}, ys[2] = {y, h - 1 - y};
            for (int yi : ys) {
                for (int xi : xs) {
                    uint8_t* p = pixels.bgra.data() + (static_cast<size_t>(yi) * w + xi) * 4;
                    for (int c = 0; c < 4; ++c) p[c] = static_cast<uint8_t>(std::lround(p[c] * coverage));
                }
            }
        }
    }
}

}  // namespace kite
