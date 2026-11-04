#pragma once
// W10 spike (docs/windows-osr-spike.md), behind --osr on a test profile: the shown page
// rendered off-screen by Chromium (CEF's shared_texture_enabled + OnAcceleratedPaint) and
// presented as a DirectComposition visual on the content card, clipped to the card's 6pt
// corners as the Mac's is. Nothing here runs without --osr.
//
// Threads, as the W10 row in windows/helix/checkpoints.md asks: OnAcceleratedPaint runs on
// CEF's UI thread and its texture goes back to Chromium's pool when it returns, so the frame
// is copied and presented there, on a D3D11 device of the presenter's own (on Kite's
// renderer's adapter), never Kite's device or its single-threaded Direct2D. The visual and
// its clip are Kite's thread's (they live in Kite's composition tree); the swap chain they
// show is presented from CEF's thread, which DirectComposition picks up without a commit.

#include <windows.h>  // first: the DirectX headers need its types

#include <d3d11_4.h>
#include <dcomp.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "shell/Capture.h"

namespace kite {

// Counters the spike exposes in a named mapping (Local\KiteOsrSpike-<pid>) for the
// measurement tool (windows/tools/osrperf), so it reads them without touching Kite's threads.
// Plain 64-bit counters written by one thread each.
struct OffscreenStats {
    uint64_t version;            // 1
    uint64_t qpcFrequency;
    uint64_t viewPaints;         // OnAcceleratedPaint for the shown page's view
    uint64_t popupPaints;        // ... for its <select> or autofill popup
    uint64_t ignoredPaints;      // from a page that isn't shown
    uint64_t presents;           // frames presented to the card's swap chain
    uint64_t openFailures;       // OpenSharedResource1 failed
    uint64_t copyTicksTotal;     // open + copy + present on CEF's thread, QPC ticks
    uint64_t copyTicksMax;
    uint64_t inputsForwarded;    // mouse, wheel and key events sent to the page
    uint64_t inputToPresentTicksTotal;  // from a forwarded input to the next present
    uint64_t inputToPresentCount;
    uint64_t popupShows;         // OnPopupShow(true)
    uint64_t cursorChanges;      // OnCursorChange
    uint64_t imeRangeChanges;    // OnImeCompositionRangeChanged
    uint64_t resizes;            // WasResized
    uint64_t hides;              // WasHidden(true)
    uint64_t lastWidth, lastHeight;  // the last view texture, px
    uint64_t lastPresentQpc;
    uint64_t lastCursorType;     // cef_cursor_type_t
};

class OffscreenPresenter {
public:
    // A D3D11 device of its own on `adapterLuid` (Kite's renderer's adapter, the one Chromium's
    // GPU process picks too, checked by PDH in the spike), multithread-protected. Null with
    // `error` when it can't be made.
    static std::unique_ptr<OffscreenPresenter> Create(LUID adapterLuid, std::wstring& error);
    ~OffscreenPresenter();
    OffscreenPresenter(const OffscreenPresenter&) = delete;
    OffscreenPresenter& operator=(const OffscreenPresenter&) = delete;

    // Kite's thread. Puts the page's visual under `parent` in `device`'s tree (again after the
    // compositor is rebuilt for a lost GPU). Null detaches.
    void Attach(IDCompositionDevice* device, IDCompositionVisual* parent);
    // Kite's thread: where the card is (client px) and its corner radius (px); shown or not.
    // Commits Kite's composition device.
    void Place(const RECT& card, float radius, bool visible);

    // CEF's thread. Which browser's frames are shown (its identifier; 0 for none).
    void SetShown(int browserID) { shown_ = browserID; }
    int Shown() const { return shown_; }
    // A frame from OnAcceleratedPaint. True when it was presented.
    bool Paint(int browserID, bool popup, HANDLE sharedTexture);
    // OnPopupShow / OnPopupSize (the popup's rect in view px).
    void PopupShown(bool shown);
    void PopupRect(const RECT& rect);
    bool NeedsViewRepaint() { return needsView_.exchange(false); }

    // Any thread: the next presented frame of the shown page, read back (for --capture). Kite's
    // thread asks, CEF's paints; the caller makes Chromium paint again (Invalidate).
    void RequestReadBack();
    // Waits up to `timeoutMs` for the requested frame, pumping messages.
    std::optional<Pixels> TakeReadBack(DWORD timeoutMs, std::wstring& error);
    bool HasPresented() const { return stats_ && stats_->presents > 0; }
    // Whether the frame's corners are cut out as it's copied (else DirectComposition clips).
    bool MasksCorners() const { return maskCorners_; }

    OffscreenStats* Stats() { return stats_; }
    // Kite's thread: an input was forwarded now (for input → next present).
    void InputForwarded();

private:
    OffscreenPresenter() = default;
    bool EnsureSwapChain(UINT width, UINT height);
    bool EnsureTexture(Microsoft::WRL::ComPtr<ID3D11Texture2D>& texture, UINT width, UINT height);
    bool Compose(ID3D11Texture2D* view);  // the view (and popup) into the back buffer, presented
    bool DrawMasked(ID3D11Texture2D* target, ID3D11Texture2D* view, const D3D11_TEXTURE2D_DESC& desc);

    std::mutex mutex_;  // the device's context and the swap chain: CEF's thread, and a read-back
    Microsoft::WRL::ComPtr<ID3D11Device1> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<IDXGIFactory2> factory_;
    Microsoft::WRL::ComPtr<IDXGISwapChain1> swapChain_;
    UINT width_ = 0, height_ = 0;
    // While a popup shows: the last view frame and the popup's, composed into each frame.
    Microsoft::WRL::ComPtr<ID3D11Texture2D> viewCopy_, popupCopy_;
    bool viewValid_ = false, popupValid_ = false;
    bool popupShown_ = false;
    RECT popupRect_{};
    std::atomic<bool> needsView_{false};
    std::atomic<int> shown_{0};
    bool maskCorners_ = true;
    std::atomic<float> radius_{0};
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> card_;

    // Kite's thread.
    Microsoft::WRL::ComPtr<IDCompositionDevice> dcomp_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionRectangleClip> clip_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> parent_;
    bool contentSet_ = false;

    // Read-back.
    std::atomic<bool> readBackWanted_{false};
    HANDLE readBackDone_ = nullptr;
    std::optional<Pixels> readBack_;

    HANDLE statsMapping_ = nullptr;
    OffscreenStats* stats_ = nullptr;
    std::atomic<int64_t> pendingInput_{0};
};

// Rounds `pixels`' corners to `radius` px, anti-aliased, as the card's clip shows them
// (premultiplied: every channel is scaled by the coverage).
void RoundCorners(Pixels& pixels, float radius);

}  // namespace kite
