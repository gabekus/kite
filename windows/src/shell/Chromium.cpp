// See Chromium.h.

#include "shell/Chromium.h"

#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"
#include "core/Uuid.h"
#include "shell/MainWindow.h"

namespace kite {

namespace {

// The Mac's KCPageBackdropColor: what a page shows before it first paints.
constexpr cef_color_t kPageBackdrop = 0xFF323232;

CefRect ToCefRect(const RECT& r) { return CefRect(r.left, r.top, r.right - r.left, r.bottom - r.top); }

std::filesystem::path Utf8Path(const std::string& text) {
    return std::filesystem::path(std::u8string(reinterpret_cast<const char8_t*>(text.data()), text.size()));
}

}  // namespace

struct Chromium::Shared {
    HWND window = nullptr;
    PageEvents events;
    std::filesystem::path root;
    // Set when every browser that was ever created has closed (OnBeforeClose) and none is
    // being created: what the destructor waits for before CefShutdown.
    HANDLE allClosed = nullptr;

    // Both threads.
    std::atomic<int> creating{0};  // asked for (CreateBrowser, an allowed popup), no OnAfterCreated yet
    std::atomic<int> alive{0};     // OnAfterCreated, no OnBeforeClose yet
    std::atomic<bool> closing{false};
    std::mutex mutex;
    std::deque<std::function<void()>> pending;     // for Kite's UI thread
    RECT bounds{};                                 // where a new popup's window goes
    std::map<std::pair<int, int>, std::string> popupTabs;  // (opener browser id, popup_id) → tab id

    // Kite's UI thread only.
    struct Page {
        CefRefPtr<CefBrowser> browser;  // null until OnAfterCreated
        HWND hwnd = nullptr;
        bool closeReady = false;  // through DoClose
    };
    std::map<std::string, Page> pages;  // by tab id
    std::map<std::string, CefRefPtr<CefRequestContext>> contexts;  // by profile directory
    std::string shown;

    void Post(std::function<void()> work) {
        {
            std::lock_guard lock(mutex);
            pending.push_back(std::move(work));
        }
        PostMessageW(window, MainWindow::kWakeMessage, 0, 0);
    }

    void SignalIfAllClosed() {
        if (alive.load() == 0 && creating.load() == 0) SetEvent(allClosed);
        else ResetEvent(allClosed);
    }

    // Shows the selected tab's window where the card is, hides the rest. Hidden windows
    // count as occluded to Chromium, which throttles their pages.
    void Layout() {
        RECT r;
        {
            std::lock_guard lock(mutex);
            r = bounds;
        }
        for (auto& [id, page] : pages) {
            if (!page.hwnd) continue;
            if (id == shown) {
                SetWindowPos(page.hwnd, nullptr, r.left, r.top, r.right - r.left, r.bottom - r.top,
                             SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            } else {
                ShowWindow(page.hwnd, SW_HIDE);
            }
        }
    }

    void Attach(const std::string& tabID, CefRefPtr<CefBrowser> browser, HWND hwnd) {
        Page& page = pages[tabID];
        page.browser = browser;
        page.hwnd = hwnd;
        if (closing) browser->GetHost()->CloseBrowser(true);
        else Layout();
    }
};

namespace {

// One per tab: CEF's handlers for that tab's browser, on CEF's UI thread.
class PageClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler {
public:
    PageClient(std::string tabID, std::shared_ptr<Chromium::Shared> shared) : tabID_(std::move(tabID)), shared_(std::move(shared)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

    // CefLifeSpanHandler

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        ++shared_->alive;
        const HWND hwnd = browser->GetHost()->GetWindowHandle();
        shared_->Post([shared = shared_, id = tabID_, browser, hwnd] { shared->Attach(id, browser, hwnd); });
        --shared_->creating;  // after the post, so MayCloseWindow sees one or the other
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int popupID, const CefString& targetURL,
                       const CefString&, cef_window_open_disposition_t, bool, const CefPopupFeatures&, CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client, CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue>&,
                       bool*) override {
        if (shared_->closing) return true;
        // Hosted in a Kite tab instead of a separate window, as the Mac does, so window.opener
        // still works (sign-in popups post their result back through it).
        const std::string id = NewUuid();
        RECT bounds;
        {
            std::lock_guard lock(shared_->mutex);
            bounds = shared_->bounds;
            shared_->popupTabs[{browser->GetIdentifier(), popupID}] = id;
        }
        windowInfo.SetAsChild(shared_->window, ToCefRect(bounds));
        client = new PageClient(id, shared_);
        settings.background_color = kPageBackdrop;
        ++shared_->creating;
        ResetEvent(shared_->allClosed);
        shared_->Post([shared = shared_, opener = tabID_, id, url = targetURL.ToString()] {
            shared->pages.try_emplace(id);  // so Show doesn't create a second browser for it
            if (shared->events.popupOpened) shared->events.popupOpened(opener, id, url);
        });
        return false;
    }

