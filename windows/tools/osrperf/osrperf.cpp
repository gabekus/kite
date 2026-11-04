// osrperf: the W10 spike's measurement tool (docs/windows-osr-spike.md). Not part of Kite's
// build and never shipped; a stand-in until P0b's kiteperf. It launches Kite.exe on a test
// profile without activating it, then measures one page, windowed or --osr:
//
//   cpu       10 s with nothing watching: CPU ms/s of Kite.exe and each Chromium helper (by
//             --type), GPU engine running time per process and dedicated GPU memory per
//             process (PDH), the system's CPU load, and --osr's own counters.
//   cadence   10 s of Windows.Graphics.Capture on Kite's window: every frame DWM composes
//             with a change in it, with its QPC time; the same for both modes, since a
//             windowed page's presents are Chromium's GPU process's and not visible to Kite.
//   latency   N times: a posted WM_MOUSEMOVE (to the page's Chromium window, or to Kite's
//             window with --osr, which forwards it with SendMouseMoveEvent), then the first
//             captured frame in which the page's block changed colour. No real input.
//   shot      one captured frame as a PNG: the window as DWM shows it, page included.
//   minimize  (--minimize) 5 s more of cpu with the window minimized: the page should draw nothing.
//
//   osrperf measure <Kite.exe> <profile> <out.json> [--osr] [--seconds 10] [--latency 40]
//                   [--shot file.png] [--top] [--minimize]
//   osrperf launch <Kite.exe> <profile> [Kite's arguments...]   (waits for it to exit)
//   osrperf dcomp4   whether IDCompositionTexture is there, per adapter
//
// Build: cmake -S windows/tools/osrperf -B windows/tools/osrperf/build -A x64
//        cmake --build windows/tools/osrperf/build --config Release

#include <windows.h>

#include <d3d11.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <tlhelp32.h>
#include <wincodec.h>
#include <winternl.h>
#include <wrl/client.h>

#include <Windows.Graphics.Capture.Interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wdx = winrt::Windows::Graphics::DirectX;

namespace {

// Kite's OffscreenStats (windows/src/shell/OffscreenPage.h), read from its mapping.
struct OffscreenStats {
    uint64_t version, qpcFrequency, viewPaints, popupPaints, ignoredPaints, presents, openFailures, copyTicksTotal, copyTicksMax,
        inputsForwarded, inputToPresentTicksTotal, inputToPresentCount, popupShows, cursorChanges, imeRangeChanges, resizes, hides,
        lastWidth, lastHeight, lastPresentQpc, lastCursorType;
};

int64_t Qpc() {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart;
}
double QpcFrequency() {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return static_cast<double>(f.QuadPart);
}
void Sleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

std::string Narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}

// MARK: Processes

std::wstring CommandLineOf(DWORD pid) {
    using Query = NTSTATUS(NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
    static const auto query = reinterpret_cast<Query>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess"));
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h || !query) return {};
    std::vector<uint8_t> buffer(8192);
    ULONG needed = 0;
    std::wstring out;
    if (query(h, 60 /* ProcessCommandLineInformation */, buffer.data(), static_cast<ULONG>(buffer.size()), &needed) >= 0) {
        const auto* text = reinterpret_cast<const UNICODE_STRING*>(buffer.data());
        out.assign(text->Buffer, text->Length / sizeof(wchar_t));
    }
    CloseHandle(h);
    return out;
}

struct Proc {
    DWORD pid = 0;
    std::string role;  // browser, gpu-process, renderer, utility, ...
};

