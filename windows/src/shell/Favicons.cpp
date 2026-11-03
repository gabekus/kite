// See Favicons.h.

#include "shell/Favicons.h"

#include <wincodec.h>
#include <winhttp.h>
#include <wrl/client.h>

#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// Favicons are small; anything bigger isn't one (and isn't worth decoding on a hunch).
constexpr size_t kMaxBytes = 1 << 20;
// Name resolution, connect, send and receive: a dead host gives up in seconds.
constexpr int kTimeoutMs = 10'000;

std::wstring Widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(std::max(size, 0)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), size);
    return out;
}

struct Handle {
    HINTERNET value = nullptr;
    ~Handle() {
        if (value) WinHttpCloseHandle(value);
    }
};

// The icon's bytes (whatever the status, as URLSession's data(from:) returns them: an error
// page then fails to decode), or nothing on any failure.
std::optional<std::string> Fetch(HINTERNET session, const std::string& url) {
    std::wstring wide = Widen(url);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(wide.c_str(), static_cast<DWORD>(wide.size()), 0, &parts)) return std::nullopt;
    if (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) return std::nullopt;
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    if (path.empty()) path = L"/";
    Handle connection{WinHttpConnect(session, host.c_str(), parts.nPort, 0)};
    if (!connection.value) return std::nullopt;
    Handle request{WinHttpOpenRequest(connection.value, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                      parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)};
    if (!request.value || !WinHttpSendRequest(request.value, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request.value, nullptr)) {
        return std::nullopt;
    }
    std::string bytes;
    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request.value, &available)) return std::nullopt;
        if (available == 0) break;
        if (bytes.size() + available > kMaxBytes) return std::nullopt;
        const size_t at = bytes.size();
        bytes.resize(at + available);
        DWORD read = 0;
        if (!WinHttpReadData(request.value, bytes.data() + at, available, &read)) return std::nullopt;
        bytes.resize(at + read);
    }
    return bytes;
}

// Decoded and scaled to side×side, stretched as the Mac's favicon view stretches its image.
// An .ico's frame is the smallest at least that big (else the biggest), as NSImage picks a
// representation for the size it draws at.
std::optional<Pixels> Decode(IWICImagingFactory* wic, const std::string& bytes, UINT side) {
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(wic->CreateStream(stream.GetAddressOf())) ||
        FAILED(stream->InitializeFromMemory(reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data())), static_cast<DWORD>(bytes.size()))) ||
        FAILED(wic->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf()))) {
        return std::nullopt;
    }
    UINT frames = 0;
    if (FAILED(decoder->GetFrameCount(&frames)) || frames == 0) return std::nullopt;
    ComPtr<IWICBitmapFrameDecode> chosen;
    UINT chosenSide = 0;
    for (UINT i = 0; i < frames && i < 64; ++i) {
        ComPtr<IWICBitmapFrameDecode> frame;
        UINT w = 0, h = 0;
        if (FAILED(decoder->GetFrame(i, frame.GetAddressOf())) || FAILED(frame->GetSize(&w, &h)) || !w || !h) continue;
        const UINT size = std::max(w, h);
        const bool better = !chosen || (chosenSide < side ? size > chosenSide : size >= side && size < chosenSide);
        if (better) {
            chosen = frame;
            chosenSide = size;
        }
    }
    if (!chosen) return std::nullopt;
    ComPtr<IWICFormatConverter> converter;
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(wic->CreateFormatConverter(converter.GetAddressOf())) ||
        FAILED(converter->Initialize(chosen.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeMedianCut)) ||
        FAILED(wic->CreateBitmapScaler(scaler.GetAddressOf()))) {
        return std::nullopt;
    }
    // High-quality cubic where there is one (Windows 10; 4 in the SDK's enum, which MinGW's
    // headers don't have yet), Fant before.
    constexpr auto kHighQualityCubic = static_cast<WICBitmapInterpolationMode>(4);
    if (FAILED(scaler->Initialize(converter.Get(), side, side, kHighQualityCubic)) &&
        FAILED(scaler->Initialize(converter.Get(), side, side, WICBitmapInterpolationModeFant))) {
        return std::nullopt;
    }
    Pixels pixels;
    pixels.width = pixels.height = side;
    pixels.bgra.resize(static_cast<size_t>(side) * side * 4);
    if (FAILED(scaler->CopyPixels(nullptr, side * 4, static_cast<UINT>(pixels.bgra.size()), pixels.bgra.data()))) return std::nullopt;
    return pixels;
}

}  // namespace

