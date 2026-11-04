// See TouchpadInput.h.

#include "shell/TouchpadInput.h"

#include <directmanipulation.h>

#include <atomic>
#include <cstdio>

#include "shell/Errors.h"
#include "shell/FrameClock.h"

namespace kite {

using Microsoft::WRL::ComPtr;

// Core's statuses are DirectManipulation's by value: StatusChanged casts one to the other.
static_assert(static_cast<int>(ViewportStatus::Building) == static_cast<int>(DIRECTMANIPULATION_BUILDING));
static_assert(static_cast<int>(ViewportStatus::Enabled) == static_cast<int>(DIRECTMANIPULATION_ENABLED));
static_assert(static_cast<int>(ViewportStatus::Disabled) == static_cast<int>(DIRECTMANIPULATION_DISABLED));
static_assert(static_cast<int>(ViewportStatus::Running) == static_cast<int>(DIRECTMANIPULATION_RUNNING));
static_assert(static_cast<int>(ViewportStatus::Inertia) == static_cast<int>(DIRECTMANIPULATION_INERTIA));
static_assert(static_cast<int>(ViewportStatus::Ready) == static_cast<int>(DIRECTMANIPULATION_READY));
static_assert(static_cast<int>(ViewportStatus::Suspended) == static_cast<int>(DIRECTMANIPULATION_SUSPENDED));

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
// contact as down), so a resting finger never keeps the clock going for good: then the contact
// goes back to the system, whose wheel messages carry whatever the fingers do next.
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

TouchpadInput::TouchpadInput(HWND window, std::function<void(const SwipeInput&)> input, std::function<void()> wantsFrames)
    : window_(window), input_(std::move(input)), wantsFrames_(std::move(wantsFrames)) {}

std::unique_ptr<TouchpadInput> TouchpadInput::Create(HWND window, std::function<void(const SwipeInput&)> input,
                                                     std::function<void()> wantsFrames, std::wstring& error) {
    std::unique_ptr<TouchpadInput> touchpad(new TouchpadInput(window, std::move(input), std::move(wantsFrames)));
    error = touchpad->Init();
    if (!error.empty()) return nullptr;
    return touchpad;
}

std::wstring TouchpadInput::Init() {
    // DirectManipulation is apartment-threaded, on the window's thread. COM stays initialized
    // for the thread's life: other objects made on it may outlive this one. A thread already in
    // the multithreaded apartment (RPC_E_CHANGED_MODE) can't have it: no gestures, and the
    // touchpad stays the system's wheel messages.
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) return HResultMessage(L"COM's single-threaded apartment", hr);
    hr = CoCreateInstance(kManagerClass, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IDirectManipulationManager),
                          reinterpret_cast<void**>(manager_.GetAddressOf()));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation", hr);
    hr = manager_->GetUpdateManager(__uuidof(IDirectManipulationUpdateManager), reinterpret_cast<void**>(updates_.GetAddressOf()));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's update manager", hr);
    hr = manager_->CreateViewport(nullptr, window_, __uuidof(IDirectManipulationViewport),
                                  reinterpret_cast<void**>(viewport_.GetAddressOf()));
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's viewport", hr);
    // Panning only, with its momentum, kept to one axis once a gesture is clearly along it.
    hr = viewport_->ActivateConfiguration(
        DIRECTMANIPULATION_CONFIGURATION_INTERACTION | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_X |
        DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA |
        DIRECTMANIPULATION_CONFIGURATION_RAILS_X | DIRECTMANIPULATION_CONFIGURATION_RAILS_Y);
    if (SUCCEEDED(hr)) hr = viewport_->SetViewportOptions(DIRECTMANIPULATION_VIEWPORT_OPTIONS_MANUALUPDATE);
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's configuration", hr);
    handler_.Attach(new Handler(this));
    hr = viewport_->AddEventHandler(window_, handler_.Get(), &cookie_);
    if (FAILED(hr)) return HResultMessage(L"DirectManipulation's event handler", hr);
    const RECT viewport{0, 0, static_cast<LONG>(kViewport), static_cast<LONG>(kViewport)};
    hr = viewport_->SetViewportRect(&viewport);
    ComPtr<IDirectManipulationContent> content;
    if (SUCCEEDED(hr)) {
        hr = viewport_->GetPrimaryContent(__uuidof(IDirectManipulationContent), reinterpret_cast<void**>(content.GetAddressOf()));
    }
    if (SUCCEEDED(hr)) {
        const RECT room{-kContentMargin, -kContentMargin, kContentMargin + static_cast<LONG>(kViewport),
                        kContentMargin + static_cast<LONG>(kViewport)};
        hr = content->SetContentRect(&room);
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
    // The handler first, so nothing DirectManipulation reports from here on reaches this.
    if (handler_) handler_->Forget();
    if (viewport_) {
        if (cookie_) viewport_->RemoveEventHandler(cookie_);
        viewport_->Abandon();
        viewport_.Reset();
    }
    handler_.Reset();
    if (manager_ && activated_) manager_->Deactivate(window_);
    updates_.Reset();
    manager_.Reset();
}

