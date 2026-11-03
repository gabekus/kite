// See Capture.h.

#include "shell/Capture.h"

#include <wincodec.h>

#include <vector>

namespace kite {
namespace {

#ifndef PW_RENDERFULLCONTENT
constexpr UINT PW_RENDERFULLCONTENT = 0x00000002;
#endif

template <typename T>
struct ComPtr {
    T* p = nullptr;
    ComPtr() = default;
    ComPtr(const ComPtr&) = delete;  // a copy would Release twice
    ComPtr& operator=(const ComPtr&) = delete;
    ~ComPtr() {
        if (p) p->Release();
    }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
};

std::wstring HResultText(const wchar_t* what, HRESULT hr) {
    wchar_t buffer[16];
    wsprintfW(buffer, L"0x%08X", static_cast<unsigned>(hr));
    return std::wstring(what) + L" failed (" + buffer + L")";
}

}  // namespace

std::wstring CaptureClientToPng(HWND hwnd, const std::filesystem::path& file) {
    RECT client{};
    GetClientRect(hwnd, &client);
    const int width = client.right - client.left;
    const int height = client.bottom - client.top;
    if (width <= 0 || height <= 0) return L"the window has no client area";

    // Render the whole window into a top-down 32bpp DIB, then crop to the client area.
    RECT window{};
    GetWindowRect(hwnd, &window);
    POINT origin{0, 0};
    ClientToScreen(hwnd, &origin);
    const int windowWidth = window.right - window.left;
    const int windowHeight = window.bottom - window.top;
    const int offsetX = origin.x - window.left;
    const int offsetY = origin.y - window.top;

    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = windowWidth;
    info.bmiHeader.biHeight = -windowHeight;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    void* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, screen);
    if (!memory || !bitmap) {
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        return L"couldn't allocate the capture bitmap";
    }
    HGDIOBJ previous = SelectObject(memory, bitmap);
    BOOL printed = PrintWindow(hwnd, memory, PW_RENDERFULLCONTENT);
    GdiFlush();

    // Copy the client rows out, forcing alpha opaque (GDI leaves it undefined).
    std::vector<BYTE> pixels(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
    const auto* source = static_cast<const BYTE*>(bits);
    for (int y = 0; y < height; ++y) {
        const BYTE* row = source + (static_cast<size_t>(y + offsetY) * windowWidth + offsetX) * 4;
        BYTE* out = pixels.data() + static_cast<size_t>(y) * width * 4;
        for (int x = 0; x < width; ++x) {
            out[x * 4 + 0] = row[x * 4 + 0];
            out[x * 4 + 1] = row[x * 4 + 1];
            out[x * 4 + 2] = row[x * 4 + 2];
            out[x * 4 + 3] = 0xFF;
        }
    }
    SelectObject(memory, previous);
    DeleteObject(bitmap);
    DeleteDC(memory);
    if (!printed) return L"PrintWindow failed";

    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    std::wstring error;
    {
        ComPtr<IWICImagingFactory> factory;
        ComPtr<IWICStream> stream;
        ComPtr<IWICBitmapEncoder> encoder;
        ComPtr<IWICBitmapFrameEncode> frame;
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
        if (FAILED(hr)) error = HResultText(L"WIC factory", hr);
        if (error.empty() && FAILED(hr = factory->CreateStream(&stream))) error = HResultText(L"CreateStream", hr);
        if (error.empty() && FAILED(hr = stream->InitializeFromFilename(file.c_str(), GENERIC_WRITE)))
            error = HResultText(L"opening the output file", hr);
        if (error.empty() && FAILED(hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)))
            error = HResultText(L"PNG encoder", hr);
        if (error.empty() && FAILED(hr = encoder->Initialize(stream.p, WICBitmapEncoderNoCache))) error = HResultText(L"encoder init", hr);
        if (error.empty() && FAILED(hr = encoder->CreateNewFrame(&frame, nullptr))) error = HResultText(L"CreateNewFrame", hr);
        if (error.empty() && FAILED(hr = frame->Initialize(nullptr))) error = HResultText(L"frame init", hr);
        if (error.empty() && FAILED(hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height))))
            error = HResultText(L"SetSize", hr);
        if (error.empty() && FAILED(hr = frame->SetPixelFormat(&format))) error = HResultText(L"SetPixelFormat", hr);
        if (error.empty() && format != GUID_WICPixelFormat32bppBGRA) error = L"PNG encoder refused 32bpp BGRA";
        if (error.empty() &&
            FAILED(hr = frame->WritePixels(static_cast<UINT>(height), static_cast<UINT>(width) * 4,
                                           static_cast<UINT>(pixels.size()), pixels.data())))
            error = HResultText(L"WritePixels", hr);
        if (error.empty() && FAILED(hr = frame->Commit())) error = HResultText(L"frame commit", hr);
        if (error.empty() && FAILED(hr = encoder->Commit())) error = HResultText(L"encoder commit", hr);
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return error;
}

}  // namespace kite