std::vector<Proc> KiteTree(DWORD root) {
    std::vector<Proc> out{{root, "browser"}};
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W e{sizeof(e)};
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
        if (e.th32ParentProcessID != root) continue;
        const std::wstring cl = CommandLineOf(e.th32ProcessID);
        std::string role = "other";
        const size_t at = cl.find(L"--type=");
        if (at != std::wstring::npos) {
            const size_t end = cl.find(L' ', at);
            role = Narrow(cl.substr(at + 7, end == std::wstring::npos ? std::wstring::npos : end - at - 7));
            if (role == "utility") {
                const size_t sub = cl.find(L"--utility-sub-type=");
                if (sub != std::wstring::npos) {
                    const size_t send = cl.find(L' ', sub);
                    role += ":" + Narrow(cl.substr(sub + 19, send == std::wstring::npos ? std::wstring::npos : send - sub - 19));
                }
            }
        }
        out.push_back({e.th32ProcessID, role});
    }
    // DWM composes every window: what a page costs it shows here (shared with the rest of the desktop).
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
        if (_wcsicmp(e.szExeFile, L"dwm.exe") == 0) out.push_back({e.th32ProcessID, "dwm"});
    }
    CloseHandle(snap);
    return out;
}

uint64_t CpuTime100ns(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    FILETIME c, x, k, u;
    uint64_t t = 0;
    if (GetProcessTimes(h, &c, &x, &k, &u)) {
        t = (static_cast<uint64_t>(k.dwHighDateTime) << 32 | k.dwLowDateTime) + (static_cast<uint64_t>(u.dwHighDateTime) << 32 | u.dwLowDateTime);
    }
    CloseHandle(h);
    return t;
}

struct SystemTimes {
    uint64_t idle = 0, total = 0;
};
SystemTimes System() {
    FILETIME i, k, u;
    GetSystemTimes(&i, &k, &u);
    auto v = [](FILETIME f) { return static_cast<uint64_t>(f.dwHighDateTime) << 32 | f.dwLowDateTime; };
    return {v(i), v(k) + v(u)};  // kernel includes idle
}

// MARK: PDH (GPU memory and engine time per process)

struct GpuSample {
    std::map<DWORD, double> dedicatedBytes;     // per pid
    std::map<DWORD, uint64_t> runningTime100ns; // per pid, every engine
    std::map<DWORD, std::string> luid;          // per pid, the adapter most of its dedicated memory is on
    std::map<DWORD, double> luidBytes;
};

DWORD PidOfInstance(const wchar_t* name) {
    // "pid_1234_luid_0x00000000_0x0000D1C3_phys_0..."
    if (wcsncmp(name, L"pid_", 4) != 0) return 0;
    return static_cast<DWORD>(wcstoul(name + 4, nullptr, 10));
}

class Gpu {
public:
    Gpu() {
        PdhOpenQueryW(nullptr, 0, &query_);
        PdhAddEnglishCounterW(query_, L"\\GPU Process Memory(*)\\Dedicated Usage", 0, &memory_);
        PdhAddEnglishCounterW(query_, L"\\GPU Engine(*)\\Running Time", 0, &engine_);
    }
    ~Gpu() { PdhCloseQuery(query_); }
    GpuSample Sample() {
        GpuSample s;
        PdhCollectQueryData(query_);
        DWORD bytes = 0, count = 0;
        if (PdhGetRawCounterArrayW(memory_, &bytes, &count, nullptr) == PDH_MORE_DATA) {
            std::vector<uint8_t> buf(bytes);
            auto* items = reinterpret_cast<PDH_RAW_COUNTER_ITEM_W*>(buf.data());
            if (PdhGetRawCounterArrayW(memory_, &bytes, &count, items) == ERROR_SUCCESS) {
                for (DWORD i = 0; i < count; ++i) {
                    if (DWORD pid = PidOfInstance(items[i].szName)) {
                        const double value = static_cast<double>(items[i].RawValue.FirstValue);
                        s.dedicatedBytes[pid] += value;
                        // The adapter holding most of its memory is the one it renders on.
                        const std::wstring name = items[i].szName;
                        const size_t l = name.find(L"luid_");
                        if (l != std::wstring::npos && value > s.luidBytes[pid]) {
                            s.luidBytes[pid] = value;
                            s.luid[pid] = Narrow(name.substr(l + 5, 21));
                        }
                    }
                }
            }
        }
        bytes = count = 0;
        if (PdhGetRawCounterArrayW(engine_, &bytes, &count, nullptr) == PDH_MORE_DATA) {
            std::vector<uint8_t> buf(bytes);
            auto* items = reinterpret_cast<PDH_RAW_COUNTER_ITEM_W*>(buf.data());
            if (PdhGetRawCounterArrayW(engine_, &bytes, &count, items) == ERROR_SUCCESS) {
                for (DWORD i = 0; i < count; ++i) {
                    const DWORD pid = PidOfInstance(items[i].szName);
                    if (!pid) continue;
                    s.runningTime100ns[pid] += static_cast<uint64_t>(items[i].RawValue.FirstValue);
                }
            }
        }
        return s;
    }

private:
    PDH_HQUERY query_ = nullptr;
    PDH_HCOUNTER memory_ = nullptr, engine_ = nullptr;
};