bool TouchpadInput::HitTest(WPARAM wParam, LPARAM lParam, const std::function<bool(POINT)>& take) {
    const UINT32 pointer = GET_POINTERID_WPARAM(wParam);
    POINTER_INPUT_TYPE type = PT_POINTER;
    if (!GetPointerType(pointer, &type) || type != PT_TOUCHPAD) return false;
    POINT at{static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))};
    ScreenToClient(window_, &at);
    if (!take(at) || FAILED(viewport_->SetContact(pointer))) return false;
    pointer_ = pointer;
    contactHeld_ = contactTaken_ = true;
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

void TouchpadInput::ReleaseContact() {
    if (contactHeld_) releaseWanted_ = true;
}

void TouchpadInput::Release() {
    releaseWanted_ = false;
    if (!contactHeld_) return;
    contactHeld_ = contactTaken_ = false;
    pollUntil_ = 0;
    const HRESULT hr = viewport_->ReleaseContact(pointer_);
    const double now = FrameClock::Now();
    if (log) {
        char line[96];
        std::snprintf(line, sizeof line, "{\"dm\":\"release\",\"t\":%.6f,\"pointer\":%u,\"hr\":%ld}", now, pointer_, static_cast<long>(hr));
        log(line);
    }
    // A gesture let go of mid-way ends here, whether or not DirectManipulation reports it (its
    // own report after this changes nothing): its frames stop with it.
    if (phases_.Moving()) {
        float x = contentX_, y = contentY_;
        ContentTransform(x, y);
        phases_.StatusChanged(ViewportStatus::Enabled, ViewportStatus::Running, x, y, now, pending_);
        Deliver();
    }
}

bool TouchpadInput::NeedsFrames(double now) const {
    return phases_.Moving() || recentring_ || releaseWanted_ || now < pollUntil_ || contactTaken_;
}

void TouchpadInput::PollFor(double seconds) {
    pollUntil_ = FrameClock::Now() + seconds;
}

bool TouchpadInput::Step() {
    const double now = FrameClock::Now();
    if (!NeedsFrames(now)) return false;
    const size_t before = reports_;
    updates_->Update(nullptr);
    recentring_ = false;
    if (releaseWanted_) Release();
    // Fingers resting before they move: polled until DirectManipulation says it's running, they
    // lift, or kLongestRest has gone by.
    if (contactTaken_) {
        POINTER_INFO info{};
        if (!(GetPointerInfo(pointer_, &info) && (info.pointerFlags & POINTER_FLAG_INCONTACT))) {
            contactHeld_ = contactTaken_ = false;
        } else if (now >= restUntil_) {
            Release();
        }
    }
    if (log && reports_ == before) {
        char line[96];
        std::snprintf(line, sizeof line, "{\"dm\":\"poll\",\"t\":%.6f,\"held\":%d}", now, contactTaken_ ? 1 : 0);
        log(line);
    }
    return NeedsFrames(FrameClock::Now());
}

void TouchpadInput::StatusChanged(int current, int previous) {
    ++reports_;
    float x = contentX_, y = contentY_;
    if (ContentTransform(x, y)) {
        contentX_ = x;
        contentY_ = y;
    }
    if (log) {
        char line[160];
        std::snprintf(line, sizeof line, "{\"dm\":\"status\",\"t\":%.6f,\"current\":%d,\"previous\":%d,\"x\":%.3f,\"y\":%.3f}", FrameClock::Now(),
                      current, previous, x, y);
        log(line);
    }
    const bool recentre = phases_.StatusChanged(static_cast<ViewportStatus>(current), static_cast<ViewportStatus>(previous), x, y,
                                                FrameClock::Now(), pending_);
    if (current == DIRECTMANIPULATION_RUNNING || current == DIRECTMANIPULATION_INERTIA) {
        contactTaken_ = false;  // DirectManipulation has it now: no more polling for a rest
        if (wantsFrames_) wantsFrames_();
    } else if (current == DIRECTMANIPULATION_READY) {
        contactHeld_ = contactTaken_ = releaseWanted_ = false;  // the fingers lifted
    }
    if (recentre) Recentre();
    Deliver();
}

void TouchpadInput::ContentMoved(float x, float y) {
    ++reports_;
    contentX_ = x;
    contentY_ = y;
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
    ComPtr<IDirectManipulationContent> content;
    if (!viewport_ ||
        FAILED(viewport_->GetPrimaryContent(__uuidof(IDirectManipulationContent), reinterpret_cast<void**>(content.GetAddressOf())))) {
        return false;
    }
    float transform[6] = {};
    if (FAILED(content->GetContentTransform(transform, 6))) return false;
    x = transform[4];
    y = transform[5];
    return true;
}

void TouchpadInput::Recentre() {
    // The next Step applies it (on manual updates it may wait for one), and the next gesture
    // counts from the middle whenever it lands.
    if (viewport_ && SUCCEEDED(viewport_->ZoomToRect(0, 0, kViewport, kViewport, FALSE))) {
        phases_.Recentred();
        recentring_ = true;
    }
}

}  // namespace kite
