// See FadedLayer.h.

#include "shell/FadedLayer.h"

#include "shell/Errors.h"

namespace kite {

std::wstring DrawFadedLayer(Compositor& compositor, FadedLayer& layer, UINT width, UINT height, UINT dpi, const Compositor::Content& content,
                            bool readBack, HRESULT& hr, bool& fresh) {
    IDCompositionDevice* device = compositor.Device();
    if (!layer.visual) {
        fresh = true;
        if (FAILED(hr = device->CreateVisual(layer.visual.GetAddressOf())) || FAILED(hr = device->CreateEffectGroup(layer.effect.GetAddressOf())) ||
            FAILED(hr = layer.visual->SetEffect(layer.effect.Get()))) {
            layer = FadedLayer{};
            return HResultMessage(L"creating a layer's visual", hr);
        }
    }
    if (!layer.surface) {
        if (FAILED(hr = device->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                     layer.surface.GetAddressOf())) ||
            FAILED(hr = layer.visual->SetContent(layer.surface.Get()))) {
            layer.surface.Reset();
            return HResultMessage(L"creating a layer's surface", hr);
        }
    } else if ((width != layer.width || height != layer.height) && FAILED(hr = layer.surface->Resize(width, height))) {
        return HResultMessage(L"resizing a layer's surface", hr);
    }
    layer.width = width;
    layer.height = height;
    layer.pixels = Pixels{};
    return compositor.DrawSurface(layer.surface.Get(), width, height, dpi, content, readBack ? &layer.pixels : nullptr, hr);
}

}  // namespace kite