// MARK: Windows

HWND KiteWindow(DWORD pid) {
    struct Find {
        DWORD pid;
        HWND found;
    } find{pid, nullptr};
    EnumWindows(
        [](HWND h, LPARAM l) -> BOOL {
            auto* f = reinterpret_cast<Find*>(l);
            DWORD owner = 0;
            GetWindowThreadProcessId(h, &owner);
            wchar_t cls[64] = {};
            GetClassNameW(h, cls, 64);
            if (owner == f->pid && wcscmp(cls, L"KiteBrowserWindow") == 0 && IsWindowVisible(h)) {
                f->found = h;
                return FALSE;
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&find));
    return find.found;
}

// The deepest visible child window at a client point of `top` (a windowed page's Chromium
// window), and the point in its client coordinates.
HWND DeepestChild(HWND top, POINT& pt) {
    HWND at = top;
    for (;;) {
        HWND child = ChildWindowFromPointEx(at, pt, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT);
        if (!child || child == at) return at;
        MapWindowPoints(at, child, &pt, 1);
        at = child;
    }
}

// MARK: Capture (Windows.Graphics.Capture)

struct Frame {
    int64_t time100ns;  // SystemRelativeTime: QPC-based
    uint32_t bgra;      // the probe pixel, when probing
};

class Capturer {
public:
    explicit Capturer(HWND window) {
        D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
                          device_.GetAddressOf(), nullptr, context_.GetAddressOf());
        ComPtr<IDXGIDevice> dxgi;
        device_.As(&dxgi);
        winrt::com_ptr<::IInspectable> inspectable;
        CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put());
        winrtDevice_ = inspectable.as<wdx::Direct3D11::IDirect3DDevice>();
        auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        winrt::check_hresult(interop->CreateForWindow(window, winrt::guid_of<wgc::GraphicsCaptureItem>(),
                                                      winrt::put_abi(item_)));
        pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(winrtDevice_, wdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 3,
                                                                     item_.Size());
        session_ = pool_.CreateCaptureSession(item_);
        try {
            session_.IsCursorCaptureEnabled(false);
            // Every composed frame, not at most 60 a second (the default caps it there).
            session_.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan{10'000});
        } catch (...) {
        }
        pool_.FrameArrived([this](const wgc::Direct3D11CaptureFramePool& pool, const winrt::Windows::Foundation::IInspectable&) {
            auto frame = pool.TryGetNextFrame();
            if (!frame) return;
            OnFrame(frame);
        });
    }
    ~Capturer() {
        try {
            session_.Close();
            pool_.Close();
        } catch (...) {
        }
    }
    void Start() { session_.StartCapture(); }
    void SetProbe(std::optional<POINT> probe) {
        std::lock_guard lock(mutex_);
        probe_ = probe;
    }
    void WantShot() { wantShot_ = true; }
    void WantFind() { wantFind_ = true; }
    std::vector<Frame> Take() {
        std::lock_guard lock(mutex_);
        return std::exchange(frames_, {});
    }
    // Waits for a probed frame whose pixel differs from `from` (by more than a little).
    std::optional<Frame> WaitForChange(uint32_t from, int timeoutMs) {
        std::unique_lock lock(mutex_);
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        for (;;) {
            for (const Frame& f : frames_) {
                if (Differs(f.bgra, from)) return f;
            }
            frames_.clear();
            if (cv_.wait_until(lock, until) == std::cv_status::timeout) return std::nullopt;
        }
    }
    uint32_t LastProbe() {
        std::lock_guard lock(mutex_);
        return lastProbe_;
    }
    bool Found(POINT& at, SIZE& size) {
        std::lock_guard lock(mutex_);
        if (!found_) return false;
        at = *found_;
        size = frameSize_;
        return true;
    }
    std::vector<uint8_t> Shot(UINT& w, UINT& h) {
        std::lock_guard lock(mutex_);
        w = shotW_;
        h = shotH_;
        return shot_;
    }
    static bool Differs(uint32_t a, uint32_t b) {
        int d = 0;
        for (int i = 0; i < 3; ++i) d += std::abs(static_cast<int>((a >> (8 * i)) & 255) - static_cast<int>((b >> (8 * i)) & 255));
        return d > 60;
    }

private:
    void OnFrame(const wgc::Direct3D11CaptureFrame& frame) {
        const int64_t t = frame.SystemRelativeTime().count();
        auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        ComPtr<ID3D11Texture2D> texture;
        access->GetInterface(IID_PPV_ARGS(texture.GetAddressOf()));
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        std::optional<POINT> probe;
        {
            std::lock_guard lock(mutex_);
            probe = probe_;
            frameSize_ = SIZE{static_cast<LONG>(desc.Width), static_cast<LONG>(desc.Height)};
        }
        uint32_t pixel = 0;
        const bool whole = wantShot_.exchange(false) | wantFind_.load();
        if (whole) {
            std::vector<uint8_t> rows;
            ReadBack(texture.Get(), desc, nullptr, rows);
            if (wantFind_.exchange(false)) {
                // The block: the first pure-green pixel, then its centre.
                for (UINT y = 0; y < desc.Height; ++y) {
                    bool done = false;
                    for (UINT x = 0; x < desc.Width; ++x) {
                        const uint8_t* p = &rows[(static_cast<size_t>(y) * desc.Width + x) * 4];
                        if (p[1] > 200 && p[0] < 60 && p[2] < 60) {
                            std::lock_guard lock(mutex_);
                            found_ = POINT{static_cast<LONG>(x), static_cast<LONG>(y)};
                            done = true;
                            break;
                        }
                    }
                    if (done) break;
                }
            }
            std::lock_guard lock(mutex_);
            shot_ = std::move(rows);
            shotW_ = desc.Width;
            shotH_ = desc.Height;
        }
        if (probe && probe->x < static_cast<LONG>(desc.Width) && probe->y < static_cast<LONG>(desc.Height)) {
            D3D11_BOX box{static_cast<UINT>(probe->x), static_cast<UINT>(probe->y), 0, static_cast<UINT>(probe->x) + 1,
                          static_cast<UINT>(probe->y) + 1, 1};
            std::vector<uint8_t> px;
            ReadBack(texture.Get(), desc, &box, px);
            if (px.size() >= 4) pixel = px[0] | px[1] << 8 | px[2] << 16 | 0xFF000000u;
        }
        {
            std::lock_guard lock(mutex_);
            frames_.push_back({t, pixel});
            if (probe) lastProbe_ = pixel;
        }
        cv_.notify_all();
    }
    void ReadBack(ID3D11Texture2D* texture, const D3D11_TEXTURE2D_DESC& desc, const D3D11_BOX* box, std::vector<uint8_t>& out) {
        D3D11_TEXTURE2D_DESC s = desc;
        s.Width = box ? 1 : desc.Width;
        s.Height = box ? 1 : desc.Height;
        s.Usage = D3D11_USAGE_STAGING;
        s.BindFlags = 0;
        s.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        s.MiscFlags = 0;
        ComPtr<ID3D11Texture2D> staging;
        if (FAILED(device_->CreateTexture2D(&s, nullptr, staging.GetAddressOf()))) return;
        if (box) context_->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, texture, 0, box);
        else context_->CopyResource(staging.Get(), texture);
        D3D11_MAPPED_SUBRESOURCE m{};
        if (FAILED(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m))) return;
        out.resize(static_cast<size_t>(s.Width) * s.Height * 4);
        for (UINT y = 0; y < s.Height; ++y) memcpy(&out[static_cast<size_t>(y) * s.Width * 4], static_cast<uint8_t*>(m.pData) + y * m.RowPitch, s.Width * 4);
        context_->Unmap(staging.Get(), 0);
    }

    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    wdx::Direct3D11::IDirect3DDevice winrtDevice_{nullptr};
    wgc::GraphicsCaptureItem item_{nullptr};
    wgc::Direct3D11CaptureFramePool pool_{nullptr};
    wgc::GraphicsCaptureSession session_{nullptr};
    std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<Frame> frames_;
    std::optional<POINT> probe_;
    uint32_t lastProbe_ = 0;
    std::atomic<bool> wantShot_{false}, wantFind_{false};
    std::optional<POINT> found_;
    SIZE frameSize_{};
    std::vector<uint8_t> shot_;
    UINT shotW_ = 0, shotH_ = 0;
};

