// See Chromium.h.

#include "shell/Chromium.h"

#include <algorithm>
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
#include "include/cef_task.h"
#include "core/Uuid.h"
#include "shell/MainWindow.h"

namespace kite {

namespace {

// The Mac's KCPageBackdropColor: what a page shows before it first paints. A page that sets
// no background of its own still gets white (the DevTools override in OnAfterCreated).
constexpr cef_color_t kPageBackdrop = 0xFF323232;

CefRect ToCefRect(const RECT& r) { return CefRect(r.left, r.top, r.right - r.left, r.bottom - r.top); }

std::filesystem::path Utf8Path(const std::string& text) {
    return std::filesystem::path(std::u8string(reinterpret_cast<const char8_t*>(text.data()), text.size()));
}

// Runs a function on one of CEF's threads.
class FunctionTask : public CefTask {
public:
    explicit FunctionTask(std::function<void()> work) : work_(std::move(work)) {}
    void Execute() override { work_(); }

private:
    std::function<void()> work_;
    IMPLEMENT_REFCOUNTING(FunctionTask);
};

void RunOnCefUIThread(std::function<void()> work) { CefPostTask(TID_UI, new FunctionTask(std::move(work))); }

}  // namespace

struct Chromium::Shared {
    HWND window = nullptr;
    PageEvents events;
    std::filesystem::path root;
    std::atomic<bool> closing{false};

    // Both threads, under the mutex.
    std::mutex mutex;
    std::deque<std::function<void()>> pending;  // for Kite's UI thread
    RECT bounds{};                              // where a new popup's window goes
    int creating = 0;  // asked for (CreateBrowser, an allowed popup), no OnAfterCreated or abort yet
    int alive = 0;     // OnAfterCreated, no OnBeforeClose yet
    // Set while nothing is creating or alive: what the destructor waits for before
    // CefShutdown. Changed only with the counts, under the mutex.
    HANDLE allClosed = nullptr;
    std::map<std::pair<int, int>, std::string> popupTabs;  // (opener browser id, popup_id) → tab id

    // Kite's UI thread only.
    struct Placement {
        bool visible = true;  // on the card, rather than 0×0; SetAsChild windows start there
        RECT rect{};
        bool operator==(const Placement& o) const { return visible == o.visible && EqualRect(&rect, &o.rect); }
    };
    struct Page {
        CefRefPtr<CefBrowser> browser;  // null until OnAfterCreated
        HWND hwnd = nullptr;
        bool closeReady = false;  // through DoClose while closing
        Placement placed;         // as last sent to CEF's thread
    };
    std::map<std::string, Page> pages;  // by tab id
    std::map<std::string, CefRefPtr<CefRequestContext>> contexts;  // by profile directory
    std::string shown;
    bool minimized = false;

    // Hands work to Kite's UI thread; one wake per batch.
    void Post(std::function<void()> work) {
        bool wake;
        {
            std::lock_guard lock(mutex);
            wake = pending.empty();
            pending.push_back(std::move(work));
        }
        if (wake) PostMessageW(window, MainWindow::kWakeMessage, 0, 0);
    }

    void Count(int creatingDelta, int aliveDelta) {
        std::lock_guard lock(mutex);
        creating += creatingDelta;
        alive += aliveDelta;
        if (creating == 0 && alive == 0) SetEvent(allClosed);
        else ResetEvent(allClosed);
    }

    RECT Bounds() {
        std::lock_guard lock(mutex);
        return bounds;
    }

