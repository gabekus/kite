#pragma once
// A small DirectComposition visual with a surface of its own, faded by an effect group: what
// changes its opacity on the compositor without drawing (the space bar's icons and hover backing,
// the sidebar's top-row buttons). Its owner places the visual and sets the opacity.

#include <windows.h>  // first: the DirectX headers need its types

#include <dcomp.h>
#include <wrl/client.h>

#include <string>

#include "shell/Capture.h"
#include "shell/Compositor.h"

namespace kite {

struct FadedLayer {
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface;
    Microsoft::WRL::ComPtr<IDCompositionEffectGroup> effect;
    UINT width = 0, height = 0;  // the surface's, px
    Pixels pixels;               // its last draw, read back, for a capture
};

// Draws `content` (in points at `dpi`) into all of the layer's surface, `width` × `height` px: its
// visual, effect group and surface made the first time (`fresh` is set then: it needs a parent and
// an opacity), the surface resized for a new size. With `readBack` it keeps the drawing in `pixels`.
// Empty on success, else what failed (`hr`: whether the GPU went, IsDeviceLost).
std::wstring DrawFadedLayer(Compositor& compositor, perf::View view, FadedLayer& layer, UINT width, UINT height, UINT dpi, const Compositor::Content& content,
                            bool readBack, HRESULT& hr, bool& fresh);
// After DrawFadedLayer: a fresh layer's visual goes into `parent`, placed as AddVisual places it
// (`insertAbove` the `reference`, or with none, on top for FALSE and at the bottom for TRUE). A
// layer whose draw (`error`) or attach failed is dropped, to be made again by the next draw.
// `error`, or what the attach's failure was.
std::wstring AttachFadedLayer(FadedLayer& layer, bool fresh, std::wstring error, IDCompositionVisual* parent, BOOL insertAbove,
                              IDCompositionVisual* reference, HRESULT& hr);

}  // namespace kite