bool SavePng(const std::wstring& path, const std::vector<uint8_t>& bgra, UINT w, UINT h) {
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.GetAddressOf())))) return false;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    std::vector<uint8_t> opaque = bgra;
    for (size_t i = 3; i < opaque.size(); i += 4) opaque[i] = 255;
    return SUCCEEDED(factory->CreateStream(stream.GetAddressOf())) && SUCCEEDED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) &&
           SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.GetAddressOf())) &&
           SUCCEEDED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) &&
           SUCCEEDED(encoder->CreateNewFrame(frame.GetAddressOf(), nullptr)) && SUCCEEDED(frame->Initialize(nullptr)) &&
           SUCCEEDED(frame->SetSize(w, h)) && SUCCEEDED(frame->SetPixelFormat(&format)) &&
           SUCCEEDED(frame->WritePixels(h, w * 4, static_cast<UINT>(opaque.size()), opaque.data())) && SUCCEEDED(frame->Commit()) &&
           SUCCEEDED(encoder->Commit());
}

// MARK: Launch

struct Launched {
    PROCESS_INFORMATION pi{};
    bool ok = false;
};

Launched Launch(const std::wstring& kite, const std::wstring& profile, const std::wstring& args) {
    SetEnvironmentVariableW(L"KITE_SUPPORT_PATH", profile.c_str());
    STARTUPINFOW si{sizeof(si)};
    // Shown without activating: the test never takes the foreground or the keyboard.
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_SHOWNOACTIVATE;
    std::wstring command = L"\"" + kite + L"\" " + args;
    Launched l;
    l.ok = CreateProcessW(kite.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &l.pi) != FALSE;
    return l;
}

