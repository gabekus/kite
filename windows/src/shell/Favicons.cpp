// See Favicons.h.

#include "shell/Favicons.h"

#include "core/Sidebar.h"
#include "core/Url.h"
#include "shell/Text.h"

#include <d2d1_1.h>
#include <wincodec.h>
#include <winhttp.h>
#include <wrl/client.h>

// Direct2D's SVG renderer (Windows 10 1703 and later); the MinGW headers don't have it yet, so
// the cross-compile check builds without it (SVG icons show the globe there).
#if __has_include(<d2d1_3.h>)
#include <d2d1_3.h>
#define KITE_SVG_FAVICONS 1
#endif

#include <algorithm>
#include <cctype>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <string_view>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// Favicons are small; anything bigger isn't one (and isn't worth decoding on a hunch).
constexpr size_t kMaxBytes = 1 << 20;
// Name resolution, connect, send and the wait for the response each give up after this, and
// the whole fetch (a server can trickle its body) after kDeadlineMs.
constexpr int kTimeoutMs = 5'000;
constexpr ULONGLONG kDeadlineMs = 15'000;
// Fetches at once, so a dead host holds up only its own thread.
constexpr int kWorkers = 4;
// A frame bigger than this a side isn't decoded: a favicon's header can claim any size, and
// WIC decodes the whole frame before scaling it.
constexpr UINT kMaxFrameSide = 1024;
// The cache's bound: the Mac's NSCache keeps 500 icons; bytes bound what 500 can cost.
constexpr size_t kMaxEntries = 500;
constexpr size_t kMaxCacheBytes = 16 << 20;

struct Handle {
    HINTERNET value = nullptr;
    ~Handle() {
        if (value) WinHttpCloseHandle(value);
    }
};

// The icon's bytes (whatever the status, as URLSession's data(from:) returns them: an error
// page then fails to decode), or nothing on any failure.
std::optional<std::string> Fetch(HINTERNET session, const std::string& url) {
    if (url.size() > 5 && _strnicmp(url.c_str(), "data:", 5) == 0) {
        auto bytes = url::DataBytes(url);
        if (!bytes || bytes->size() > kMaxBytes) return std::nullopt;
        return bytes;
    }
    if (!session) return std::nullopt;
    const ULONGLONG deadline = GetTickCount64() + kDeadlineMs;
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
        // A server that trickles its body stops here: each read can wait kTimeoutMs, the
        // whole body kDeadlineMs.
        if (GetTickCount64() > deadline) return std::nullopt;
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

#if KITE_SVG_FAVICONS
// An SVG icon, as NSImage draws one on the Mac: fitted into side×side (its viewBox, else its
// width and height, else the square itself), centred, with Direct2D's SVG renderer into a WIC
// bitmap (software, on this thread). Direct2D draws SVG's static subset (no text or scripts).
std::optional<Pixels> RasterizeSvg(IWICImagingFactory* wic, ID2D1Factory1* d2d, const std::string& bytes, UINT side) {
    if (!d2d) return std::nullopt;
    ComPtr<IWICBitmap> bitmap;
    ComPtr<ID2D1RenderTarget> target;
    ComPtr<ID2D1DeviceContext5> context;
    ComPtr<IWICStream> stream;
    ComPtr<ID2D1SvgDocument> document;
    const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (FAILED(wic->CreateBitmap(side, side, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, bitmap.GetAddressOf())) ||
        FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), &props, target.GetAddressOf())) || FAILED(target.As(&context)) ||
        FAILED(wic->CreateStream(stream.GetAddressOf())) ||
        FAILED(stream->InitializeFromMemory(reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data())), static_cast<DWORD>(bytes.size()))) ||
        FAILED(context->CreateSvgDocument(stream.Get(), D2D1::SizeF(static_cast<float>(side), static_cast<float>(side)),
                                          document.GetAddressOf()))) {
        return std::nullopt;
    }
    // A root with a size but no viewBox draws at that size: give it one, so it fills the square.
    ComPtr<ID2D1SvgElement> root;
    document->GetRoot(root.GetAddressOf());
    if (root && !root->IsAttributeSpecified(L"viewBox")) {
        D2D1_SVG_LENGTH width{}, height{};
        if (SUCCEEDED(root->GetAttributeValue(L"width", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &width, sizeof(width))) &&
            SUCCEEDED(root->GetAttributeValue(L"height", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &height, sizeof(height))) &&
            width.units == D2D1_SVG_LENGTH_UNITS_NUMBER && height.units == D2D1_SVG_LENGTH_UNITS_NUMBER && width.value > 0 &&
            height.value > 0) {
            const D2D1_SVG_VIEWBOX box{0, 0, width.value, height.value};
            root->SetAttributeValue(L"viewBox", D2D1_SVG_ATTRIBUTE_POD_TYPE_VIEWBOX, &box, sizeof(box));
        }
    }
    if (root) {
        const D2D1_SVG_LENGTH full{100, D2D1_SVG_LENGTH_UNITS_PERCENTAGE};
        root->SetAttributeValue(L"width", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &full, sizeof(full));
        root->SetAttributeValue(L"height", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &full, sizeof(full));
    }
    context->BeginDraw();
    context->Clear(D2D1_COLOR_F{0, 0, 0, 0});
    context->DrawSvgDocument(document.Get());
    if (FAILED(context->EndDraw())) return std::nullopt;
    Pixels pixels;
    pixels.width = pixels.height = side;
    pixels.bgra.resize(static_cast<size_t>(side) * side * 4);
    if (FAILED(bitmap->CopyPixels(nullptr, side * 4, static_cast<UINT>(pixels.bgra.size()), pixels.bgra.data()))) return std::nullopt;
    return pixels;
}
#endif