struct Favicons::Shared {
    HWND window;
    UINT message;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Key> queue;
    std::deque<std::pair<Key, std::optional<Pixels>>> done;
    bool stopping = false;
    bool posted = false;
};

std::unique_ptr<Favicons> Favicons::Create(HWND window, UINT message) {
    auto shared = std::make_shared<Shared>();
    shared->window = window;
    shared->message = message;
    // The worker holds the queue too, so it outlives this object if a fetch is still running
    // when the window closes.
    std::thread([shared] {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        ComPtr<IWICImagingFactory> wic;
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()));
        // The system's proxy settings (automatic where Windows has it, 8.1 and later).
        Handle session{WinHttpOpen(L"Kite", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
        if (!session.value) {
            session.value = WinHttpOpen(L"Kite", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        }
        if (session.value) {
            WinHttpSetTimeouts(session.value, kTimeoutMs, kTimeoutMs, kTimeoutMs, kTimeoutMs);
            DWORD decompress = WINHTTP_DECOMPRESSION_FLAG_ALL;
            WinHttpSetOption(session.value, WINHTTP_OPTION_DECOMPRESSION, &decompress, sizeof(decompress));
        }
        for (;;) {
            Key key;
            {
                std::unique_lock lock(shared->mutex);
                shared->wake.wait(lock, [&] { return shared->stopping || !shared->queue.empty(); });
                if (shared->stopping) break;
                key = std::move(shared->queue.front());
                shared->queue.pop_front();
            }
            std::optional<Pixels> pixels;
            if (session.value && wic) {
                if (auto bytes = Fetch(session.value, key.first); bytes && !bytes->empty()) pixels = Decode(wic.Get(), *bytes, key.second);
            }
            std::lock_guard lock(shared->mutex);
            if (shared->stopping) break;
            shared->done.emplace_back(std::move(key), std::move(pixels));
            // One wake for however many arrive before the window takes them.
            if (!shared->posted) shared->posted = PostMessageW(shared->window, shared->message, 0, 0) != FALSE;
        }
        wic.Reset();
        if (SUCCEEDED(com)) CoUninitialize();
    }).detach();
    return std::unique_ptr<Favicons>(new Favicons(std::move(shared)));
}

Favicons::~Favicons() {
    {
        std::lock_guard lock(shared_->mutex);
        shared_->stopping = true;
        shared_->queue.clear();
    }
    shared_->wake.notify_all();
}

const Pixels* Favicons::Get(const std::string& url, UINT side) {
    const Key key{url, side};
    if (auto found = icons_.find(key); found != icons_.end()) return &found->second;
    if (asked_.insert(key).second) {
        {
            std::lock_guard lock(shared_->mutex);
            shared_->queue.push_back(key);
        }
        shared_->wake.notify_one();
    }
    return nullptr;
}

bool Favicons::TakeResults() {
    std::deque<std::pair<Key, std::optional<Pixels>>> done;
    {
        std::lock_guard lock(shared_->mutex);
        done.swap(shared_->done);
        shared_->posted = false;
    }
    bool arrived = false;
    for (auto& [key, pixels] : done) {
        // A failure stays in asked_, so it isn't fetched again this run.
        if (pixels) {
            icons_.insert_or_assign(key, std::move(*pixels));
            arrived = true;
        }
    }
    return arrived;
}

}  // namespace kite