void CloseKite(Launched& l, HWND window) {
    if (window) PostMessageW(window, WM_CLOSE, 0, 0);
    if (WaitForSingleObject(l.pi.hProcess, 25'000) != WAIT_OBJECT_0) {
        for (const Proc& p : KiteTree(l.pi.dwProcessId)) {
            if (p.role == "dwm") continue;  // listed for measuring only, never ours to end
            if (HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, p.pid)) {
                TerminateProcess(h, 9);
                CloseHandle(h);
            }
        }
        fprintf(stderr, "osrperf: Kite didn't close in 25 s; terminated\n");
    }
    CloseHandle(l.pi.hThread);
    CloseHandle(l.pi.hProcess);
}

HWND WaitForWindow(DWORD pid, int timeoutMs) {
    for (int t = 0; t < timeoutMs; t += 100) {
        if (HWND h = KiteWindow(pid)) return h;
        Sleep(100);
    }
    return nullptr;
}

const OffscreenStats* MapStats(DWORD pid, HANDLE& mapping) {
    const std::wstring name = L"Local\\KiteOsrSpike-" + std::to_wstring(pid);
    mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
    if (!mapping) return nullptr;
    return static_cast<const OffscreenStats*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(OffscreenStats)));
}

std::string Percentiles(std::vector<double> v) {
    if (v.empty()) return "null";
    std::sort(v.begin(), v.end());
    auto at = [&](double q) { return v[std::min(v.size() - 1, static_cast<size_t>(q * (v.size() - 1) + 0.5))]; };
    double sum = 0;
    for (double x : v) sum += x;
    char buf[256];
    snprintf(buf, sizeof buf, "{\"n\":%zu,\"mean\":%.3f,\"p50\":%.3f,\"p90\":%.3f,\"p99\":%.3f,\"min\":%.3f,\"max\":%.3f}", v.size(),
             sum / v.size(), at(0.5), at(0.9), at(0.99), v.front(), v.back());
    return buf;
}