// Decoded and scaled to side×side, stretched as the Mac's favicon view stretches its image.
// An .ico's frame is the smallest at least that big (else the biggest), as NSImage picks a
// representation for the size it draws at. Frames over kMaxFrameSide aren't considered.
std::optional<Pixels> Decode(IWICImagingFactory* wic, ID2D1Factory1* d2d, const std::string& bytes, UINT side) {
    if (LooksLikeSvg(bytes)) {
#if KITE_SVG_FAVICONS
        return RasterizeSvg(wic, d2d, bytes, side);
#else
        (void)d2d;
        return std::nullopt;
#endif
    }
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
        if (size > kMaxFrameSide) continue;
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

// A fetch (no bytes yet) or a decode at another size (the bytes from an earlier fetch).
struct Job {
    std::string url;
    UINT side = 0;
    std::shared_ptr<const std::string> bytes;
};
struct Result {
    std::string url;
    UINT side = 0;
    bool fetched = false;                       // this job fetched (rather than only decoded)
    std::shared_ptr<const std::string> bytes;   // null when the fetch failed
    std::optional<Pixels> pixels;               // null when it didn't decode
};

}  // namespace

struct Favicons::Shared {
    HWND window;
    UINT message;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Job> queue;
    std::deque<Result> done;
    int busy = 0;  // jobs a worker has taken and not yet finished
    bool stopping = false;
    bool posted = false;
};