    void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupID) override {
        std::string id;
        {
            std::lock_guard lock(shared_->mutex);
            auto it = shared_->popupTabs.find({browser->GetIdentifier(), popupID});
            if (it == shared_->popupTabs.end()) return;
            id = std::move(it->second);
            shared_->popupTabs.erase(it);
        }
        // The tab stays, without its opener: showing it again loads its address afresh.
        shared_->Post([shared = shared_, id] {
            if (auto it = shared->pages.find(id); it != shared->pages.end() && !it->second.browser) shared->pages.erase(it);
        });
        --shared_->creating;
        shared_->SignalIfAllClosed();
    }

    bool DoClose(CefRefPtr<CefBrowser>) override {
        // The main window closes once every browser is through here or closed
        // (MayCloseWindow), so ask it again. Returning false is documented to send that
        // WM_CLOSE itself, but on Gabe's PC (CEF 156, a parent window on another thread) none
        // arrived, so Kite doesn't rely on it; an extra WM_CLOSE is harmless. W5's single-tab close will
        // destroy just this tab's window instead, as the Mac's KCBrowser does.
        shared_->Post([shared = shared_, id = tabID_] {
            if (auto it = shared->pages.find(id); it != shared->pages.end()) it->second.closeReady = true;
            if (shared->closing) PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser>) override {
        // A force-closed browser may skip DoClose and end here (seen with CEF 156's default
        // style on Gabe's PC), so this also asks the window to close again.
        shared_->Post([shared = shared_, id = tabID_] {
            shared->pages.erase(id);
            if (shared->closing) PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        --shared_->alive;
        shared_->SignalIfAllClosed();
    }

    // CefDisplayHandler

    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
        if (!frame->IsMain()) return;
        shared_->Post([shared = shared_, id = tabID_, address = url.ToString()] {
            if (shared->events.addressChanged) shared->events.addressChanged(id, address);
        });
    }

    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
        shared_->Post([shared = shared_, id = tabID_, text = title.ToString()] {
            if (shared->events.titleChanged) shared->events.titleChanged(id, text);
        });
    }

    // CefLoadHandler

    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading, bool, bool) override {
        shared_->Post([shared = shared_, id = tabID_, isLoading] {
            if (shared->events.loadingChanged) shared->events.loadingChanged(id, isLoading);
        });
    }

private:
    const std::string tabID_;
    const std::shared_ptr<Chromium::Shared> shared_;
    IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

int RunChromiumSubprocess(HINSTANCE instance) {
    CefMainArgs args(instance);
    return CefExecuteProcess(args, nullptr, nullptr);
}

std::unique_ptr<Chromium> Chromium::Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, PageEvents events,
                                          std::wstring& error) {
    // Chromium wants root_cache_path absolute and every cache_path inside it, else it keeps
    // that profile in memory only; built from the resolved path, like the Mac (realpath).
    std::error_code ec;
    std::filesystem::create_directories(root, ec);
    std::filesystem::path resolved = std::filesystem::weakly_canonical(std::filesystem::absolute(root, ec), ec);
    if (ec || resolved.empty()) resolved = root;

    auto shared = std::make_shared<Shared>();
    shared->window = window;
    shared->events = std::move(events);
    shared->root = resolved;
    shared->allClosed = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    if (!shared->allClosed) {
        error = L"CreateEvent failed";
        return nullptr;
    }

    CefSettings settings;
    // CEF's own UI thread, so Kite's message loop (DirectComposition, the device-lost wait)
    // stays its own. The sandbox needs CEF's bootstrap executable and is its own checkpoint
    // (W6b in windows/helix/checkpoints.md); until then pages run unsandboxed, as in any
    // CEF app built without cef_sandbox.
    settings.multi_threaded_message_loop = true;
    settings.no_sandbox = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.persist_session_cookies = true;
    settings.background_color = kPageBackdrop;
    CefString(&settings.root_cache_path) = resolved.wstring();
    CefString(&settings.cache_path) = (resolved / L"Default").wstring();
    CefString(&settings.log_file) = (resolved / L"chromium.log").wstring();
    CefMainArgs args(instance);
    if (!CefInitialize(args, settings, nullptr, nullptr)) {
        error = L"CefInitialize failed (exit code " + std::to_wstring(CefGetExitCode()) + L")";
        CloseHandle(shared->allClosed);
        return nullptr;
    }
    return std::unique_ptr<Chromium>(new Chromium(std::move(shared)));
}

Chromium::Chromium(std::shared_ptr<Shared> shared) : shared_(std::move(shared)) {}

Chromium::~Chromium() {
    // The main window is gone by now (Kite declares this before it), and with it every
    // browser's window; CEF finishes closing them on its thread. Bounded, so a wedged
    // browser can't keep Kite from exiting.
    // (A browser not yet through DoClose means Kite left early, on an error path.)
    shared_->closing = true;
    for (auto& [id, page] : shared_->pages) {
        if (page.browser && !page.closeReady) page.browser->GetHost()->CloseBrowser(true);
    }
    shared_->SignalIfAllClosed();
    WaitForSingleObject(shared_->allClosed, 10'000);
    shared_->pages.clear();
    shared_->contexts.clear();
    {
        std::lock_guard lock(shared_->mutex);
        shared_->pending.clear();
    }
    CefShutdown();
    CloseHandle(shared_->allClosed);
}

void Chromium::Show(const std::string& tabID, const std::string& profileDirectory, const std::string& url, const RECT& bounds) {
    if (shared_->closing) return;
    {
        std::lock_guard lock(shared_->mutex);
        shared_->bounds = bounds;
    }
    shared_->shown = tabID;
    if (!shared_->pages.contains(tabID)) {
        // A space's own profile gets its own request context, a folder beside Default, as
        // the Mac's KCRequestContext does; the default profile is CEF's global context.
        CefRefPtr<CefRequestContext> context;
        if (profileDirectory != "Default") {
            CefRefPtr<CefRequestContext>& cached = shared_->contexts[profileDirectory];
            if (!cached) {
                CefRequestContextSettings contextSettings;
                contextSettings.persist_session_cookies = true;
                CefString(&contextSettings.cache_path) = (shared_->root / Utf8Path(profileDirectory)).wstring();
                cached = CefRequestContext::CreateContext(contextSettings, nullptr);
            }
            context = cached;
        }
        CefWindowInfo windowInfo;
        windowInfo.SetAsChild(shared_->window, ToCefRect(bounds));
        CefBrowserSettings browserSettings;
        browserSettings.background_color = kPageBackdrop;
        shared_->pages.try_emplace(tabID);
        ++shared_->creating;
        ResetEvent(shared_->allClosed);
        if (!CefBrowserHost::CreateBrowser(windowInfo, new PageClient(tabID, shared_), url.empty() ? "about:blank" : url,
                                           browserSettings, nullptr, context)) {
            OutputDebugStringW(L"Kite: CefBrowserHost::CreateBrowser failed\n");
            shared_->pages.erase(tabID);
            --shared_->creating;
            shared_->SignalIfAllClosed();
        }
    }
    shared_->Layout();
}

void Chromium::SetBounds(const RECT& bounds) {
    {
        std::lock_guard lock(shared_->mutex);
        shared_->bounds = bounds;
    }
    shared_->Layout();
}

void Chromium::Focus() {
    auto it = shared_->pages.find(shared_->shown);
    if (it != shared_->pages.end() && it->second.browser) it->second.browser->GetHost()->SetFocus(true);
}

bool Chromium::MayCloseWindow() {
    RunPending();  // a DoClose that just ran may have its note queued behind this WM_CLOSE
    if (!shared_->closing) {
        shared_->closing = true;
        for (auto& [id, page] : shared_->pages) {
            if (page.browser) page.browser->GetHost()->CloseBrowser(true);
        }
    }
    if (shared_->creating.load() > 0) return false;
    for (const auto& [id, page] : shared_->pages) {
        if (!page.browser || !page.closeReady) return false;
    }
    return true;
}

void Chromium::RunPending() {
    std::deque<std::function<void()>> work;
    {
        std::lock_guard lock(shared_->mutex);
        work.swap(shared_->pending);
    }
    for (auto& item : work) item();
}

}  // namespace kite
