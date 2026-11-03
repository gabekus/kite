#include "shell/TouchpadInput.h"

#include <directmanipulation.h>

#include <atomic>
#include <cstdio>

#include "shell/Errors.h"
#include "shell/FrameClock.h"

namespace kite {

namespace {

// DirectManipulationManager's class (directmanipulation.h's CLSID, defined here so neither
// toolchain needs it from a library).
constexpr CLSID kManagerClass = {0x54e211b6, 0x3650, 0x4f75, {0x83, 0x34, 0xfa, 0x35, 0x95, 0x98, 0xe1, 0xc5}};
// The viewport, and content far bigger round it, in px: a gesture's travel is never clamped,
// and the viewport goes back over the middle after each one.
constexpr float kViewport = 1000;
constexpr LONG kContentMargin = 1 << 20;
// How long a taken contact keeps the frames coming before DirectManipulation says it's running
// (a tap or a resting finger never does): a few frames, for its manual updates to start it.
constexpr double kFirstWord = 0.25;
// And at most this long while it's held without moving (should Windows keep reporting a lifted
// contact as down), so a resting finger never keeps the clock going for good.
constexpr double kLongestRest = 10;

}  // namespace

// The viewport's event handler: a COM object DirectManipulation holds, forwarding to its
// TouchpadInput until that goes.
class TouchpadInput::Handler final : public IDirectManipulationViewportEventHandler {
public:
    explicit Handler(TouchpadInput* owner) : owner_(owner) {}
    void Forget() { owner_ = nullptr; }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (!object) return E_POINTER;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IDirectManipulationViewportEventHandler)) {
            *object = static_cast<IDirectManipulationViewportEventHandler*>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG left = --references_;
        if (left == 0) delete this;
        return left;
    }

    HRESULT STDMETHODCALLTYPE OnViewportStatusChanged(IDirectManipulationViewport*, DIRECTMANIPULATION_STATUS current,
                                                      DIRECTMANIPULATION_STATUS previous) override {
        if (owner_) owner_->StatusChanged(current, previous);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnViewportUpdated(IDirectManipulationViewport*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnContentUpdated(IDirectManipulationViewport*, IDirectManipulationContent* content) override {
        float transform[6] = {};
        if (owner_ && content && SUCCEEDED(content->GetContentTransform(transform, 6))) owner_->ContentMoved(transform[4], transform[5]);
        return S_OK;
    }

private:
    ~Handler() = default;
    TouchpadInput* owner_;
    std::atomic<ULONG> references_{1};
};

std::unique_ptr<TouchpadInput> TouchpadInput::Create(HWND window, std::function<void(const SwipeInput&)> input,
                                                     std::function<void()> wantsFrames, std::wstring& error) {
    std::unique_ptr<TouchpadInput> touchpad(new TouchpadInput(window, std::move(input), std::move(wantsFrames)));
    error = touchpad->Init();
    if (!error.empty()) return nullptr;
    return touchpad;
}

std::wstring TouchpadInput::Init() {
    // DirectManipulation is apartment-threaded, on the window's thread. COM stays initialized
    // for the thread's life: other objects made on it may outlive this one.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    HRESULT hr = CoCreateInstance(kManagerClass, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IDirectManipulationManager),
                                  reinterpret_cast<void**>(&manager_));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation", hr);
    hr = manager_->GetUpdateManager(__uuidof(IDirectManipulationUpdateManager), reinterpret_cast<void**>(&updates_));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's update manager", hr);
    hr = manager_->CreateViewport(nullptr, window_, __uuidof(IDirectManipulationViewport), reinterpret_cast<void**>(&viewport_));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's viewport", hr);
    // Panning only, with its momentum, kept to one axis once a gesture is clearly along it.
    hr = viewport_->ActivateConfiguration(
        DIRECTMANIPULATION_CONFIGURATION_INTERACTION | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_X |
        DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA |
        DIRECTMANIPULATION_CONFIGURATION_RAILS_X | DIRECTMANIPULATION_CONFIGURATION_RAILS_Y);
    if (SUCCEEDED(hr)) hr = viewport_->SetViewportOptions(DIRECTMANIPULATION_VIEWPORT_OPTIONS_MANUALUPDATE);
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's configuration", hr);
    handler_ = new Handler(this);
    hr = viewport_->AddEventHandler(window_, handler_, &cookie_);
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's event handler", hr);
    const RECT viewport{0, 0, static_cast<LONG>(kViewport), static_cast<LONG>(kViewport)};
    hr = viewport_->SetViewportRect(&viewport);
    IDirectManipulationContent* content = nullptr;
    if (SUCCEEDED(hr)) hr = viewport_->GetPrimaryContent(__uuidof(IDirectManipulationContent), reinterpret_cast<void**>(&content));
    if (SUCCEEDED(hr)) {
        const RECT room{-kContentMargin, -kContentMargin, kContentMargin + static_cast<LONG>(kViewport),
                        kContentMargin + static_cast<LONG>(kViewport)};
        hr = content->SetContentRect(&room);
        content->Release();
    }
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's viewport", hr);
    hr = manager_->Activate(window_);
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's activation", hr);
    activated_ = true;
    hr = viewport_->Enable();
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's viewport", hr);
    // Over the middle from the start, so the first gesture counts from there.
    Recentre();
    updates_->Update(nullptr);
    recentring_ = false;
    return {};
}