int Measure(int argc, wchar_t** argv) {
    if (argc < 5) return 1;
    const std::wstring kite = argv[2], profile = argv[3], out = argv[4];
    bool osr = false, top = false, minimize = false;
    int seconds = 10, latencyN = 40;
    std::wstring shot;
    for (int i = 5; i < argc; ++i) {
        const std::wstring a = argv[i];
        if (a == L"--osr") osr = true;
        else if (a == L"--top") top = true;
        else if (a == L"--minimize") minimize = true;
        else if (a == L"--seconds" && i + 1 < argc) seconds = _wtoi(argv[++i]);
        else if (a == L"--latency" && i + 1 < argc) latencyN = _wtoi(argv[++i]);
        else if (a == L"--shot" && i + 1 < argc) shot = argv[++i];
    }
    const double freq = QpcFrequency();
    Launched kiteProcess = Launch(kite, profile, std::wstring(L"--window-size 1280,820") + (osr ? L" --osr" : L""));
    if (!kiteProcess.ok) {
        fprintf(stderr, "osrperf: couldn't start Kite\n");
        return 2;
    }
    const DWORD pid = kiteProcess.pi.dwProcessId;
    HWND window = WaitForWindow(pid, 20'000);
    if (!window) {
        CloseKite(kiteProcess, nullptr);
        fprintf(stderr, "osrperf: no Kite window\n");
        return 3;
    }
    // Out of the way: behind every other window (or on top, still inactive, with --top).
    SetWindowPos(window, top ? HWND_TOP : HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    HANDLE mapping = nullptr;
    const OffscreenStats* stats = nullptr;
    // Ready: the page's first frame (--osr's counter, or a page window with a widget), then settle.
    for (int t = 0; t < 30'000; t += 100) {
        if (osr) {
            if (!stats) stats = MapStats(pid, mapping);
            if (stats && stats->presents > 0) break;
        } else {
            RECT c{};
            GetClientRect(window, &c);
            POINT p{c.right / 2 + 120, c.bottom / 2};
            if (DeepestChild(window, p) != window) break;
        }
        Sleep(100);
    }
    Sleep(4000);

    std::ostringstream json;
    json << "{\"mode\":\"" << (osr ? "osr" : "windowed") << "\",\"seconds\":" << seconds;

    // cpu: nothing watching.
    auto sample = [&](int secs, std::ostringstream& o) {
        std::vector<Proc> procs = KiteTree(pid);
        std::map<DWORD, uint64_t> cpu0;
        for (const Proc& p : procs) cpu0[p.pid] = CpuTime100ns(p.pid);
        Gpu gpu;
        const GpuSample g0 = gpu.Sample();
        const SystemTimes s0 = System();
        OffscreenStats st0{};
        if (stats) st0 = *stats;
        const int64_t q0 = Qpc();
        Sleep(secs * 1000);
        const int64_t q1 = Qpc();
        const SystemTimes s1 = System();
        const GpuSample g1 = gpu.Sample();
        OffscreenStats st1{};
        if (stats) st1 = *stats;
        const double wall = (q1 - q0) / freq;
        const double sysBusy = 100.0 * (1.0 - static_cast<double>(s1.idle - s0.idle) / static_cast<double>(s1.total - s0.total));
        o << ",\"systemCpuPercent\":" << sysBusy << ",\"processes\":[";
        bool first = true;
        for (const Proc& p : procs) {
            const double cpuMs = static_cast<double>(CpuTime100ns(p.pid) - cpu0[p.pid]) / 1e4 / wall;
            const auto rt0 = g0.runningTime100ns.count(p.pid) ? g0.runningTime100ns.at(p.pid) : 0;
            const auto rt1 = g1.runningTime100ns.count(p.pid) ? g1.runningTime100ns.at(p.pid) : 0;
            const double gpuMs = static_cast<double>(rt1 - rt0) / 1e4 / wall;
            const double mem = g1.dedicatedBytes.count(p.pid) ? g1.dedicatedBytes.at(p.pid) / 1048576.0 : 0;
            o << (first ? "" : ",") << "{\"pid\":" << p.pid << ",\"role\":\"" << p.role << "\",\"cpuMsPerS\":" << cpuMs
                 << ",\"gpuEngineMsPerS\":" << gpuMs << ",\"gpuDedicatedMB\":" << mem << ",\"luid\":\""
                 << (g1.luid.count(p.pid) ? g1.luid.at(p.pid) : "") << "\"}";
            first = false;
        }
        o << "]";
        if (stats) {
            const double presents = static_cast<double>(st1.presents - st0.presents);
            o << ",\"osr\":{\"presentsPerS\":" << presents / wall << ",\"viewPaintsPerS\":" << (st1.viewPaints - st0.viewPaints) / wall
                 << ",\"ignoredPaints\":" << (st1.ignoredPaints - st0.ignoredPaints)
                 << ",\"copyPresentMsMean\":" << (presents > 0 ? (st1.copyTicksTotal - st0.copyTicksTotal) / freq * 1000 / presents : 0)
                 << ",\"copyPresentMsMax\":" << st1.copyTicksMax / freq * 1000 << ",\"openFailures\":" << st1.openFailures
                 << ",\"texture\":[" << st1.lastWidth << "," << st1.lastHeight << "]}";
        }
    };
    sample(seconds, json);

    if (!IsWindow(window)) {
        fprintf(stderr, "osrperf: Kite's window went away (Kite exited)\n");
        CloseKite(kiteProcess, nullptr);
        return 5;
    }
    // cadence (and the shot).
    try {
        Capturer capture(window);
        capture.WantShot();
        capture.WantFind();  // the first frame always comes: find the block in it
        capture.Start();
        Sleep(300);
        capture.Take();  // the first frame always comes; count from here
        const int64_t q0 = Qpc();
        Sleep(seconds * 1000);
        const int64_t q1 = Qpc();
        std::vector<Frame> frames = capture.Take();
        std::vector<double> gaps;
        for (size_t i = 1; i < frames.size(); ++i) gaps.push_back((frames[i].time100ns - frames[i - 1].time100ns) / 1e4);
        json << ",\"cadence\":{\"frames\":" << frames.size() << ",\"fps\":" << frames.size() / ((q1 - q0) / freq)
             << ",\"intervalMs\":" << Percentiles(gaps) << "}";
        if (!shot.empty()) {
            UINT w = 0, h = 0;
            const std::vector<uint8_t> pixels = capture.Shot(w, h);
            if (!pixels.empty()) SavePng(shot, pixels, w, h);
        }

        // latency: the pages' grey block changes colour on each mousemove; a green marker finds it.
        if (latencyN > 0) {
            POINT blockInFrame{};
            SIZE frameSize{};
            for (int t = 0; t < 3000 && !capture.Found(blockInFrame, frameSize); t += 50) Sleep(50);
            if (capture.Found(blockInFrame, frameSize)) {
                // The frame is the window's visible bounds; map the block into client coordinates.
                RECT windowRect{}, frameBounds{};
                GetWindowRect(window, &windowRect);
                DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &frameBounds, sizeof frameBounds);
                // The marker is 10 px tall, 10 px above the block: probe the block's middle.
                POINT probe{blockInFrame.x + 60, blockInFrame.y + 80};
                POINT client{probe.x + frameBounds.left, probe.y + frameBounds.top};
                ScreenToClient(window, &client);
                capture.SetProbe(probe);
                std::vector<double> latencies;
                int misses = 0;
                for (int i = 0; i < latencyN; ++i) {
                    Sleep(60 + (i * 7) % 17);  // off the vblank's phase
                    capture.Take();
                    const uint32_t before = capture.LastProbe();
                    POINT at{client.x + (i % 2 ? 6 : -6), client.y};
                    HWND target = window;
                    POINT local = at;
                    if (!osr) target = DeepestChild(window, local);
                    const int64_t posted = Qpc();
                    PostMessageW(target, WM_MOUSEMOVE, 0, MAKELPARAM(local.x, local.y));
                    const auto changed = capture.WaitForChange(before, 1000);
                    if (!changed) {
                        ++misses;
                        continue;
                    }
                    const double postedAt100ns = posted / freq * 1e7;
                    latencies.push_back((static_cast<double>(changed->time100ns) - postedAt100ns) / 1e4);
                }
                json << ",\"latency\":{\"ms\":" << Percentiles(latencies) << ",\"misses\":" << misses << "}";
            } else {
                json << ",\"latency\":null";
            }
        }
    } catch (const winrt::hresult_error& e) {
        fprintf(stderr, "osrperf: capture failed: 0x%08X\n", static_cast<unsigned>(e.code()));
    }
    // minimized: the page should stop drawing (windowed: its widget window hidden; --osr: WasHidden).
    if (minimize) {
        ShowWindow(window, SW_SHOWMINNOACTIVE);
        Sleep(2000);
        json << ",\"minimized\":{\"seconds\":5";
        sample(5, json);
        json << "}";
    }
    json << "}";
    if (mapping) {
        UnmapViewOfFile(stats);
        CloseHandle(mapping);
    }
    CloseKite(kiteProcess, window);
    std::ofstream(out, std::ios::binary) << json.str() << "\n";
    printf("%s\n", json.str().c_str());
    return 0;
}

// Whether this PC's DirectComposition has IDCompositionTexture (IDCompositionDevice4, Windows 11
// 24H2+), and on which adapters: the zero-swap-chain way to show a copied page texture.
int Dcomp4() {
    ComPtr<IDXGIFactory1> factory;
    CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory && factory->EnumAdapters1(i, adapter.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        ComPtr<ID3D11Device> device;
        if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                     D3D11_SDK_VERSION, device.GetAddressOf(), nullptr, nullptr))) {
            continue;
        }
        ComPtr<IDCompositionDevice4> dcomp;
        const HRESULT hr = DCompositionCreateDevice3(device.Get(), IID_PPV_ARGS(dcomp.GetAddressOf()));
        BOOL supported = FALSE;
        if (SUCCEEDED(hr)) dcomp->CheckCompositionTextureSupport(device.Get(), &supported);
        printf("adapter %u %s luid 0x%08lX_0x%08lX: IDCompositionDevice4 %s, composition textures %s\n", i, Narrow(desc.Description).c_str(),
               static_cast<unsigned long>(desc.AdapterLuid.HighPart), desc.AdapterLuid.LowPart, SUCCEEDED(hr) ? "yes" : "no",
               supported ? "supported" : "not supported");
    }
    return 0;
}

