// See Chromium.h.

#include "shell/Chromium.h"

#include <imm.h>
// GET_X_LPARAM and GET_Y_LPARAM without windowsx.h, whose macros (GetFirstChild...) break cef_dom.h.
#ifndef GET_X_LPARAM
#define GET_X_LPARAM(lp) (static_cast<int>(static_cast<short>(LOWORD(lp))))
#define GET_Y_LPARAM(lp) (static_cast<int>(static_cast<short>(HIWORD(lp))))
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_focus_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "core/Json.h"
#include "core/LiveTabPolicy.h"
#include "core/Uuid.h"
#include "shell/Keys.h"
#include "shell/MainWindow.h"
#include "shell/OffscreenPage.h"

namespace kite {

namespace {

// The Mac's KCPageBackdropColor: what a page shows before it first paints. A page that sets
// no background of its own still gets white (the DevTools override in OnAfterCreated).
constexpr cef_color_t kPageBackdrop = 0xFF323232;

// How long closing the window waits for the browsers before it goes ahead anyway.
constexpr UINT kCloseDeadlineMs = 5'000;
constexpr UINT_PTR kCloseDeadlineTimer = 0x4B43;  // 'KC'; BrowserWindowController's timers are small numbers

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
    // Use Both's "second press" bookkeeping, on CEF's UI thread only (OnPreKeyEvent, OnKeyEvent).
    ShortcutPriorityGate gate;

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
        bool closeWhenMade = false;  // Kite closed its tab before the browser existed
        Placement placed;         // as last sent to CEF's thread
        std::string pendingURL;   // Navigate before the browser existed
        Timestamp lastShown = Now();  // made, or last on the card (the Mac's lastShown)
        bool mediaInUse = false;      // camera, microphone or screen capture (OnMediaAccessChange)
        std::string profile;          // the profile directory it was made in (a popup: its opener's)
    };
    // Kite's UI thread only. Browsers Kite closed (Close) whose DoClose hasn't come back yet:
    // out of `pages`, so their tab can have a new page, but the window waits for them.
    std::vector<CefRefPtr<CefBrowser>> retiring;
    void Retired(const CefRefPtr<CefBrowser>& browser) {
        std::erase_if(retiring, [&](const CefRefPtr<CefBrowser>& b) { return b->IsSame(browser); });
    }
    std::map<std::string, Page> pages;  // by tab id
    std::map<std::string, CefRefPtr<CefRequestContext>> contexts;  // by profile directory
    std::string shown;
    bool minimized = false;
    LiveTabPolicy policy;  // at most six live pages, as the Mac's PagePool
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

    // W10 spike: --osr's off-screen pages (OffscreenOptions). Set before CefInitialize.
    bool osr = false;
    OffscreenOptions offscreen;
    std::unique_ptr<OffscreenPresenter> presenter;
    UINT dpi = USER_DEFAULT_SCREEN_DPI;  // under the mutex
    std::atomic<HCURSOR> cursor{nullptr};
    CefRefPtr<CefBrowser> selfTestBrowser;  // under the mutex: the shown page, for the self-test
    std::string selfTestTitle;              // under the mutex: its last title
    // Kite's UI thread only: the page's share of the window's input.
    bool pageHasKeyboard = false;
    bool mouseInPage = false;
    bool pageCapture = false;
    int clickCount = 0;
    DWORD lastClickTime = 0;
    POINT lastClickAt{};
    UINT lastClickButton = 0;
    float Scale() {
        std::lock_guard lock(mutex);
        return static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
    }
    // The card in DIPs, as the page lays out in it.
    CefRect ViewRect() {
        std::lock_guard lock(mutex);
        const float scale = static_cast<float>(dpi) / USER_DEFAULT_SCREEN_DPI;
        return CefRect(0, 0, std::max(1, static_cast<int>(std::lround((bounds.right - bounds.left) / scale))),
                       std::max(1, static_cast<int>(std::lround((bounds.bottom - bounds.top) / scale))));
    }

    // The shown page on the card, the rest hidden: WasHidden and WasResized instead of
    // windows (the windowed Layout's widget-window trick isn't needed).
    void LayoutOffscreen() {
        const RECT card = Bounds();
        int shownID = 0;
        std::vector<std::pair<CefRefPtr<CefBrowser>, Placement>> changes;
        for (auto& [id, page] : pages) {
            if (!page.browser) continue;
            Placement wanted;
            wanted.visible = id == shown && !minimized;
            wanted.rect = wanted.visible ? card : page.placed.rect;
            if (wanted.visible) shownID = page.browser->GetIdentifier();
            if (wanted == page.placed) continue;
            page.placed = wanted;
            changes.emplace_back(page.browser, wanted);
        }
        if (presenter) presenter->Place(card, 6.0f * Scale(), shownID != 0);
        RunOnCefUIThread([presenter = presenter.get(), shownID, changes = std::move(changes)] {
            if (presenter) presenter->SetShown(shownID);
            for (const auto& [browser, placement] : changes) {
                CefRefPtr<CefBrowserHost> host = browser->GetHost();
                host->WasHidden(!placement.visible);
                if (presenter && !placement.visible) ++presenter->Stats()->hides;
                if (placement.visible) {
                    host->WasResized();
                    host->Invalidate(PET_VIEW);  // a frame now, not on the page's next change
                    if (presenter) ++presenter->Stats()->resizes;
                }
            }
        });
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
        if (osr) return LayoutOffscreen();
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
        if (it != pages.end() && it->second.browser) {
            it->second.browser->GetHost()->SetFocus(true);
            pageHasKeyboard = true;
        }
    }

    Page* PageFor(const std::string& tabID, const CefRefPtr<CefBrowser>& browser) {
        auto it = pages.find(tabID);
        if (it == pages.end() || !it->second.browser || !it->second.browser->IsSame(browser)) return nullptr;
        return &it->second;
    }

