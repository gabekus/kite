// See Chromium.h.

#include "shell/Chromium.h"

#include <algorithm>
#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <string_view>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_focus_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "core/Uuid.h"
#include "shell/MainWindow.h"

namespace kite {

namespace {

// The Mac's KCPageBackdropColor: what a page shows before it first paints. A page that sets
// no background of its own still gets white (the DevTools override in OnAfterCreated).
constexpr cef_color_t kPageBackdrop = 0xFF323232;

// How long closing the window waits for the browsers before it goes ahead anyway.
constexpr UINT kCloseDeadlineMs = 5'000;
constexpr UINT_PTR kCloseDeadlineTimer = 0x4B43;  // 'KC'; main.cpp's timers are small numbers

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

// Chromium's widget window inside CEF's host window: its one child, of a class Chromium
// numbers as it registers it (Chrome_WidgetWin_0, _1, ...), so matched by prefix.
HWND FindPageWidget(HWND host) {
    const HWND child = GetWindow(host, GW_CHILD);
    wchar_t name[64] = {};
    if (!child || !GetClassNameW(child, name, static_cast<int>(std::size(name)))) return nullptr;
    return std::wstring_view(name).starts_with(L"Chrome_WidgetWin_") ? child : nullptr;
}

}  // namespace

struct Chromium::Shared {
    HWND window = nullptr;
    // Where Post's wakes go: the window until it's about to be destroyed, then null, so CEF's
    // late callbacks never post to a handle Windows may have reused.
    std::atomic<HWND> wakeTarget{nullptr};
    PageEvents events;
    std::filesystem::path root;
    std::atomic<bool> closing{false};
    // BlockInput: the pages take no input (Kite's command bar is over them).
    std::atomic<bool> inputBlocked{false};
    // Keys that reach a page go to Kite: from Ctrl+T in a page until Kite unblocks input.
    std::atomic<bool> keysToKite{false};

    // Both threads, under the mutex.
    std::mutex mutex;
    std::deque<std::function<void()>> pending;  // for Kite's UI thread
    bool wakePosted = false;                    // a kWakeMessage is on its way
    std::atomic<bool> widgetMissing{false};     // a page had no Chromium widget window (FindPageWidget)
    RECT bounds{};                              // where a new popup's window goes
    int creating = 0;  // asked for (CreateBrowser, an allowed popup), no OnAfterCreated or abort yet
    int alive = 0;     // OnAfterCreated, no OnBeforeClose yet
    // Set while nothing is creating or alive: what the destructor waits for before
    // CefShutdown. Changed only with the counts, under the mutex.
    HANDLE allClosed = nullptr;
    std::map<std::pair<int, int>, std::string> popupTabs;  // (opener browser id, popup_id) → tab id

    // Kite's UI thread only.
    struct Placement {
        bool visible = true;  // shown on the card, rather than hidden; SetAsChild windows start shown
        RECT rect{};          // where it was last put; a hidden page keeps its size
        bool operator==(const Placement& o) const { return visible == o.visible && EqualRect(&rect, &o.rect); }
    };
    struct Page {
        CefRefPtr<CefBrowser> browser;  // null until OnAfterCreated
        HWND hwnd = nullptr;
        bool closeReady = false;  // through DoClose while closing
        Placement placed;         // as last sent to CEF's thread
        std::string pendingURL;   // Navigate before the browser existed
    };
    std::map<std::string, Page> pages;  // by tab id
    std::map<std::string, CefRefPtr<CefRequestContext>> contexts;  // by profile directory
    std::string shown;
    bool minimized = false;
    ULONGLONG closingSince = 0;  // when MayCloseWindow started closing
    bool closeForced = false;    // the deadline closed the window before every browser was ready