int LaunchAndWait(int argc, wchar_t** argv) {
    if (argc < 4) return 1;
    std::wstring args;
    for (int i = 4; i < argc; ++i) args += std::wstring(i > 4 ? L" " : L"") + L"\"" + argv[i] + L"\"";
    Launched l = Launch(argv[2], argv[3], args);
    if (!l.ok) return 2;
    if (HWND w = WaitForWindow(l.pi.dwProcessId, 20'000)) SetWindowPos(w, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    DWORD code = 0;
    if (WaitForSingleObject(l.pi.hProcess, 120'000) != WAIT_OBJECT_0) {
        HWND w = KiteWindow(l.pi.dwProcessId);
        CloseKite(l, w);
        return 4;
    }
    GetExitCodeProcess(l.pi.hProcess, &code);
    CloseHandle(l.pi.hThread);
    CloseHandle(l.pi.hProcess);
    printf("exit %lu\n", code);
    return static_cast<int>(code);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc >= 2 && std::wstring(argv[1]) == L"measure") return Measure(argc, argv);
    if (argc >= 2 && std::wstring(argv[1]) == L"launch") return LaunchAndWait(argc, argv);
    if (argc >= 2 && std::wstring(argv[1]) == L"dcomp4") return Dcomp4();
    fprintf(stderr, "usage: osrperf measure <Kite.exe> <profile> <out.json> [--osr] [--seconds N] [--latency N] [--shot PNG] [--top]\n"
                    "       osrperf launch <Kite.exe> <profile> [args...]\n");
    return 1;
}
