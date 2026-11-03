#include "shell/TouchpadInput.h"

#include <directmanipulation.h>

#include <atomic>

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

std::unique_ptr<TouchpadInput> TouchpadInput::Create(HWND window, std::function<void(const SwipeInput&)> input, std::wstring& error) {
    std::unique_ptr<TouchpadInput> touchpad(new TouchpadInput(window, std::move(input)));
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
    Recentre();
    updates_->Update(nullptr);
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

bool TouchpadInput::HitTest(WPARAM wParam, const std::function<bool(POINT)>& take) {
    const UINT32 pointer = GET_POINTERID_WPARAM(wParam);
    POINTER_INPUT_TYPE type = PT_POINTER;
    if (!GetPointerType(pointer, &type) || type != PT_TOUCHPAD) return false;
    POINTER_INFO info{};
    if (!GetPointerInfo(pointer, &info)) return false;
    POINT at = info.ptPixelLocation;
    ScreenToClient(window_, &at);
    if (!take(at) || FAILED(viewport_->SetContact(pointer))) return false;
    contact_ = at;
    pollUntil_ = FrameClock::Now() + kFirstWord;
    return true;
}

bool TouchpadInput::Active() const { return gesture_ != Gesture::None || FrameClock::Now() < pollUntil_; }

void TouchpadInput::Update() {
    if (updates_) updates_->Update(nullptr);
}

void TouchpadInput::StatusChanged(int current, int previous) {
    if (current == previous) return;
    if (current == DIRECTMANIPULATION_RUNNING) {
        // Fingers down again mid-momentum: that ends, and a gesture of its own begins.
        if (gesture_ == Gesture::Inertia) Emit(SwipeInput::Phase::MomentumEnded, 0, 0);
        gesture_ = Gesture::Running;
        // Where the content starts from: DirectManipulation reports where it is, not how far it
        // went.
        baseline_ = ContentTransform(lastX_, lastY_);
        pollUntil_ = 0;
        Emit(SwipeInput::Phase::Began, 0, 0);
    } else if (current == DIRECTMANIPULATION_INERTIA) {
        if (gesture_ == Gesture::Running) Emit(SwipeInput::Phase::Ended, 0, 0);
        gesture_ = Gesture::Inertia;
    } else {
        // At rest (or the system took the viewport away mid-gesture).
        const Gesture was = gesture_;
        gesture_ = Gesture::None;
        if (was == Gesture::Running) {
            Emit(current == DIRECTMANIPULATION_READY ? SwipeInput::Phase::Ended : SwipeInput::Phase::Cancelled, 0, 0);
        } else if (was == Gesture::Inertia) {
            Emit(SwipeInput::Phase::MomentumEnded, 0, 0);
        }
        if (current == DIRECTMANIPULATION_READY && was != Gesture::None) Recentre();
    }
}

void TouchpadInput::ContentMoved(float x, float y) {
    // Only a gesture's movement: the viewport going back to the middle is none.
    if (gesture_ == Gesture::None) return;
    if (!baseline_) {
        // Where it started wasn't to be had: it starts from its first word.
        baseline_ = true;
        lastX_ = x;
        lastY_ = y;
        return;
    }
    const float dx = x - lastX_, dy = y - lastY_;
    lastX_ = x;
    lastY_ = y;
    if (dx == 0 && dy == 0) return;
    Emit(gesture_ == Gesture::Running ? SwipeInput::Phase::Changed : SwipeInput::Phase::Momentum, dx / scale_, dy / scale_);
}

void TouchpadInput::Emit(SwipeInput::Phase phase, double dx, double dy) {
    if (input_) input_(SwipeInput{phase, dx, dy, FrameClock::Now()});
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
    if (viewport_) viewport_->ZoomToRect(0, 0, kViewport, kViewport, FALSE);
    baseline_ = false;
}

}  // namespace kite
