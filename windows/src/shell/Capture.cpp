// See Capture.h.

#include "shell/Capture.h"

#include <wincodec.h>
#include <wrl/client.h>

#include "shell/Errors.h"

namespace kite {

std::wstring SavePng(const Pixels& pixels, const std::filesystem::path& file) {
    if (!pixels.width || !pixels.height || pixels.bgra.size() != static_cast<size_t>(pixels.width) * pixels.height * 4) {
        return L"no pixels to save";
    }
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    std::wstring error;
    {
        Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
        Microsoft::WRL::ComPtr<IWICStream> stream;
        Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
        Microsoft::WRL::ComPtr<IWICBitmapFrameEncode> frame;
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.GetAddressOf()));
        if (FAILED(hr)) error = HResultMessage(L"WIC factory", hr);
        if (error.empty() && FAILED(hr = factory->CreateStream(stream.GetAddressOf()))) error = HResultMessage(L"CreateStream", hr);
        if (error.empty() && FAILED(hr = stream->InitializeFromFilename(file.c_str(), GENERIC_WRITE)))
            error = HResultMessage(L"opening the output file", hr);
        if (error.empty() && FAILED(hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.GetAddressOf())))
            error = HResultMessage(L"PNG encoder", hr);
        if (error.empty() && FAILED(hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) error = HResultMessage(L"encoder init", hr);
        if (error.empty() && FAILED(hr = encoder->CreateNewFrame(frame.GetAddressOf(), nullptr))) error = HResultMessage(L"CreateNewFrame", hr);
        if (error.empty() && FAILED(hr = frame->Initialize(nullptr))) error = HResultMessage(L"frame init", hr);
        if (error.empty() && FAILED(hr = frame->SetSize(pixels.width, pixels.height)))
            error = HResultMessage(L"SetSize", hr);
        if (error.empty() && FAILED(hr = frame->SetPixelFormat(&format))) error = HResultMessage(L"SetPixelFormat", hr);
        if (error.empty() && format != GUID_WICPixelFormat32bppBGRA) error = L"PNG encoder refused 32bpp BGRA";
        if (error.empty() &&
            FAILED(hr = frame->WritePixels(pixels.height, pixels.width * 4, static_cast<UINT>(pixels.bgra.size()),
                                           const_cast<BYTE*>(pixels.bgra.data()))))
            error = HResultMessage(L"WritePixels", hr);
        if (error.empty() && FAILED(hr = frame->Commit())) error = HResultMessage(L"frame commit", hr);
        if (error.empty() && FAILED(hr = encoder->Commit())) error = HResultMessage(L"encoder commit", hr);
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return error;
}

void ComposeOver(Pixels& base, const Pixels& top, POINT origin) {
    for (UINT y = 0; y < top.height; ++y) {
        const LONG by = origin.y + static_cast<LONG>(y);
        if (by < 0 || by >= static_cast<LONG>(base.height)) continue;
        for (UINT x = 0; x < top.width; ++x) {
            const LONG bx = origin.x + static_cast<LONG>(x);
            if (bx < 0 || bx >= static_cast<LONG>(base.width)) continue;
            const uint8_t* src = &top.bgra[(static_cast<size_t>(y) * top.width + x) * 4];
            uint8_t* dst = &base.bgra[(static_cast<size_t>(by) * base.width + static_cast<size_t>(bx)) * 4];
            const unsigned keep = 255u - src[3];
            for (int c = 0; c < 4; ++c) dst[c] = static_cast<uint8_t>(src[c] + (dst[c] * keep + 127) / 255);
        }
    }
}

}  // namespace kite