    // Closes a page Kite is done with (its tab closed or unloaded): hidden at once, then closed
    // on CEF's thread. It's no longer in `pages`, so its DoClose reports no pageClosed.
    void ClosePage(std::map<std::string, Page>::iterator it) {
        CefRefPtr<CefBrowser> browser = it->second.browser;
        const HWND hwnd = it->second.hwnd;
        if (shown == it->first) shown.clear();
        pages.erase(it);
        retiring.push_back(browser);
        RunOnCefUIThread([browser, hwnd] {
            if (hwnd) {
                if (const HWND widget = FindPageWidget(hwnd)) ShowWindow(widget, SW_HIDE);
                ShowWindow(hwnd, SW_HIDE);
            }
            browser->GetHost()->CloseBrowser(true);
        });
    }

    // The Mac's PagePool.didShow and hibernate: past the limit, the least recently shown
    // pages close, unless one is tied to a popup, using the camera or microphone, or playing
    // sound (asked of the page first, on CEF's thread; Discard gets the answer).
    void Evict();
    // The pages that count, with when each was last shown: not one whose tab already closed
    // (closeWhenMade), which goes on its own once made.
    std::map<std::string, Timestamp> LivePages() const {
        std::map<std::string, Timestamp> live;
        for (const auto& [id, page] : pages) {
            if (!page.closeWhenMade) live.emplace(id, page.lastShown);
        }
        return live;
    }
    std::vector<std::string> OverTheLimit() const {
        std::set<std::string> keep;
        if (!shown.empty()) keep.insert(shown);
        return policy.TabsToEvict(LivePages(), keep);
    }
    void Discard(const std::string& tabID, const CefRefPtr<CefBrowser>& browser, bool busy) {
        auto it = pages.find(tabID);
        if (busy || closing || tabID == shown || it == pages.end() || !it->second.browser || !it->second.browser->IsSame(browser) ||
            it->second.mediaInUse || (events.keepAlive && events.keepAlive(tabID))) {
            return;
        }
        // Still over the limit, and still among the least recently shown: a tab closed, or
        // this one was shown again, while the page was being asked.
        const std::vector<std::string> over = OverTheLimit();
        if (std::find(over.begin(), over.end(), tabID) == over.end()) return;
        ClosePage(it);
        if (events.pageDiscarded) events.pageDiscarded(tabID);
    }