namespace {

void Work(const std::shared_ptr<Favicons::Shared>& shared) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IWICImagingFactory> wic;
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf()));
    // For SVG icons; this thread's own.
    ComPtr<ID2D1Factory1> d2d;
    const D2D1_FACTORY_OPTIONS options{};
    D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options, reinterpret_cast<void**>(d2d.GetAddressOf()));
    // The system's proxy settings (automatic where Windows has it, 8.1 and later).
    Handle session{WinHttpOpen(L"Kite", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
    if (!session.value) {
        session.value = WinHttpOpen(L"Kite", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    }
    if (session.value) {
        WinHttpSetTimeouts(session.value, kTimeoutMs, kTimeoutMs, kTimeoutMs, kTimeoutMs);
        // Redirects count against the fetch's time like the rest (a /favicon.ico often moves).
        DWORD redirects = 3;
        WinHttpSetOption(session.value, WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS, &redirects, sizeof(redirects));
        DWORD decompress = WINHTTP_DECOMPRESSION_FLAG_ALL;
        WinHttpSetOption(session.value, WINHTTP_OPTION_DECOMPRESSION, &decompress, sizeof(decompress));
    }
    for (;;) {
        Job job;
        {
            std::unique_lock lock(shared->mutex);
            shared->wake.wait(lock, [&] { return shared->stopping || !shared->queue.empty(); });
            if (shared->stopping) break;
            job = std::move(shared->queue.front());
            shared->queue.pop_front();
            ++shared->busy;
        }
        Result result{job.url, job.side, !job.bytes, job.bytes, std::nullopt};
        if (!result.bytes) {
            if (auto bytes = Fetch(session.value, job.url); bytes && !bytes->empty()) {
                result.bytes = std::make_shared<const std::string>(std::move(*bytes));
            }
        }
        if (result.bytes && wic) result.pixels = Decode(wic.Get(), d2d.Get(), *result.bytes, job.side);
        std::lock_guard lock(shared->mutex);
        --shared->busy;
        if (shared->stopping) break;
        shared->done.push_back(std::move(result));
        // One wake for however many arrive before the window takes them.
        if (!shared->posted) shared->posted = PostMessageW(shared->window, shared->message, 0, 0) != FALSE;
    }
    d2d.Reset();
    wic.Reset();
    if (session.value) {
        WinHttpCloseHandle(session.value);
        session.value = nullptr;
    }
    if (SUCCEEDED(com)) CoUninitialize();
}

size_t Cost(const std::string& url, const std::shared_ptr<const std::string>& bytes, const std::map<UINT, Pixels>& sized) {
    size_t cost = url.size() + (bytes ? bytes->size() : 0);
    for (const auto& entry : sized) cost += entry.second.bgra.size();
    return cost;
}

}  // namespace

std::unique_ptr<Favicons> Favicons::Create(HWND window, UINT message) {
    auto shared = std::make_shared<Shared>();
    shared->window = window;
    shared->message = message;
    // Each worker holds the queue too, so it outlives this object if a fetch is still running
    // when the window closes.
    for (int i = 0; i < kWorkers; ++i) std::thread(Work, shared).detach();
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
    auto [found, added] = entries_.try_emplace(url);
    Entry& entry = found->second;
    entry.used = ++clock_;
    if (auto sized = entry.sized.find(side); sized != entry.sized.end()) return &sized->second;
    if (entry.failed || entry.fetching || entry.decoding.contains(side) || entry.failedSides.contains(side)) return nullptr;
    Job job{url, side, entry.bytes};
    if (entry.bytes) {
        entry.decoding.insert(side);
    } else {
        entry.fetching = true;
    }
    {
        std::lock_guard lock(shared_->mutex);
        shared_->queue.push_back(std::move(job));
    }
    shared_->wake.notify_one();
    if (added) Evict(url);
    return nullptr;
}

bool Favicons::Idle() const {
    std::lock_guard lock(shared_->mutex);
    return shared_->queue.empty() && shared_->busy == 0;
}

bool Favicons::Failed(const std::string& url) const {
    const auto found = entries_.find(url);
    return found != entries_.end() && found->second.failed;
}

bool Favicons::TakeResults() {
    std::deque<Result> done;
    {
        std::lock_guard lock(shared_->mutex);
        done.swap(shared_->done);
        shared_->posted = false;
    }
    bool arrived = false;
    for (Result& result : done) {
        auto found = entries_.find(result.url);
        if (found == entries_.end()) continue;  // dropped from the cache meanwhile
        Entry& entry = found->second;
        if (result.fetched) {
            entry.fetching = false;
            entry.bytes = result.bytes;
        }
        entry.decoding.erase(result.side);
        if (result.pixels) {
            entry.sized.insert_or_assign(result.side, std::move(*result.pixels));
            arrived = true;
        } else if (result.fetched || entry.sized.empty()) {
            // Not fetched or not an image: it stays the globe, and isn't asked for again this
            // run (the Mac's `missing`).
            entry.failed = true;
            entry.bytes.reset();
            entry.sized.clear();
        } else {
            // Only this size didn't decode: the others stay, and it isn't tried again.
            entry.failedSides.insert(result.side);
        }
    }
    if (!done.empty()) Evict({});
    return arrived;
}

// Drops the least recently shown icons until the cache is within its bounds, never `keep`
// (just asked for).
void Favicons::Evict(const std::string& keep) {
    size_t total = 0;
    for (const auto& [url, entry] : entries_) total += Cost(url, entry.bytes, entry.sized);
    while (entries_.size() > kMaxEntries || total > kMaxCacheBytes) {
        auto oldest = entries_.end();
        for (auto it = entries_.begin(); it != entries_.end(); ++it) {
            if (it->first != keep && (oldest == entries_.end() || it->second.used < oldest->second.used)) oldest = it;
        }
        if (oldest == entries_.end()) break;
        total -= Cost(oldest->first, oldest->second.bytes, oldest->second.sized);
        if (oldest->second.fetching || !oldest->second.decoding.empty()) {
            // Its queued work isn't wanted any more (a page that keeps changing its icon).
            std::lock_guard lock(shared_->mutex);
            std::erase_if(shared_->queue, [&](const Job& job) { return job.url == oldest->first; });
        }
        entries_.erase(oldest);
    }
}

}  // namespace kite