    // Puts the shown tab's window on the card and the rest at 0×0, on CEF's thread, which
    // owns them, and only for windows whose placement changed. 0×0 makes CEF shrink the
    // page's widget, and the widget window itself (Chromium's Chrome_WidgetWin_1, the host
    // window's child) is hidden and shown: that's what Chromium reads as the page's
    // visibility (HWNDMessageHandler's SWP_SHOWWINDOW/SWP_HIDEWINDOW), so a background tab
    // reports hidden and stops drawing, and reports visible again when it's back. Resizing
    // or hiding only CEF's host window left a page hidden for good (seen on Gabe's PC).
    void Layout() {
        const RECT card = Bounds();
        std::vector<std::pair<HWND, Placement>> changes;
        for (auto& [id, page] : pages) {
            if (!page.hwnd) continue;
            Placement wanted;
            wanted.visible = id == shown && !minimized;
            wanted.rect = wanted.visible ? card : RECT{};
            if (wanted == page.placed) continue;
            page.placed = wanted;
            changes.emplace_back(page.hwnd, wanted);
        }
        if (changes.empty()) return;
        // Shown first, then hidden, so the card is never empty in between.
        std::stable_partition(changes.begin(), changes.end(), [](const auto& c) { return c.second.visible; });
        RunOnCefUIThread([changes = std::move(changes)] {
            for (const auto& [host, placement] : changes) {
                const RECT& r = placement.rect;
                const HWND widget = FindWindowExW(host, nullptr, L"Chrome_WidgetWin_1", nullptr);
                if (!placement.visible && widget) ShowWindow(widget, SW_HIDE);
                SetWindowPos(host, nullptr, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                if (placement.visible && widget) ShowWindow(widget, SW_SHOWNA);
            }
        });
    }

    void FocusShown() {
        auto it = pages.find(shown);
        if (it != pages.end() && it->second.browser) it->second.browser->GetHost()->SetFocus(true);
    }

    Page* PageFor(const std::string& tabID, const CefRefPtr<CefBrowser>& browser) {
        auto it = pages.find(tabID);
        if (it == pages.end() || !it->second.browser || !it->second.browser->IsSame(browser)) return nullptr;
        return &it->second;
    }

    void Attach(const std::string& tabID, CefRefPtr<CefBrowser> browser, HWND hwnd) {
        Page& page = pages[tabID];
        page.browser = browser;
        page.hwnd = hwnd;
        page.placed = {true, Bounds()};
        if (closing) {
            browser->GetHost()->CloseBrowser(true);
            return;
        }
        Layout();
        // The window got focus before this page existed (at launch, or when a popup tab
        // replaced its opener): hand it over now.
        if (tabID == shown && GetForegroundWindow() == window) FocusShown();
    }
};

namespace {

// Kite's CefApp in the browser process: one Kite per profile, as Chromium allows. A second
// launch hands over to this one instead of opening a Chrome window of its own.
class KiteApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit KiteApp(std::shared_ptr<Chromium::Shared> shared) : shared_(std::move(shared)) {}
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine>, const CefString&) override {
        shared_->Post([shared = shared_] {
            if (shared->events.relaunched) shared->events.relaunched();
        });
        return true;
    }

private:
    const std::shared_ptr<Chromium::Shared> shared_;
    IMPLEMENT_REFCOUNTING(KiteApp);
};

// One per tab: CEF's handlers for that tab's browser, on CEF's UI thread.
class PageClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler {
public:
    // `firstURL` is loaded once the browser exists, after the white-background override.
    PageClient(std::string tabID, std::shared_ptr<Chromium::Shared> shared, std::string firstURL = {})
        : tabID_(std::move(tabID)), shared_(std::move(shared)), firstURL_(std::move(firstURL)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

    // CefLifeSpanHandler

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        // As the Mac's attachBrowser: the dark backdrop covers only the moments before a page
        // draws; a page with no background of its own is white, as in Chrome.
        CefRefPtr<CefDictionaryValue> color = CefDictionaryValue::Create();
        color->SetInt("r", 255);
        color->SetInt("g", 255);
        color->SetInt("b", 255);
        color->SetDouble("a", 1);
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetDictionary("color", color);
        browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setDefaultBackgroundColorOverride", params);
        if (!firstURL_.empty()) browser->GetMainFrame()->LoadURL(firstURL_);

        const HWND hwnd = browser->GetHost()->GetWindowHandle();
        shared_->Post([shared = shared_, id = tabID_, browser, hwnd] { shared->Attach(id, browser, hwnd); });
        {
            std::lock_guard lock(shared_->mutex);
            std::erase_if(shared_->popupTabs, [this](const auto& entry) { return entry.second == tabID_; });
        }
        shared_->Count(-1, +1);
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
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        client = new PageClient(id, shared_);
        settings.background_color = kPageBackdrop;
        shared_->Count(+1, 0);
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
        AbandonPopup(id);
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        if (!shared_->closing) {
            // The page closed itself (window.close(), as a sign-in popup does when it's done):
            // only its own window goes, as the Mac's KCBrowser tears down just its view.
            // Returning false would send WM_CLOSE to Kite's window and quit.
            RunOnCefUIThread([hwnd = browser->GetHost()->GetWindowHandle()] { DestroyWindow(hwnd); });
            shared_->Post([shared = shared_, id = tabID_] {
                if (shared->events.pageClosed) shared->events.pageClosed(id);
            });
            return true;
        }
        // Kite is closing: ask the window again, which closes once every browser is through
        // here or gone (MayCloseWindow). CEF would send that WM_CLOSE itself when this returns
        // false, but Kite's window is on another thread; an extra one is harmless.
        shared_->Post([shared = shared_, id = tabID_, browser] {
            if (Chromium::Shared::Page* page = shared->PageFor(id, browser)) page->closeReady = true;
            PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        // Popups this page asked for and that never came: no abort follows once it's gone.
        std::vector<std::string> abandoned;
        {
            std::lock_guard lock(shared_->mutex);
            for (auto it = shared_->popupTabs.begin(); it != shared_->popupTabs.end();) {
                if (it->first.first == browser->GetIdentifier()) {
                    abandoned.push_back(std::move(it->second));
                    it = shared_->popupTabs.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (const auto& id : abandoned) AbandonPopup(id);
        shared_->Post([shared = shared_, id = tabID_, browser] {
            if (shared->PageFor(id, browser)) shared->pages.erase(id);
            if (shared->closing) PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        shared_->Count(0, -1);
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
    // A popup that will never be created: its placeholder goes, and Kite moves off its tab.
    void AbandonPopup(const std::string& id) {
        shared_->Post([shared = shared_, id] {
            if (auto it = shared->pages.find(id); it != shared->pages.end() && !it->second.browser) {
                shared->pages.erase(it);
                if (shared->events.pageClosed) shared->events.pageClosed(id);
            }
        });
        shared_->Count(-1, 0);
    }

    const std::string tabID_;
    const std::shared_ptr<Chromium::Shared> shared_;
    const std::string firstURL_;
    IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

int RunChromiumSubprocess(HINSTANCE instance) {
    CefMainArgs args(instance);
    return CefExecuteProcess(args, nullptr, nullptr);
}

Chromium::StartResult Chromium::Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, PageEvents events,
                                      std::unique_ptr<Chromium>& out, std::wstring& error) {
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
        return StartResult::Failed;
    }

    CefSettings settings;
    // CEF's own UI thread, so Kite's message loop (DirectComposition, the device-lost wait)
    // stays its own. The sandbox needs CEF's bootstrap executable and is its own checkpoint
    // (W6b in windows/helix/checkpoints.md); until then pages run unsandboxed, as in any
    // CEF app built without the sandbox.
    settings.multi_threaded_message_loop = true;
    settings.no_sandbox = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.persist_session_cookies = true;
    settings.background_color = kPageBackdrop;
    CefString(&settings.root_cache_path) = resolved.wstring();
    CefString(&settings.cache_path) = (resolved / L"Default").wstring();
    CefString(&settings.log_file) = (resolved / L"chromium.log").wstring();
    CefMainArgs args(instance);
    if (!CefInitialize(args, settings, new KiteApp(shared), nullptr)) {
        const int code = CefGetExitCode();
        CloseHandle(shared->allClosed);
        if (code == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED) return StartResult::AlreadyRunning;
        error = L"CefInitialize failed (exit code " + std::to_wstring(code) + L")";
        return StartResult::Failed;
    }
    out.reset(new Chromium(std::move(shared)));
    return StartResult::Started;
}

Chromium::Chromium(std::shared_ptr<Shared> shared) : shared_(std::move(shared)) {}

Chromium::~Chromium() {
    // The main window is gone by now (Kite declares this before it), and with it every
    // browser's window; CEF finishes closing them on its thread. Bounded, so a wedged
    // browser can't keep Kite from exiting. (A browser not yet through DoClose means Kite
    // left early, on an error path.)
    shared_->closing = true;
    for (auto& [id, page] : shared_->pages) {
        if (page.browser && !page.closeReady) page.browser->GetHost()->CloseBrowser(true);
    }
    // Messages are pumped while waiting: the page windows' teardown on CEF's thread sends
    // messages to this one (their input queues are attached), and a bare wait stalled
    // OnBeforeClose until the timeout, then shut down under live browsers.
    const ULONGLONG deadline = GetTickCount64() + 10'000;
    for (;;) {
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;
        const DWORD woke = MsgWaitForMultipleObjectsEx(1, &shared_->allClosed, static_cast<DWORD>(deadline - now), QS_ALLINPUT,
                                                       MWMO_INPUTAVAILABLE);
        if (woke != WAIT_OBJECT_0 + 1) break;  // signalled, timed out or failed
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    }
    shared_->pages.clear();
    shared_->contexts.clear();
    {
        std::lock_guard lock(shared_->mutex);
        shared_->pending.clear();  // their lambdas hold `shared_`
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
    const bool switched = shared_->shown != tabID;
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
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        CefBrowserSettings browserSettings;
        browserSettings.background_color = kPageBackdrop;
        shared_->pages.try_emplace(tabID);
        shared_->Count(+1, 0);
        // Created blank and loaded once it exists (OnAfterCreated), after the white
        // background override, as the Mac does.
        if (!CefBrowserHost::CreateBrowser(windowInfo, new PageClient(tabID, shared_, url.empty() ? "about:blank" : url), "",
                                           browserSettings, nullptr, context)) {
            OutputDebugStringW(L"Kite: CefBrowserHost::CreateBrowser failed\n");
            shared_->pages.erase(tabID);
            shared_->Count(-1, 0);
        }
    }
    shared_->Layout();
    if (switched && GetForegroundWindow() == shared_->window) shared_->FocusShown();
}

void Chromium::SetBounds(const RECT& bounds) {
    {
        std::lock_guard lock(shared_->mutex);
        shared_->bounds = bounds;
    }
    shared_->minimized = false;
    shared_->Layout();
}

void Chromium::Minimized() {
    shared_->minimized = true;
    shared_->Layout();
}

void Chromium::WindowMoved() {
    auto it = shared_->pages.find(shared_->shown);
    if (it == shared_->pages.end() || !it->second.browser) return;
    RunOnCefUIThread([browser = it->second.browser] { browser->GetHost()->NotifyMoveOrResizeStarted(); });
}

void Chromium::Focus() { shared_->FocusShown(); }

bool Chromium::MayCloseWindow() {
    RunPending();  // a DoClose or OnBeforeClose that just ran may have its note queued
    if (!shared_->closing) {
        shared_->closing = true;
        for (auto& [id, page] : shared_->pages) {
            if (page.browser) page.browser->GetHost()->CloseBrowser(true);
        }
    }
    {
        std::lock_guard lock(shared_->mutex);
        if (shared_->creating > 0) return false;
    }
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