    // `closed`: OnAfterCreated already closed it, Kite having started closing by then.
    void Attach(const std::string& tabID, CefRefPtr<CefBrowser> browser, HWND hwnd, bool closed) {
        Page& page = pages[tabID];
        page.browser = browser;
        page.hwnd = hwnd;
        if (page.closeWhenMade && !closing) {
            // Its tab closed while the browser was being made.
            ClosePage(pages.find(tabID));
            return;
        }
        // Never matches, so the first Layout always places it: the window may have been
        // resized or maximized since the browser was asked for.
        page.placed = {true, RECT{-1, -1, -1, -1}};
        if (closing) {
            if (!closed) browser->GetHost()->CloseBrowser(true);  // closing started since
            return;
        }
        Layout();
        if (inputBlocked && hwnd) RunOnCefUIThread([hwnd] { EnableWindow(hwnd, FALSE); });
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

    // W10 spike: which adapter Chromium's GPU process renders on. It has to be the presenter's
    // (Kite's renderer's) for the shared texture to open without crossing GPUs, and this PC
    // has two. Chromium's own choice already matches (both on the RX 9070 XT, by PDH), so
    // nothing is passed by default. KITE_OSR_LUID=0xHIGH,0xLOW passes --use-adapter-luid,
    // the form Chromium reads (decimal, or one part, is ignored); in CEF 156 here it makes
    // ANGLE's EGL display fail on either adapter, the GPU process crashes three times and
    // Chromium ends the browser process, Kite with it (docs/windows-osr-spike.md).
    void OnBeforeCommandLineProcessing(const CefString& processType, CefRefPtr<CefCommandLine> commandLine) override {
        if (!shared_->osr || !processType.empty()) return;
        char luid[64] = {};
        if (GetEnvironmentVariableA("KITE_OSR_LUID", luid, sizeof luid) > 0) commandLine->AppendSwitchWithValue("use-adapter-luid", luid);
    }

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
// A page's Developer Tools window: only counted in and out (Shared::Count), so Chromium
// isn't shut down under it when Kite quits with it open.
class DevToolsClient : public CefClient, public CefLifeSpanHandler {
public:
    explicit DevToolsClient(std::shared_ptr<Chromium::Shared> shared) : shared_(std::move(shared)) {}
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    void OnAfterCreated(CefRefPtr<CefBrowser>) override { shared_->Count(-1, +1); }
    void OnBeforeClose(CefRefPtr<CefBrowser>) override { shared_->Count(0, -1); }

private:
    std::shared_ptr<Chromium::Shared> shared_;
    IMPLEMENT_REFCOUNTING(DevToolsClient);
};

class PageClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefDisplayHandler,
                   public CefFocusHandler,
                   public CefKeyboardHandler,
                   public CefLoadHandler,
                   public CefRequestHandler,
                   public CefRenderHandler,
                   public CefDevToolsMessageObserver {
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
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return shared_->osr ? this : nullptr; }

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
        devTools_ = browser->GetHost()->AddDevToolsMessageObserver(this);  // for CheckBusy's answers
        // Off-screen (--osr), a page has no window of its own.
        const HWND hwnd = shared_->osr ? nullptr : browser->GetHost()->GetWindowHandle();
        if (!shared_->osr && !FindPageWidget(hwnd)) {
            shared_->widgetMissing = true;
            OutputDebugStringW(L"Kite: no Chromium widget window in the page's host window; background tabs won't be hidden\n");
        }
        // Kite is already closing (the window may be gone, so Attach may never run): closed
        // here, after Attach is queued, so DoClose's note finds the page.
        const bool closed = shared_->closing;
        // Attach is queued before the first load: LoadURL reports loading at once, and a page's
        // news reaches its tab only once Attach has made it the tab's page.
        shared_->Post([shared = shared_, id = tabID_, browser, hwnd, closed] { shared->Attach(id, browser, hwnd, closed); });
        if (!closed && !firstURL_.empty()) browser->GetMainFrame()->LoadURL(firstURL_);
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
        if (shared_->osr) {
            windowInfo.SetAsWindowless(shared_->window);
            windowInfo.shared_texture_enabled = true;
            settings.windowless_frame_rate = shared_->offscreen.frameRate;
        } else {
            windowInfo.SetAsChild(shared_->window, ToCefRect(bounds));
        }
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
            // Only its own window goes, as the Mac's KCBrowser tears down just its view.
            // Returning false would send WM_CLOSE to Kite's window and quit. An off-screen page
            // has no window: false lets CEF close it at once.
            if (!shared_->osr) RunOnCefUIThread([hwnd = browser->GetHost()->GetWindowHandle()] { DestroyWindow(hwnd); });
            shared_->Post([shared = shared_, id = tabID_, browser] {
                // Still its tab's page: it closed itself (window.close(), as a sign-in popup
                // does when it's done), and Kite hears of it. Otherwise Kite closed it.
                if (shared->PageFor(id, browser)) {
                    if (shared->shown == id) shared->shown.clear();
                    shared->pages.erase(id);
                    if (shared->events.pageClosed) shared->events.pageClosed(id);
                } else {
                    shared->Retired(browser);
                }
            });
            return !shared_->osr;
        }
        // Kite is closing: ask the window again, which closes once every browser is through
        // here or gone (MayCloseWindow). CEF would send that WM_CLOSE itself when this returns
        // false, but Kite's window is on another thread; an extra one is harmless.
        shared_->Post([shared = shared_, id = tabID_, browser] {
            if (Chromium::Shared::Page* page = shared->PageFor(id, browser)) page->closeReady = true;
            else shared->Retired(browser);
            PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        devTools_ = nullptr;  // the registration holds this client
        busyChecks_.clear();
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
            shared->Retired(browser);
            if (shared->closing) PostMessageW(shared->window, WM_CLOSE, 0, 0);
        });
        shared_->Count(0, -1);
    }

    // Busy: the Mac's ChromiumEngine.checkBusy asks the page whether it's playing sound or
    // video (camera and microphone come from OnMediaAccessChange). The answer goes to Discard.
    void CheckBusy(CefRefPtr<CefBrowser> browser) {
        if (!devTools_) return;  // closing
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetString("expression", "[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && m.readyState > 2)");
        params->SetBool("returnByValue", true);
        const int id = browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
        if (id) busyChecks_.push_back(id);
    }

    // CefDevToolsMessageObserver

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int messageID, bool success, const void* result,
                                size_t size) override {
        auto it = std::find(busyChecks_.begin(), busyChecks_.end(), messageID);
        if (it == busyChecks_.end()) return;
        busyChecks_.erase(it);
        // {"result":{"type":"boolean","value":true}}; a page that can't answer isn't busy, as on the Mac.
        bool busy = false;
        if (success && result) {
            const auto parsed = json::Parse(std::string_view(static_cast<const char*>(result), size));
            if (const json::Value* answer = std::get_if<json::Value>(&parsed)) {
                const json::Value* inner = answer->Find("result");
                const json::Value* value = inner ? inner->Find("value") : nullptr;
                busy = value && value->AsBool().value_or(false);
            }
        }
        shared_->Post([shared = shared_, id = tabID_, browser, busy] { shared->Discard(id, browser, busy); });
    }

    // CefDisplayHandler

    void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool video, bool audio) override {
        shared_->Post([shared = shared_, id = tabID_, browser, inUse = video || audio] {
            if (Chromium::Shared::Page* page = shared->PageFor(id, browser)) page->mediaInUse = inUse;
        });
    }

    // A page's news reaches its tab only while it's still the tab's page: one Kite closed (its
    // tab closed, or the live-page limit) says nothing more, as the Mac's discard drops onEvent.

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
        if (!frame->IsMain()) return;
        shared_->Post([shared = shared_, id = tabID_, browser, address = url.ToString()] {
            if (shared->PageFor(id, browser) && shared->events.addressChanged) shared->events.addressChanged(id, address);
        });
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        if (shared_->osr) {
            // The first page's (a popup it opens reports nothing here).
            std::lock_guard lock(shared_->mutex);
            if (!shared_->selfTestBrowser) shared_->selfTestBrowser = browser;
            if (shared_->selfTestBrowser->IsSame(browser)) shared_->selfTestTitle = title.ToString();
        }
        shared_->Post([shared = shared_, id = tabID_, browser, text = title.ToString()] {
            if (shared->PageFor(id, browser) && shared->events.titleChanged) shared->events.titleChanged(id, text);
        });
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
        shared_->Post([shared = shared_, id = tabID_, browser, url = urls.empty() ? std::string() : urls.front().ToString()] {
            if (shared->PageFor(id, browser) && shared->events.faviconChanged) shared->events.faviconChanged(id, url);
        });
    }

    // CefDisplayHandler, off-screen: the page's cursor is Kite's to set (W10 spike).
    bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle cursor, cef_cursor_type_t type, const CefCursorInfo&) override {
        if (!shared_->osr) return false;
        shared_->cursor = cursor;
        if (shared_->presenter) {
            ++shared_->presenter->Stats()->cursorChanges;
            shared_->presenter->Stats()->lastCursorType = static_cast<uint64_t>(type);
        }
        shared_->Post([shared = shared_] {
            if (shared->mouseInPage) SetCursor(shared->cursor.load());
        });
        return true;
    }

    // CefRenderHandler (W10 spike, --osr only): the card's size and scale, and its frames.

    void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = shared_->ViewRect(); }

    bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
        const CefRect view = shared_->ViewRect();
        info.device_scale_factor = shared_->Scale();
        info.depth = 24;
        info.depth_per_component = 8;
        info.rect = view;
        info.available_rect = view;
        return true;
    }

    bool GetScreenPoint(CefRefPtr<CefBrowser>, int viewX, int viewY, int& screenX, int& screenY) override {
        const RECT card = shared_->Bounds();
        const float scale = shared_->Scale();
        POINT p{card.left + static_cast<LONG>(std::lround(viewX * scale)), card.top + static_cast<LONG>(std::lround(viewY * scale))};
        if (!ClientToScreen(shared_->window, &p)) return false;
        screenX = p.x;
        screenY = p.y;
        return true;
    }

    void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
        if (!shared_->presenter || browser->GetIdentifier() != shared_->presenter->Shown()) return;
        shared_->presenter->PopupShown(show);
        if (shared_->presenter->NeedsViewRepaint()) browser->GetHost()->Invalidate(PET_VIEW);
    }

    void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override {
        if (!shared_->presenter || browser->GetIdentifier() != shared_->presenter->Shown()) return;
        const float scale = shared_->Scale();
        shared_->presenter->PopupRect(RECT{static_cast<LONG>(std::lround(rect.x * scale)), static_cast<LONG>(std::lround(rect.y * scale)),
                                           static_cast<LONG>(std::lround((rect.x + rect.width) * scale)),
                                           static_cast<LONG>(std::lround((rect.y + rect.height) * scale))});
    }

    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&, const void*, int, int) override {}

    void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser, PaintElementType type, const RectList&,
                            const CefAcceleratedPaintInfo& info) override {
        if (!shared_->presenter) return;
        shared_->presenter->Paint(browser->GetIdentifier(), type == PET_POPUP, info.shared_texture_handle);
        if (shared_->presenter->NeedsViewRepaint()) browser->GetHost()->Invalidate(PET_VIEW);
    }

    // The IME's caret: where the candidate window goes (Kite's own IMM glue isn't written
    // yet; the spike counts the calls).
    void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>, const CefRange&, const RectList& bounds) override {
        if (!shared_->presenter) return;
        ++shared_->presenter->Stats()->imeRangeChanges;
        if (bounds.empty()) return;
        const RECT card = shared_->Bounds();
        const float scale = shared_->Scale();
        const CefRect& last = bounds.back();
        const POINT caret{card.left + static_cast<LONG>(std::lround(last.x * scale)),
                          card.top + static_cast<LONG>(std::lround((last.y + last.height) * scale))};
        shared_->Post([shared = shared_, caret] {
            if (HIMC imc = ImmGetContext(shared->window)) {
                CANDIDATEFORM form{0, CFS_CANDIDATEPOS, caret, {}};
                ImmSetCandidateWindow(imc, &form);
                ImmReleaseContext(shared->window, imc);
            }
        });
    }

    // CefFocusHandler

    // While Kite's command bar is open, a page never takes the keyboard back (Chromium
    // focuses a page as it navigates), as the Mac blurs its pages while the bar is open.
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return shared_->inputBlocked; }

    // CefKeyboardHandler

    // What a key runs, if it's one of Kite's shortcuts (PageEvents::shortcuts), looked up as
    // Kite's window does: a Ctrl+Alt key that types on this layout (AltGr's) is typing.
    const ShortcutTarget* TargetOf(const CefKeyEvent& event) const {
        const bool keyDown = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
        if (!keyDown) return nullptr;
        return ShortcutForKey(shared_->events.shortcuts, static_cast<UINT>(event.windows_key_code),
                              (event.modifiers & EVENTFLAG_CONTROL_DOWN) != 0, (event.modifiers & EVENTFLAG_ALT_DOWN) != 0,
                              (event.modifiers & EVENTFLAG_SHIFT_DOWN) != 0);
    }

    // Runs a shortcut's command on Kite's thread. New Tab also moves the keyboard: the keys
    // typed after it come to Kite until it unblocks input (Chromium.h, PageEvents::newTab).
    void Run(const ShortcutTarget& target) {
        if (target.command->id == "newTab") {
            shared_->keysToKite = true;
            // The keyboard goes to Kite's window now, from this thread (the input queues are
            // attached), so the keys typed next wait in Kite's queue as real keys and
            // characters. Until Kite answers (BlockInput), the page doesn't take it back.
            shared_->inputBlocked = true;
            shared_->Post([shared = shared_] {
                if (shared->events.newTab) shared->events.newTab();
            });
            // After the wake is posted; a key Kite still takes first opens the bar itself
            // (KeysComeToKite).
            SetFocus(shared_->window);
            return;
        }
        shared_->Post([shared = shared_, command = target.command] {
            if (shared->events.command) shared->events.command(command->id);
        });
    }

    // Kite's shortcuts, before the page sees the key, by the command's priority, as the Mac's
    // ShortcutPriorityRouter. A held key repeats its command, as the Mac's menus do.
    bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle, bool* isKeyboardShortcut) override {
        const uint32_t modifiers = event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN);
        // AltGr is Ctrl+Alt: never a Ctrl shortcut.
        const bool ctrl = (modifiers & EVENTFLAG_CONTROL_DOWN) && !(modifiers & EVENTFLAG_ALT_DOWN);
        const bool shift = (modifiers & EVENTFLAG_SHIFT_DOWN) != 0;
        const bool keyDown = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
        // While the keys go to Kite (after Ctrl+T), only New Tab's own keys are still Kite's.
        const ShortcutTarget* target = TargetOf(event);
        if (target && (!shared_->keysToKite || target->command->id == "newTab")) {
            switch (target->priority) {
            case KeyShortcutPriority::OverrideWebView:
                Run(*target);
                return true;
            case KeyShortcutPriority::PromptAfterConsumedByWebView: {
                // The second press soon after one the page kept runs Kite's command.
                const double now = static_cast<double>(GetTickCount64()) / 1000;
                if (shared_->gate.Press(target->command->id, 0, now, (event.modifiers & EVENTFLAG_IS_REPEAT) != 0)) {
                    Run(*target);
                    return true;
                }
                break;
            }
            case KeyShortcutPriority::Low:
                break;
            }
            // The page first; OnKeyEvent runs the command if it doesn't use the key.
            if (!shared_->keysToKite) {
                if (isKeyboardShortcut) *isKeyboardShortcut = true;
                return false;
            }
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

    // A key the page didn't use: a Prefer Websites or Use Both shortcut's command runs now.
    bool OnKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle) override {
        const ShortcutTarget* target = TargetOf(event);
        if (!target || shared_->keysToKite) return false;
        shared_->gate.CommandRan(target->command->id);
        Run(*target);
        return true;
    }

    // CefLoadHandler

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool, bool) override {
        shared_->Post([shared = shared_, id = tabID_, browser, isLoading] {
            if (shared->PageFor(id, browser) && shared->events.loadingChanged) shared->events.loadingChanged(id, isLoading);
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
    // CEF's UI thread only.
    CefRefPtr<CefRegistration> devTools_;
    std::vector<int> busyChecks_;  // Runtime.evaluate message ids awaiting an answer
    IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

void Chromium::Shared::Evict() {
    if (pages.size() <= policy.maxLiveTabs) return;
    for (const std::string& id : OverTheLimit()) {
        const Page& page = pages.at(id);
        // A page still being made can't be asked; it counts, and goes on a later pass.
        if (!page.browser || page.mediaInUse || (events.keepAlive && events.keepAlive(id))) continue;
        RunOnCefUIThread([browser = page.browser] {
            // Every page's client is a PageClient (Show and OnBeforePopup make them).
            CefRefPtr<CefClient> client = browser->GetHost()->GetClient();
            if (client) static_cast<PageClient*>(client.get())->CheckBusy(browser);
        });
    }
}

int RunChromiumSubprocess(HINSTANCE instance) {
    CefMainArgs args(instance);
    return CefExecuteProcess(args, nullptr, nullptr);
}

Chromium::StartResult Chromium::Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, PageEvents events,
                                      std::unique_ptr<Chromium>& out, std::wstring& error, OffscreenOptions offscreen) {
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
    if (offscreen.enabled) {
        shared->osr = true;
        shared->offscreen = offscreen;
        shared->presenter = OffscreenPresenter::Create(offscreen.adapter, error);
        if (!shared->presenter) {
            CloseHandle(shared->allClosed);
            return StartResult::Failed;
        }
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
    settings.windowless_rendering_enabled = shared->osr;
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
    shared_->retiring.clear();  // browsers Kite closed that never came back (a forced close)
    shared_->contexts.clear();
    {
        std::lock_guard lock(shared_->mutex);
        shared_->pending.clear();  // their lambdas hold `shared_`
        shared_->selfTestBrowser = nullptr;
    }
    CefShutdown();
    shared_->presenter.reset();  // on Kite's thread, which owns its visual
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
    if (auto it = shared_->pages.find(tabID); it != shared_->pages.end() && it->second.browser &&
                                                               !it->second.profile.empty() && it->second.profile != profileDirectory) {
        // Its space is in another profile now: the page closes and loads again in that one
        // (the Mac's discardPagesInWrongProfile, done here when it's next shown).
        shared_->ClosePage(it);
        if (shared_->events.pageDiscarded) shared_->events.pageDiscarded(tabID);
    }
    const bool switched = shared_->shown != tabID;
    shared_->shown = tabID;
    if (auto it = shared_->pages.find(tabID); it != shared_->pages.end()) {
        // Its tab came back (Ctrl+Shift+T) before the page being made for it was closed.
        it->second.closeWhenMade = false;
        it->second.lastShown = Now();
        // A popup's page counts as its tab's space's, as the Mac's openTab(with:) records it.
        if (it->second.profile.empty()) it->second.profile = profileDirectory;
    }
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
        CefBrowserSettings browserSettings;
        if (shared_->osr) {
            // W10 spike: rendered off-screen into a shared D3D11 texture (OnAcceleratedPaint).
            windowInfo.SetAsWindowless(shared_->window);
            windowInfo.shared_texture_enabled = true;
            browserSettings.windowless_frame_rate = shared_->offscreen.frameRate;
        } else {
            windowInfo.SetAsChild(shared_->window, ToCefRect(bounds));
        }
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        browserSettings.background_color = kPageBackdrop;
        shared_->pages.try_emplace(tabID).first->second.profile = profileDirectory;
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
    shared_->Evict();
}

void Chromium::ShowNothing() {
    shared_->shown.clear();
    shared_->Layout();
    // The keyboard was in the page that went: it comes back to Kite's window (else keys such
    // as Ctrl+Shift+T go nowhere), unless the command bar has it.
    if (!shared_->inputBlocked && GetForegroundWindow() == shared_->window) SetFocus(shared_->window);
}

void Chromium::Close(const std::string& tabID) {
    auto it = shared_->pages.find(tabID);
    if (it == shared_->pages.end() || shared_->closing) return;
    if (it->second.browser) {
        shared_->ClosePage(it);
    } else {
        // Still being made (a popup, or a page just asked for): closed once it exists.
        it->second.closeWhenMade = true;
        if (shared_->shown == tabID) shared_->shown.clear();
    }
    shared_->Layout();
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
    // Off-screen, Kite simply stops forwarding input (ForwardInput); no windows to disable.
    // Disabled, the page windows are skipped when Windows looks for the window under the
    // pointer, so clicks reach Kite's window. On CEF's thread, which owns them.
    if (!hosts.empty()) {
        RunOnCefUIThread([hosts = std::move(hosts), blocked] {
            for (HWND host : hosts) EnableWindow(host, blocked ? FALSE : TRUE);
        });
    }
}

bool Chromium::KeysComeToKite() const { return shared_->keysToKite; }

bool Chromium::Navigate(const std::string& tabID, const std::string& url) {
    auto it = shared_->pages.find(tabID);
    if (it == shared_->pages.end() || shared_->closing) return false;
    if (it->second.browser) it->second.browser->GetMainFrame()->LoadURL(url);
    else it->second.pendingURL = url;
    return true;
}

bool Chromium::Act(PageAction action) {
    auto it = shared_->pages.find(shared_->shown);
    if (it == shared_->pages.end() || !it->second.browser || shared_->closing) return false;
    RunOnCefUIThread([shared = shared_, browser = it->second.browser, action] {
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        switch (action) {
        case PageAction::Back: browser->GoBack(); break;
        case PageAction::Forward: browser->GoForward(); break;
        // As the Mac's reload: a page still loading stops instead.
        case PageAction::Reload:
            if (browser->IsLoading()) browser->StopLoad();
            else browser->Reload();
            break;
        case PageAction::ReloadIgnoringCache: browser->ReloadIgnoreCache(); break;
        case PageAction::Stop: browser->StopLoad(); break;
        case PageAction::DevTools: {
            // The page is closing (Kite quit after asking): no window that would hold it up.
            if (shared->closing) break;
            // Already open: CEF brings that window forward and makes no browser.
            if (host->HasDevTools()) {
                host->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
                break;
            }
            // In a window of its own, as Chrome's undocked tools (the Mac docks none either),
            // counted with Kite's pages so Chromium's shutdown waits for it too. Chrome style
            // (the default): CEF 156 makes no Alloy-style DevTools.
            CefWindowInfo info;
            info.SetAsPopup(nullptr, "Developer Tools");
            shared->Count(+1, 0);
            host->ShowDevTools(info, new DevToolsClient(shared), CefBrowserSettings(), CefPoint());
            break;
        }
        }
    });
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
    // And for the pages Kite closed, so none outlives its parent window.
    ready = ready && shared_->retiring.empty();
    if (ready) return goAhead();
    if (GetTickCount64() - shared_->closingSince < kCloseDeadlineMs) return false;
    OutputDebugStringW(L"Kite: a browser didn't close within 5 s; closing the window anyway\n");
    shared_->closeForced = true;
    return goAhead();
}

bool Chromium::PagesCanBeHidden() const { return !shared_->widgetMissing; }

// MARK: W10 spike: off-screen pages (--osr)

namespace {

uint32_t MouseModifiers(WPARAM wParam) {
    uint32_t m = 0;
    if (wParam & MK_CONTROL) m |= EVENTFLAG_CONTROL_DOWN;
    if (wParam & MK_SHIFT) m |= EVENTFLAG_SHIFT_DOWN;
    if (GetKeyState(VK_MENU) < 0) m |= EVENTFLAG_ALT_DOWN;
    if (wParam & MK_LBUTTON) m |= EVENTFLAG_LEFT_MOUSE_BUTTON;
    if (wParam & MK_MBUTTON) m |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
    if (wParam & MK_RBUTTON) m |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
    if (GetKeyState(VK_CAPITAL) & 1) m |= EVENTFLAG_CAPS_LOCK_ON;
    if (GetKeyState(VK_NUMLOCK) & 1) m |= EVENTFLAG_NUM_LOCK_ON;
    return m;
}

// As CEF's cefclient (osr_window_win.cc) builds a key event's modifiers.
uint32_t KeyModifiers(WPARAM wParam, LPARAM lParam) {
    uint32_t m = 0;
    if (GetKeyState(VK_SHIFT) < 0) m |= EVENTFLAG_SHIFT_DOWN;
    if (GetKeyState(VK_CONTROL) < 0) m |= EVENTFLAG_CONTROL_DOWN;
    if (GetKeyState(VK_MENU) < 0) m |= EVENTFLAG_ALT_DOWN;
    if (GetKeyState(VK_NUMLOCK) & 1) m |= EVENTFLAG_NUM_LOCK_ON;
    if (GetKeyState(VK_CAPITAL) & 1) m |= EVENTFLAG_CAPS_LOCK_ON;
    switch (wParam) {
    case VK_RETURN:
        if ((lParam >> 16) & KF_EXTENDED) m |= EVENTFLAG_IS_KEY_PAD;
        break;
    case VK_INSERT: case VK_DELETE: case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
    case VK_UP: case VK_DOWN: case VK_LEFT: case VK_RIGHT:
        if (!((lParam >> 16) & KF_EXTENDED)) m |= EVENTFLAG_IS_KEY_PAD;
        break;
    case VK_NUMLOCK: case VK_NUMPAD0: case VK_NUMPAD1: case VK_NUMPAD2: case VK_NUMPAD3: case VK_NUMPAD4:
    case VK_NUMPAD5: case VK_NUMPAD6: case VK_NUMPAD7: case VK_NUMPAD8: case VK_NUMPAD9:
    case VK_DIVIDE: case VK_MULTIPLY: case VK_SUBTRACT: case VK_ADD: case VK_DECIMAL: case VK_CLEAR:
        m |= EVENTFLAG_IS_KEY_PAD;
        break;
    case VK_SHIFT:
        if (GetKeyState(VK_LSHIFT) < 0) m |= EVENTFLAG_IS_LEFT;
        else if (GetKeyState(VK_RSHIFT) < 0) m |= EVENTFLAG_IS_RIGHT;
        break;
    case VK_CONTROL:
        if (GetKeyState(VK_LCONTROL) < 0) m |= EVENTFLAG_IS_LEFT;
        else if (GetKeyState(VK_RCONTROL) < 0) m |= EVENTFLAG_IS_RIGHT;
        break;
    case VK_MENU:
        if (GetKeyState(VK_LMENU) < 0) m |= EVENTFLAG_IS_LEFT;
        else if (GetKeyState(VK_RMENU) < 0) m |= EVENTFLAG_IS_RIGHT;
        break;
    default: break;
    }
    if (lParam & (1 << 30)) m |= EVENTFLAG_IS_REPEAT;
    return m;
}

}  // namespace

bool Chromium::Offscreen() const { return shared_->osr; }

void Chromium::UseCompositor(IDCompositionDevice* device, IDCompositionVisual* pageLayer) {
    if (!shared_->presenter) return;
    shared_->presenter->Attach(device, pageLayer);
    for (auto& [id, page] : shared_->pages) page.placed.rect = RECT{-1, -1, -1, -1};  // placed again
    shared_->Layout();
}

void Chromium::SetDpi(UINT dpi) {
    std::lock_guard lock(shared_->mutex);
    shared_->dpi = dpi;
}

HCURSOR Chromium::PageCursor() const { return shared_->mouseInPage ? shared_->cursor.load() : nullptr; }

bool Chromium::PagePresented() const { return shared_->presenter && shared_->presenter->HasPresented(); }

bool Chromium::PageMasksCorners() const { return shared_->presenter && shared_->presenter->MasksCorners(); }

bool Chromium::ForwardInput(UINT message, WPARAM wParam, LPARAM lParam) {
    Shared& s = *shared_;
    if (!s.osr || s.inputBlocked || s.closing) return false;
    auto it = s.pages.find(s.shown);
    if (it == s.pages.end() || !it->second.browser) return false;
    CefRefPtr<CefBrowserHost> host = it->second.browser->GetHost();
    const RECT card = s.Bounds();
    const float scale = s.Scale();
    auto toView = [&](POINT p) {
        CefMouseEvent event;
        // DIPs, as the page lays out: at a fractional scale this rounds to a whole DIP.
        event.x = static_cast<int>(std::floor((p.x - card.left) / scale));
        event.y = static_cast<int>(std::floor((p.y - card.top) / scale));
        event.modifiers = MouseModifiers(wParam);
        return event;
    };
    auto forwarded = [&] {
        if (s.presenter) s.presenter->InputForwarded();
        return true;
    };
    switch (message) {
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN: case WM_RBUTTONUP: case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_MBUTTONDBLCLK: {
        const POINT p{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        const bool inCard = PtInRect(&card, p) != FALSE;
        const bool down = message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MBUTTONDOWN ||
                          message == WM_LBUTTONDBLCLK || message == WM_RBUTTONDBLCLK || message == WM_MBUTTONDBLCLK;
        if (!inCard && !s.pageCapture) {
            if (s.mouseInPage) {
                s.mouseInPage = false;
                host->SendMouseMoveEvent(toView(p), true);
            }
            // A press elsewhere in Kite's window takes the keyboard from the page.
            if (down && s.pageHasKeyboard) {
                s.pageHasKeyboard = false;
                host->SetFocus(false);
            }
            return false;
        }
        CefMouseEvent event = toView(p);
        if (message == WM_MOUSEMOVE) {
            if (!s.mouseInPage) {
                s.mouseInPage = true;
                TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, s.window, 0};
                TrackMouseEvent(&track);
            }
            host->SendMouseMoveEvent(event, false);
            return forwarded();
        }
        cef_mouse_button_type_t button = MBT_LEFT;
        UINT buttonMessage = WM_LBUTTONDOWN;
        if (message == WM_RBUTTONDOWN || message == WM_RBUTTONUP || message == WM_RBUTTONDBLCLK) {
            button = MBT_RIGHT;
            buttonMessage = WM_RBUTTONDOWN;
        } else if (message == WM_MBUTTONDOWN || message == WM_MBUTTONUP || message == WM_MBUTTONDBLCLK) {
            button = MBT_MIDDLE;
            buttonMessage = WM_MBUTTONDOWN;
        }
        if (down) {
            // Off-screen, Chromium doesn't count clicks: double and triple clicks by time and
            // distance, as Windows does.
            const DWORD time = static_cast<DWORD>(GetMessageTime());
            const bool again = s.clickCount > 0 && s.lastClickButton == buttonMessage && time - s.lastClickTime <= GetDoubleClickTime() &&
                               std::abs(p.x - s.lastClickAt.x) <= GetSystemMetrics(SM_CXDOUBLECLK) / 2 &&
                               std::abs(p.y - s.lastClickAt.y) <= GetSystemMetrics(SM_CYDOUBLECLK) / 2;
            s.clickCount = again ? s.clickCount + 1 : 1;
            s.lastClickTime = time;
            s.lastClickAt = p;
            s.lastClickButton = buttonMessage;
            SetCapture(s.window);
            s.pageCapture = true;
            if (!s.pageHasKeyboard) {
                s.pageHasKeyboard = true;
                host->SetFocus(true);
            }
        } else if (!(wParam & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON))) {
            s.pageCapture = false;
            if (GetCapture() == s.window) ReleaseCapture();
        }
        host->SendMouseClickEvent(event, button, !down, std::max(1, s.clickCount));
        return forwarded();
    }
    case WM_MOUSELEAVE:
        if (s.mouseInPage && !s.pageCapture) {
            s.mouseInPage = false;
            CefMouseEvent event;
            host->SendMouseMoveEvent(event, true);
        }
        return false;  // the sidebar's hover ends too
    case WM_CAPTURECHANGED:
        s.pageCapture = false;
        return false;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL: {
        POINT p{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};  // screen px
        ScreenToClient(s.window, &p);
        if (!PtInRect(&card, p)) return false;
        CefMouseEvent event = toView(p);
        event.modifiers = MouseModifiers(GET_KEYSTATE_WPARAM(wParam));
        const int delta = GET_WHEEL_DELTA_WPARAM(wParam);
        const bool shifted = (GET_KEYSTATE_WPARAM(wParam) & MK_SHIFT) != 0;
        // WM_MOUSEHWHEEL's positive is right, CEF's is left; Shift turns a wheel sideways.
        int dx = 0, dy = 0;
        if (message == WM_MOUSEHWHEEL) dx = -delta;
        else if (shifted) dx = delta;
        else dy = delta;
        host->SendMouseWheelEvent(event, dx, dy);
        return forwarded();
    }
    case WM_KEYDOWN: case WM_KEYUP: case WM_SYSKEYDOWN: case WM_SYSKEYUP:
    case WM_CHAR: case WM_SYSCHAR: {
        if (!s.pageHasKeyboard) return false;
        // Alt+F4 still closes the window.
        if ((message == WM_SYSKEYDOWN || message == WM_SYSKEYUP) && wParam == VK_F4) return false;
        CefKeyEvent event;
        event.windows_key_code = static_cast<int>(wParam);
        event.native_key_code = static_cast<int>(lParam);
        event.is_system_key = message == WM_SYSCHAR || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP;
        if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) event.type = KEYEVENT_RAWKEYDOWN;
        else if (message == WM_KEYUP || message == WM_SYSKEYUP) event.type = KEYEVENT_KEYUP;
        else event.type = KEYEVENT_CHAR;
        event.modifiers = KeyModifiers(wParam, lParam);
        host->SendKeyEvent(event);
        return forwarded();
    }
    case WM_KILLFOCUS:
        if (s.pageHasKeyboard) host->SetFocus(false);
        s.pageHasKeyboard = false;
        return false;
    default:
        return false;
    }
}

std::wstring Chromium::ReadBackShownPage(Pixels& pixels) {
    if (!shared_->presenter) return L"no off-screen pages (--osr)";
    auto it = shared_->pages.find(shared_->shown);
    if (it == shared_->pages.end() || !it->second.browser) return L"no page is shown";
    shared_->presenter->RequestReadBack();
    RunOnCefUIThread([browser = it->second.browser] { browser->GetHost()->Invalidate(PET_VIEW); });
    std::wstring error;
    auto frame = shared_->presenter->TakeReadBack(5'000, error);
    if (!frame) return error;
    pixels = std::move(*frame);
    return {};
}

void Chromium::RunSelfTest(const std::filesystem::path& logPath) {
    // On a thread of its own, so it can wait between steps: it posts Win32 messages to Kite's
    // window (the path a real mouse and keyboard take, through ForwardInput) and calls CEF's
    // IME methods directly, since no IME can be driven without real input (and switching
    // this window's input method would switch the user's). The page
    // (windows/helix/pages/osr-selftest.html) reports in its title.
    std::thread([shared = shared_, logPath] {
        std::ofstream log(logPath, std::ios::binary | std::ios::trunc);
        auto wait = [](int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); };
        auto browser = [&]() -> CefRefPtr<CefBrowser> {
            std::lock_guard lock(shared->mutex);
            return shared->selfTestBrowser;
        };
        auto at = [&](int x, int y) {
            const RECT card = shared->Bounds();
            const float scale = shared->Scale();
            return MAKELPARAM(card.left + static_cast<int>(std::lround(x * scale)), card.top + static_cast<int>(std::lround(y * scale)));
        };
        auto post = [&](UINT message, WPARAM wParam, LPARAM lParam) { PostMessageW(shared->window, message, wParam, lParam); };
        auto click = [&](int x, int y) {
            post(WM_MOUSEMOVE, 0, at(x, y));
            post(WM_LBUTTONDOWN, MK_LBUTTON, at(x, y));
            post(WM_LBUTTONUP, 0, at(x, y));
        };
        auto key = [&](UINT vk) {
            const LPARAM scan = static_cast<LPARAM>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC)) << 16;
            post(WM_KEYDOWN, vk, 1 | scan);
            post(WM_KEYUP, vk, 1 | scan | (LPARAM{1} << 30) | (LPARAM{1} << 31));
        };
        auto report = [&](const char* step) {
            wait(500);
            std::string title;
            {
                std::lock_guard lock(shared->mutex);
                title = shared->selfTestTitle;
            }
            const OffscreenStats& st = *shared->presenter->Stats();
            log << step << "\t" << title << "\tpopupShows=" << st.popupShows << " popupPaints=" << st.popupPaints
                << " cursorChanges=" << st.cursorChanges << " lastCursorType=" << st.lastCursorType
                << " imeRangeChanges=" << st.imeRangeChanges << " presents=" << st.presents << " hides=" << st.hides
                << " ignoredPaints=" << st.ignoredPaints << "\n";
            log.flush();
        };
        for (int i = 0; i < 300 && !shared->presenter->HasPresented(); ++i) wait(100);
        wait(1000);
        report("loaded");
        // A click in the text field, then typed characters (WM_CHAR, as TranslateMessage makes).
        click(170, 35);
        report("clicked input");
        post(WM_CHAR, L'a', 1);
        post(WM_CHAR, L'b', 1);
        report("typed ab");
        // Committed IME text as DefWindowProc delivers it without Kite's IMM glue: WM_IME_CHAR,
        // which it turns into WM_CHAR.
        post(WM_IME_CHAR, 0x6F22, 1);  // 漢
        report("WM_IME_CHAR");
        // CEF's IME API, as Kite's IMM glue would call it from WM_IME_COMPOSITION.
        if (CefRefPtr<CefBrowser> b = browser()) {
            std::vector<CefCompositionUnderline> underlines(1);
            underlines[0].range = CefRange(0, 2);
            underlines[0].color = 0xFF000000;
            underlines[0].thick = false;
            b->GetHost()->ImeSetComposition(L"かな", underlines, CefRange(UINT32_MAX, UINT32_MAX), CefRange(2, 2));
            report("ImeSetComposition");
            b->GetHost()->ImeCommitText(L"字", CefRange(UINT32_MAX, UINT32_MAX), 0);
            report("ImeCommitText");
        }
        // The cursor over a link.
        post(WM_MOUSEMOVE, 0, at(100, 155));
        report("hover link");
        // A <select>: its popup opens, then Down and Enter pick the second option.
        click(120, 95);
        report("clicked select");
        key(VK_DOWN);
        report("down in popup");
        key(VK_RETURN);
        report("picked option");
        // The wheel scrolls the page (WM_MOUSEWHEEL has screen coordinates).
        {
            const LPARAM c = at(300, 300);
            POINT p{GET_X_LPARAM(c), GET_Y_LPARAM(c)};
            ClientToScreen(shared->window, &p);
            post(WM_MOUSEWHEEL, MAKEWPARAM(0, static_cast<WORD>(-WHEEL_DELTA * 3)), MAKELPARAM(p.x, p.y));
        }
        report("wheel");
        // A double click selects a word.
        post(WM_LBUTTONDOWN, MK_LBUTTON, at(60, 260));
        post(WM_LBUTTONUP, 0, at(60, 260));
        post(WM_LBUTTONDOWN, MK_LBUTTON, at(60, 260));
        post(WM_LBUTTONUP, 0, at(60, 260));
        report("double click");
        // A popup opens as a tab in front, so this page is hidden (WasHidden): its
        // visibilityState says so, and it stops painting.
        click(80, 335);
        wait(1500);
        report("popup tab shown, opener hidden");
        log << "done\n";
        log.flush();
        PostMessageW(shared->window, WM_CLOSE, 0, 0);
    }).detach();
}

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