TouchpadInput::~TouchpadInput() {
    if (handler_) handler_->Forget();
    if (viewport_) {
        if (cookie_) viewport_->RemoveEventHandler(cookie_);
        viewport_->Abandon();
        viewport_->Release();
    }
    if (handler_) handler_->Release();
    if (manager_ && activated_) manager_->Deactivate(window_);
    if (updates_) updates_->Release();
    if (manager_) manager_->Release();
}

bool TouchpadInput::HitTest(WPARAM wParam, LPARAM lParam, const std::function<bool(POINT)>& take) {
    const UINT32 pointer = GET_POINTERID_WPARAM(wParam);
    POINTER_INPUT_TYPE type = PT_POINTER;
    if (!GetPointerType(pointer, &type) || type != PT_TOUCHPAD) return false;
    POINT at{static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))};
    ScreenToClient(window_, &at);
    if (!take(at) || FAILED(viewport_->SetContact(pointer))) return false;
    contact_ = at;
    pointer_ = pointer;
    contactTaken_ = true;
    const double now = FrameClock::Now();
    pollUntil_ = now + kFirstWord;
    restUntil_ = now + kLongestRest;
    if (log) {
        char line[120];
        std::snprintf(line, sizeof line, "{\"dm\":\"contact\",\"t\":%.6f,\"pointer\":%u,\"x\":%ld,\"y\":%ld}", now, pointer, at.x, at.y);
        log(line);
    }
    return true;
}

bool TouchpadInput::Active() const {
    if (phases_.Moving() || recentring_ || FrameClock::Now() < pollUntil_) return true;
    // Fingers resting before they move: DirectManipulation's updates must keep coming until it
    // says it's running (up to kLongestRest).
    POINTER_INFO info{};
    return contactTaken_ && FrameClock::Now() < restUntil_ && GetPointerInfo(pointer_, &info) &&
           (info.pointerFlags & POINTER_FLAG_INCONTACT);
}

void TouchpadInput::Update() {
    const size_t before = reports_;
    if (updates_) updates_->Update(nullptr);
    recentring_ = false;
    // A contact that lifted without ever moving: no more polling for it.
    POINTER_INFO info{};
    if (contactTaken_ && !(GetPointerInfo(pointer_, &info) && (info.pointerFlags & POINTER_FLAG_INCONTACT))) contactTaken_ = false;
    if (log && reports_ == before) {
        char line[96];
        std::snprintf(line, sizeof line, "{\"dm\":\"poll\",\"t\":%.6f,\"held\":%d}", FrameClock::Now(), contactTaken_ ? 1 : 0);
        log(line);
    }
}

void TouchpadInput::StatusChanged(int current, int previous) {
    ++reports_;
    float x = 0, y = 0;
    ContentTransform(x, y);
    if (log) {
        char line[160];
        std::snprintf(line, sizeof line, "{\"dm\":\"status\",\"t\":%.6f,\"current\":%d,\"previous\":%d,\"x\":%.3f,\"y\":%.3f}", FrameClock::Now(),
                      current, previous, x, y);
        log(line);
    }
    const bool recentre = phases_.StatusChanged(static_cast<ViewportStatus>(current), static_cast<ViewportStatus>(previous), x, y,
                                                FrameClock::Now(), pending_);
    if (current == DIRECTMANIPULATION_RUNNING || current == DIRECTMANIPULATION_INERTIA) {
        contactTaken_ = false;  // DirectManipulation has it now
        if (wantsFrames_) wantsFrames_();
    }
    if (recentre) Recentre();
    Deliver();
}

void TouchpadInput::ContentMoved(float x, float y) {
    ++reports_;
    if (log) {
        char line[120];
        std::snprintf(line, sizeof line, "{\"dm\":\"content\",\"t\":%.6f,\"x\":%.3f,\"y\":%.3f}", FrameClock::Now(), x, y);
        log(line);
    }
    phases_.ContentMoved(x, y, scale_, FrameClock::Now(), pending_);
    Deliver();
}

void TouchpadInput::Deliver() {
    // Taken first: what an input does may make the next report (a recentre's) reach here.
    std::vector<SwipeInput> events;
    events.swap(pending_);
    for (const SwipeInput& event : events) {
        if (input_) input_(event);
    }
    // Its storage back for the next report's, unless a report came meanwhile.
    events.clear();
    if (pending_.empty()) pending_.swap(events);
}

bool TouchpadInput::ContentTransform(float& x, float& y) const {
    IDirectManipulationContent* content = nullptr;
    if (!viewport_ ||
        FAILED(viewport_->GetPrimaryContent(__uuidof(IDirectManipulationContent), reinterpret_cast<void**>(&content)))) {
        return false;
    }
    float transform[6] = {};
    const bool read = SUCCEEDED(content->GetContentTransform(transform, 6));
    content->Release();
    if (read) {
        x = transform[4];
        y = transform[5];
    }
    return read;
}

void TouchpadInput::Recentre() {
    // The next Update applies it (on manual updates it may wait for one), and the next
    // gesture counts from the middle whenever it lands.
    if (viewport_ && SUCCEEDED(viewport_->ZoomToRect(0, 0, kViewport, kViewport, FALSE))) {
        phases_.Recentred();
        recentring_ = true;
    }
}

}  // namespace kite