    // Hands work to Kite's UI thread; one wake per batch.
    void Post(std::function<void()> work) {
        {
            std::lock_guard lock(mutex);
            pending.push_back(std::move(work));
            if (wakePosted) return;
            wakePosted = true;
        }
        const HWND target = wakeTarget.load();
        if (!target || !PostMessageW(target, MainWindow::kWakeMessage, 0, 0)) {
            std::lock_guard lock(mutex);
            wakePosted = false;  // the next post tries again
        }
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

    // Puts the shown tab's window on the card and hides the rest, on CEF's thread, which owns
    // them, and only for windows whose placement changed. The page's widget window
    // (Chromium's Chrome_WidgetWin_N, the host window's child; FindPageWidget) is hidden and
    // shown itself: that's what Chromium reads as the page's visibility (HWNDMessageHandler's
    // SWP_SHOWWINDOW/SWP_HIDEWINDOW), so a background tab reports hidden and stops drawing,
    // and reports visible again when it's back. Hiding only CEF's host window left a page
    // hidden for good (seen on Gabe's PC). A hidden page keeps its size, as on the Mac, which
    // only hides the view: resizing it to 0×0 would give the page a resize to nothing, and a
    // reflow, on every tab switch. It leans on Chromium's window layout, so a missing widget
    // is reported (widgetMissing, which fails --smoke-test); W10's off-screen pages replace it
    // with WasHidden.
    void Layout() {
        const RECT card = Bounds();
        std::vector<std::pair<HWND, Placement>> changes;
        for (auto& [id, page] : pages) {
            if (!page.hwnd) continue;
            Placement wanted;
            wanted.visible = id == shown && !minimized;
            wanted.rect = wanted.visible ? card : page.placed.rect;
            if (wanted == page.placed) continue;
            page.placed = wanted;
            changes.emplace_back(page.hwnd, wanted);
        }
        if (changes.empty()) return;
        // Shown first, then hidden, so the card is never empty in between.
        std::stable_partition(changes.begin(), changes.end(), [](const auto& c) { return c.second.visible; });
        RunOnCefUIThread([changes = std::move(changes)] {
            for (const auto& [host, placement] : changes) {
                const HWND widget = FindPageWidget(host);
                if (placement.visible) {
                    const RECT& r = placement.rect;
                    SetWindowPos(host, nullptr, r.left, r.top, r.right - r.left, r.bottom - r.top,
                                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                    if (widget) ShowWindow(widget, SW_SHOWNA);
                } else {
                    if (widget) ShowWindow(widget, SW_HIDE);
                    ShowWindow(host, SW_HIDE);
                }
            }
        });
    }

    void FocusShown() {
        if (inputBlocked) return;
        auto it = pages.find(shown);
        if (it != pages.end() && it->second.browser) it->second.browser->GetHost()->SetFocus(true);
    }

    Page* PageFor(const std::string& tabID, const CefRefPtr<CefBrowser>& browser) {
        auto it = pages.find(tabID);
        if (it == pages.end() || !it->second.browser || !it->second.browser->IsSame(browser)) return nullptr;
        return &it->second;
    }

    // `closed`: OnAfterCreated already closed it, Kite having started closing by then.
    void Attach(const std::string& tabID, CefRefPtr<CefBrowser> browser, HWND hwnd, bool closed) {
        Page& page = pages[tabID];
        page.browser = browser;
        page.hwnd = hwnd;
        // Never matches, so the first Layout always places it: the window may have been
        // resized or maximized since the browser was asked for.
        page.placed = {true, RECT{-1, -1, -1, -1}};
        if (closing) {
            if (!closed) browser->GetHost()->CloseBrowser(true);  // closing started since
            return;
        }
        Layout();
        if (inputBlocked) RunOnCefUIThread([hwnd] { EnableWindow(hwnd, FALSE); });
        if (!page.pendingURL.empty()) {
            browser->GetMainFrame()->LoadURL(page.pendingURL);
            page.pendingURL.clear();
        }
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
class PageClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefDisplayHandler,
                   public CefFocusHandler,
                   public CefKeyboardHandler,
                   public CefLoadHandler,
                   public CefRequestHandler {
public:
    // `firstURL` is loaded once the browser exists, after the white-background override.
    PageClient(std::string tabID, std::shared_ptr<Chromium::Shared> shared, std::string firstURL = {})
        : tabID_(std::move(tabID)), shared_(std::move(shared)), firstURL_(std::move(firstURL)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

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
        if (!FindPageWidget(hwnd)) {
            shared_->widgetMissing = true;
            OutputDebugStringW(L"Kite: no Chromium widget window in the page's host window; background tabs won't be hidden\n");
        }
        // Kite is already closing (the window may be gone, so Attach may never run): closed
        // here, after Attach is queued, so DoClose's note finds the page.
        const bool closed = shared_->closing;
        shared_->Post([shared = shared_, id = tabID_, browser, hwnd, closed] { shared->Attach(id, browser, hwnd, closed); });
        {
            std::lock_guard lock(shared_->mutex);
            std::erase_if(shared_->popupTabs, [this](const auto& entry) { return entry.second == tabID_; });
        }
        shared_->Count(-1, +1);
        if (closed) browser->GetHost()->CloseBrowser(true);
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

    // CefFocusHandler

    // While Kite's command bar is open, a page never takes the keyboard back (Chromium
    // focuses a page as it navigates), as the Mac blurs its pages while the bar is open.
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return shared_->inputBlocked; }

    // CefKeyboardHandler

    // Kite's own shortcut, Ctrl+T, before the page sees it. The keys after it come to Kite
    // until it unblocks input (Chromium.h, PageEvents::newTab).
    bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle, bool*) override {
        const uint32_t modifiers = event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN);
        // AltGr is Ctrl+Alt: never a Ctrl shortcut.
        const bool ctrl = (modifiers & EVENTFLAG_CONTROL_DOWN) && !(modifiers & EVENTFLAG_ALT_DOWN);
        const bool shift = (modifiers & EVENTFLAG_SHIFT_DOWN) != 0;
        const bool keyDown = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
        if (keyDown && event.windows_key_code == 'T' && modifiers == EVENTFLAG_CONTROL_DOWN) {
            shared_->keysToKite = true;
            // The keyboard goes to Kite's window now, from this thread (the input queues are
            // attached), so the keys typed next wait in Kite's queue as real keys and
            // characters. Kite takes its posted wake before them, so the bar is open by then.
            // Until Kite answers (BlockInput), the page doesn't take the keyboard back.
            shared_->inputBlocked = true;
            SetFocus(shared_->window);
            shared_->Post([shared = shared_] {
                if (shared->events.newTab) shared->events.newTab();
            });
            return true;
        }
        if (!shared_->keysToKite) return false;
        // Keys this page had already taken before the focus moved. Chromium drops the
        // characters of a key whose keydown was handled here, so only the keys themselves
        // (arrows, Backspace, Enter, Escape) reliably arrive this way.
        if (keyDown || event.type == KEYEVENT_CHAR) {
            const bool character = event.type == KEYEVENT_CHAR;
            const unsigned code = character ? static_cast<unsigned>(event.character) : static_cast<unsigned>(event.windows_key_code);
            shared_->Post([shared = shared_, character, code, ctrl, shift] {
                if (shared->events.keyForwarded) shared->events.keyForwarded(character, code, ctrl, shift);
            });
        }
        return true;
    }

    // CefLoadHandler

    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading, bool, bool) override {
        shared_->Post([shared = shared_, id = tabID_, isLoading] {
            if (shared->events.loadingChanged) shared->events.loadingChanged(id, isLoading);
        });
    }

    // CefRequestHandler

    // Ctrl-click and middle-click (a background tab), Ctrl+Shift-click (a foreground one): a
    // new Kite tab, as the Mac's KCBrowser does. Otherwise Alloy would load the link in this
    // tab, replacing the page. Anything else, or without a click, goes on as Chromium decides.
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& targetURL,
                          cef_window_open_disposition_t disposition, bool userGesture) override {
        const bool background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
        const bool foreground = disposition == CEF_WOD_NEW_FOREGROUND_TAB;
        if (!userGesture || !(background || foreground) || targetURL.empty() || shared_->closing) return false;
        shared_->Post([shared = shared_, opener = tabID_, url = targetURL.ToString(), foreground] {
            if (shared->events.openInNewTab) shared->events.openInNewTab(opener, url, foreground);
        });
        return true;
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
    shared->wakeTarget = window;
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

Chromium::~Chromium() { Shutdown(); }

bool Chromium::Shutdown() {
    if (shutDown_) return cleanShutdown_;
    shutDown_ = true;
    shared_->wakeTarget = nullptr;
    // The main window is gone by now, and with it every browser's window; CEF finishes
    // closing them on its thread. Bounded, so a wedged browser can't keep Kite from exiting.
    // (A browser not yet through DoClose means Kite left early, on an error path.)
    shared_->closing = true;
    for (auto& [id, page] : shared_->pages) {
        if (page.browser && !page.closeReady) page.browser->GetHost()->CloseBrowser(true);
    }
    // Messages are pumped while waiting: the page windows' teardown on CEF's thread sends
    // messages to this one (their input queues are attached), and a bare wait stalled
    // OnBeforeClose until the timeout, then shut down under live browsers.
    bool allClosed = false;
    const ULONGLONG deadline = GetTickCount64() + 10'000;
    for (;;) {
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;
        const DWORD woke = MsgWaitForMultipleObjectsEx(1, &shared_->allClosed, static_cast<DWORD>(deadline - now), QS_ALLINPUT,
                                                       MWMO_INPUTAVAILABLE);
        if (woke == WAIT_OBJECT_0) allClosed = true;
        if (woke != WAIT_OBJECT_0 + 1) break;  // signalled, timed out or failed
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    }
    if (!allClosed) OutputDebugStringW(L"Kite: browsers still open after 10 s; shutting Chromium down anyway\n");
    shared_->pages.clear();
    shared_->contexts.clear();
    {
        std::lock_guard lock(shared_->mutex);
        shared_->pending.clear();  // their lambdas hold `shared_`
    }
    CefShutdown();
    CloseHandle(shared_->allClosed);
    cleanShutdown_ = allClosed && !shared_->closeForced;
    return cleanShutdown_;
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

void Chromium::BlockInput(bool blocked) {
    shared_->inputBlocked = blocked;
    shared_->keysToKite = blocked;
    std::vector<HWND> hosts;
    for (const auto& [id, page] : shared_->pages) {
        if (page.hwnd) hosts.push_back(page.hwnd);
    }
    // Disabled, the page windows are skipped when Windows looks for the window under the
    // pointer, so clicks reach Kite's window. On CEF's thread, which owns them.
    if (!hosts.empty()) {
        RunOnCefUIThread([hosts = std::move(hosts), blocked] {
            for (HWND host : hosts) EnableWindow(host, blocked ? FALSE : TRUE);
        });
    }
}

bool Chromium::Navigate(const std::string& tabID, const std::string& url) {
    auto it = shared_->pages.find(tabID);
    if (it == shared_->pages.end() || shared_->closing) return false;
    if (it->second.browser) it->second.browser->GetMainFrame()->LoadURL(url);
    else it->second.pendingURL = url;
    return true;
}

bool Chromium::MayCloseWindow() {
    const bool started = !shared_->closing.exchange(true);  // before the queue, so it opens no new page
    RunPending();  // a DoClose or OnBeforeClose that just ran may have its note queued
    if (started) {
        shared_->closingSince = GetTickCount64();
        for (auto& [id, page] : shared_->pages) {
            if (page.browser) page.browser->GetHost()->CloseBrowser(true);
        }
        // A browser that never answers mustn't keep the window open: after this the close
        // goes ahead, and Shutdown's bounded wait covers the rest. The timer repeats (it goes
        // with the window), since its tick and GetTickCount64's can disagree by one step.
        SetTimer(shared_->window, kCloseDeadlineTimer, kCloseDeadlineMs,
                 [](HWND hwnd, UINT, UINT_PTR, DWORD) { PostMessageW(hwnd, WM_CLOSE, 0, 0); });
    }
    bool ready = true;
    const auto goAhead = [this] {
        shared_->wakeTarget = nullptr;  // the window is destroyed next
        return true;
    };
    {
        std::lock_guard lock(shared_->mutex);
        ready = shared_->creating == 0;
    }
    for (const auto& [id, page] : shared_->pages) {
        if (!ready) break;
        ready = page.browser && page.closeReady;
    }
    if (ready) return goAhead();
    if (GetTickCount64() - shared_->closingSince < kCloseDeadlineMs) return false;
    OutputDebugStringW(L"Kite: a browser didn't close within 5 s; closing the window anyway\n");
    shared_->closeForced = true;
    return goAhead();
}

bool Chromium::PagesCanBeHidden() const { return !shared_->widgetMissing; }

void Chromium::RunPending() {
    std::deque<std::function<void()>> work;
    {
        std::lock_guard lock(shared_->mutex);
        work.swap(shared_->pending);
        shared_->wakePosted = false;
    }
    for (auto& item : work) item();
}

}  // namespace kite
