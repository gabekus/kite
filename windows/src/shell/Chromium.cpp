// See Chromium.h.

#include "shell/Chromium.h"

#include <algorithm>
#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string_view>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_preference.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/cef_v8.h"
#include "core/Json.h"
#include "core/LiveTabPolicy.h"
#include "core/Uuid.h"
#include "shell/Keys.h"
#include "shell/MainWindow.h"
#include "shell/PerfLog.h"
#include "shell/QuietRun.h"
#include "shell/Text.h"

namespace kite {

namespace {

// The Mac's KCPageBackdropColor: what a page shows before it first paints. A page that sets
// no background of its own still gets white (the DevTools override in OnAfterCreated).
constexpr cef_color_t kPageBackdrop = 0xFF323232;

// The Mac's kEnergySaverPref. Chromium's BatterySaverModeState: 0 = disabled, 1 = on battery
// below 20% (Chrome's default).
constexpr char kEnergySaverPref[] = "performance_tuning.battery_saver_mode.state";

// How long closing the window waits for the browsers before it goes ahead anyway.
constexpr UINT kCloseDeadlineMs = 5'000;
constexpr UINT_PTR kCloseDeadlineTimer = 0x4B43;  // 'KC'; BrowserWindowController's timers are small numbers

// Tells the browser process which renderer hosts each tab's main frame. CEF has no
// browser-side accessor for a browser's render process id, so the renderer sends its own, from
// each new main-frame script context (a navigation that moves the tab to another renderer
// sends again). The Mac's KiteHelper/main.mm and KCBrowser.mm share the name. Sent in every
// run, as on the Mac, whose Task Manager reads it (Windows' will); today only --smoke-test
// uses it, and a message per new main-frame context costs nothing that shows.
constexpr char kRendererPIDMessage[] = "kite.rendererPID";

CefRect ToCefRect(const RECT& r) { return CefRect(r.left, r.top, r.right - r.left, r.bottom - r.top); }

// A page's window: Alloy style, a child of Kite's window over the card, made without
// activating anything (Kite in front of the user's window otherwise; why, and what CEF does
// with the style, in docs/windows.md, Building). OnAfterCreated takes the style off again.
void SetAsPage(CefWindowInfo& info, HWND parent, const RECT& bounds) {
    info.SetAsChild(parent, ToCefRect(bounds));
    info.ex_style |= WS_EX_NOACTIVATE;
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
}

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
    // A quiet run (Start's `quiet`): no page takes the focus or shows a dialog, and the
    // pages' windows never activate. Set before CEF starts, then only read (any thread).
    bool quiet = false;
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
    // The Mac's gEnergySaverEnabled: off unless the user turns it on (SetEnergySaverEnabled).
    std::atomic<bool> energySaverEnabled{false};

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

    // Closes a page Kite is done with (its tab closed or unloaded): hidden at once, then closed
    // on CEF's thread. It's no longer in `pages`, so its DoClose reports no pageClosed.
    void ClosePage(std::map<std::string, Page>::iterator it) {
        CefRefPtr<CefBrowser> browser = it->second.browser;
        const HWND hwnd = it->second.hwnd;
        if (shown == it->first) shown.clear();
        pressurePicks.erase(it->first);
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
    // The Mac's watchMemoryPressure: every page not on screen is asked whether it's busy, and
    // closes unless it is, or has been shown since (LiveTabPolicy::StillHibernates).
    void DiscardUnderPressure();
    // Tabs picked under memory pressure, with when each was last shown then, until their busy
    // check answers (Kite's UI thread only).
    std::map<std::string, Timestamp> pressurePicks;
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
        std::optional<Timestamp> pickedUnderPressure;
        if (auto pick = pressurePicks.extract(tabID)) pickedUnderPressure = pick.mapped();
        if (busy || closing || tabID == shown || it == pages.end() || !it->second.browser || !it->second.browser->IsSame(browser) ||
            it->second.mediaInUse || (events.keepAlive && events.keepAlive(tabID))) {
            return;
        }
        if (pickedUnderPressure) {
            // Under memory pressure any hidden page goes, unless it was shown while it was asked.
            if (!LiveTabPolicy::StillHibernates(pickedUnderPressure, it->second.lastShown, true, tabID == shown)) return;
        } else {
            // Still over the limit, and still among the least recently shown: a tab closed, or
            // this one was shown again, while the page was being asked.
            const std::vector<std::string> over = OverTheLimit();
            if (std::find(over.begin(), over.end(), tabID) == over.end()) return;
        }
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

// On a quiet run's renderers' command lines: the renderer skips window.print() (KiteHelperApp)
// and sends this process message instead.
constexpr char kQuietSwitch[] = "kite-quiet-run";
constexpr char kPrintSkipped[] = "kite.printSkipped";
// The Mac's ApplyEnergySaver, on CEF's UI thread. Energy Saver is a local-state preference, one
// for all profiles: only the global preferences have it, as on the Mac, and no request
// context's (a space's own profile) does.
void ApplyEnergySaver(const Chromium::Shared& shared) {
    CefRefPtr<CefPreferenceManager> prefs = CefPreferenceManager::GetGlobalPreferenceManager();
    if (!prefs) return;
    if (!prefs->HasPreference(kEnergySaverPref)) {
        OutputDebugStringW(L"Kite: Chromium has no Energy Saver preference; left as is\n");
        return;
    }
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetInt(shared.energySaverEnabled ? 1 : 0);
    CefString error;
    if (!prefs->SetPreference(kEnergySaverPref, value, error)) {
        OutputDebugStringW((L"Kite: couldn't set Energy Saver: " + error.ToWString() + L"\n").c_str());
    }
}

// Kite's CefApp in the browser process: one Kite per profile, as Chromium allows. A second
// launch hands over to this one instead of opening a Chrome window of its own.
class KiteApp : public CefApp, public CefBrowserProcessHandler {
public:
    KiteApp(std::shared_ptr<Chromium::Shared> shared, std::vector<std::string> switches)
        : shared_(std::move(shared)), switches_(std::move(switches)) {}
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    // --chromium-switches, in the browser process only (its helpers get what Chromium passes on).
    void OnBeforeCommandLineProcessing(const CefString& processType, CefRefPtr<CefCommandLine> commandLine) override {
        if (!processType.empty()) return;
        for (const std::string& entry : switches_) {
            const size_t equals = entry.find('=');
            if (equals == std::string::npos) {
                commandLine->AppendSwitch(entry);
                continue;
            }
            const std::string name = entry.substr(0, equals);
            std::string value = entry.substr(equals + 1);
            // A feature list adds to what's already there (CEF's own, or an earlier entry), never
            // replaces it: appending a switch again replaces its value.
            if (name == "disable-features" && commandLine->HasSwitch(name)) {
                const std::string existing = commandLine->GetSwitchValue(name).ToString();
                if (!existing.empty()) value = existing + "," + value;
            }
            commandLine->AppendSwitchWithValue(name, value);
        }
    }
    // Where the Mac applies Energy Saver after CefInitialize, and again at its first browser in
    // case the context wasn't ready: here the global preferences exist, and no browser does
    // yet, so one try covers both, and the browsers Chromium makes itself (the Mac's
    // KCDefaultClient) too.
    void OnContextInitialized() override { ApplyEnergySaver(*shared_); }

    bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine>, const CefString&) override {
        shared_->Post([shared = shared_] {
            if (shared->events.relaunched) shared->events.relaunched();
        });
        return true;
    }

    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> commandLine) override {
        if (shared_->quiet && commandLine->GetSwitchValue("type") == "renderer") commandLine->AppendSwitch(kQuietSwitch);
    }

private:
    const std::shared_ptr<Chromium::Shared> shared_;
    const std::vector<std::string> switches_;
    IMPLEMENT_REFCOUNTING(KiteApp);
};

// window.print() in a quiet run's renderer: Alloy shows the system's print dialog, which comes
// to the front (CEF's print handler is Linux only). It returns at once instead, as a cancelled
// one does, and tells the browser process, which writes the KITE_TEST_MODAL line.
class SkipPrint : public CefV8Handler {
public:
    bool Execute(const CefString&, CefRefPtr<CefV8Value>, const CefV8ValueList&, CefRefPtr<CefV8Value>&, CefString&) override {
        if (CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext()) {
            if (CefRefPtr<CefFrame> frame = context->GetFrame()) frame->SendProcessMessage(PID_BROWSER, CefProcessMessage::Create(kPrintSkipped));
        }
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(SkipPrint);
};

// Kite's CefApp in the helpers (the Mac's KiteHelperApp, KiteHelper/main.mm): in a renderer,
// each tab's main frame reports the process it runs in; a quiet run's renderer (`quietRenderer`,
// RunChromiumSubprocess) also skips window.print() in every frame (SkipPrint).
class KiteHelperApp : public CefApp, public CefRenderProcessHandler {
public:
    explicit KiteHelperApp(bool quietRenderer) : quietRenderer_(quietRenderer) {}
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    // Every frame's window, before its scripts run.
    void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        if (quietRenderer_) context->GetGlobal()->SetValue("print", CefV8Value::CreateFunction("print", new SkipPrint), V8_PROPERTY_ATTRIBUTE_NONE);
        if (!frame->IsMain()) return;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kRendererPIDMessage);
        message->GetArgumentList()->SetInt(0, static_cast<int>(GetCurrentProcessId()));
        frame->SendProcessMessage(PID_BROWSER, message);
    }

private:
    const bool quietRenderer_;
    IMPLEMENT_REFCOUNTING(KiteHelperApp);
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
                   public CefDialogHandler,
                   public CefFocusHandler,
                   public CefJSDialogHandler,
                   public CefKeyboardHandler,
                   public CefLoadHandler,
                   public CefRequestHandler,
                   public CefDevToolsMessageObserver {
public:
    // `firstURL` is loaded once the browser exists, after the white-background override.
    PageClient(std::string tabID, std::shared_ptr<Chromium::Shared> shared, std::string firstURL = {})
        : tabID_(std::move(tabID)), shared_(std::move(shared)), firstURL_(std::move(firstURL)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    // Only in a quiet run, which shows no dialog: otherwise Chromium's own.
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return shared_->quiet ? this : nullptr; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return shared_->quiet ? this : nullptr; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    // The renderer's messages (KiteHelperApp): kite.rendererPID, the process now hosting this
    // tab's page; kite.printSkipped, a quiet run's window.print() that didn't open the dialog.
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (source != PID_RENDERER) return false;
        if (message->GetName() == kPrintSkipped) {
            LogSkippedModal(L"print dialog");
            return true;
        }
        if (message->GetName() != kRendererPIDMessage || !frame || !frame->IsMain()) return false;
        const int pid = message->GetArgumentList()->GetInt(0);
        if (pid <= 0) return true;
        shared_->Post([shared = shared_, id = tabID_, browser, pid] {
            if (shared->PageFor(id, browser) && shared->events.rendererStarted) shared->events.rendererStarted(id, static_cast<DWORD>(pid));
        });
        return true;
    }

    // CefLifeSpanHandler

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        perf::Mark("browser-created", tabID_);
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
        const HWND hwnd = browser->GetHost()->GetWindowHandle();
        // Made without activating (SetAsPage); from now on a click activates it as before.
        // A quiet run's pages keep the style: they never activate.
        if (!shared_->quiet) SetWindowLongPtrW(hwnd, GWL_EXSTYLE, GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & ~WS_EX_NOACTIVATE);
        if (!FindPageWidget(hwnd)) {
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
        SetAsPage(windowInfo, shared_->window, bounds);
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
            // Returning false would send WM_CLOSE to Kite's window and quit.
            RunOnCefUIThread([hwnd = browser->GetHost()->GetWindowHandle()] { DestroyWindow(hwnd); });
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
            return true;
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
        shared_->Post([shared = shared_, id = tabID_, browser, text = title.ToString()] {
            if (shared->PageFor(id, browser) && shared->events.titleChanged) shared->events.titleChanged(id, text);
        });
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
        shared_->Post([shared = shared_, id = tabID_, browser, url = urls.empty() ? std::string() : urls.front().ToString()] {
            if (shared->PageFor(id, browser) && shared->events.faviconChanged) shared->events.faviconChanged(id, url);
        });
    }

    // CefDialogHandler, CefJSDialogHandler: a quiet run's pages only

    // No file chooser: cancelled, as if dismissed.
    bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode, const CefString& title, const CefString&,
                      const std::vector<CefString>&, const std::vector<CefString>&, const std::vector<CefString>&,
                      CefRefPtr<CefFileDialogCallback> callback) override {
        LogSkippedModal(std::wstring(mode == FILE_DIALOG_SAVE ? L"save" : L"open") + L" panel: " + title.ToWString());
        callback->Cancel();
        return true;
    }

    // alert, confirm and prompt are suppressed: they return at once, as a dismissed one does.
    bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&, JSDialogType type, const CefString& message, const CefString&,
                    CefRefPtr<CefJSDialogCallback>, bool& suppressMessage) override {
        const wchar_t* kind = type == JSDIALOGTYPE_CONFIRM ? L"confirm" : type == JSDIALOGTYPE_PROMPT ? L"prompt" : L"alert";
        LogSkippedModal(std::wstring(L"javascript ") + kind + L": " + message.ToWString());
        suppressMessage = true;
        return false;
    }

    // Leave Page? Left, as the Mac's forced close and quit answer it (KCBrowser.mm's
    // OnBeforeUnloadDialog), and like it on a later turn of CEF's thread: answering inside this
    // call slowed Chromium's teardown there.
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool isReload, CefRefPtr<CefJSDialogCallback> callback) override {
        LogSkippedModal(isReload ? L"reload page dialog" : L"leave page dialog");
        RunOnCefUIThread([callback] { callback->Continue(true, CefString()); });
        return true;
    }

    // CefFocusHandler

    // While Kite's command bar is open, a page never takes the keyboard back (Chromium
    // focuses a page as it navigates), as the Mac blurs its pages while the bar is open. A
    // quiet run's pages never take it: focusing a page's window activates Kite's.
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return shared_->inputBlocked || shared_->quiet; }

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
            // (KeysComeToKite). Never in a quiet run, whose windows don't take the focus.
            if (!shared_->quiet) SetFocus(shared_->window);
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
        perf::Mark(isLoading ? "load-begin" : "load-end", tabID_);
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

void Chromium::Shared::DiscardUnderPressure() {
    if (closing) return;
    std::set<std::string> keep;
    if (!shown.empty()) keep.insert(shown);
    for (const std::string& id : TabsToDiscardUnderPressure(LivePages(), keep)) {
        const Page& page = pages.at(id);
        if (!page.browser || page.mediaInUse || (events.keepAlive && events.keepAlive(id))) continue;
        pressurePicks[id] = page.lastShown;
        RunOnCefUIThread([browser = page.browser] {
            CefRefPtr<CefClient> client = browser->GetHost()->GetClient();
            if (client) static_cast<PageClient*>(client.get())->CheckBusy(browser);
        });
    }
}

void Chromium::DiscardHiddenPages() { shared_->DiscardUnderPressure(); }

int RunChromiumSubprocess(HINSTANCE instance, void* sandboxInfo) {
    CefMainArgs args(instance);
    // A quiet run's renderer (KiteApp::OnBeforeChildProcessLaunch's switch, on renderers only)
    // skips window.print() (KiteHelperApp).
    CefRefPtr<CefCommandLine> commandLine = CefCommandLine::CreateCommandLine();
    commandLine->InitFromString(GetCommandLineW());
    const bool quietRenderer = commandLine->HasSwitch(kQuietSwitch) && commandLine->GetSwitchValue("type") == "renderer";
    return CefExecuteProcess(args, new KiteHelperApp(quietRenderer), sandboxInfo);
}

Chromium::StartResult Chromium::Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, void* sandboxInfo,
                                      PageEvents events, bool quiet, std::vector<std::string> switches, std::unique_ptr<Chromium>& out,
                                      std::wstring& error) {
    // Chromium wants root_cache_path absolute and every cache_path inside it, else it keeps
    // that profile in memory only; built from the resolved path, like the Mac (realpath).
    std::error_code ec;
    std::filesystem::create_directories(root, ec);
    std::filesystem::path resolved = std::filesystem::weakly_canonical(std::filesystem::absolute(root, ec), ec);
    if (ec || resolved.empty()) resolved = root;

    auto shared = std::make_shared<Shared>();
    shared->window = window;
    shared->quiet = quiet;
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
    // stays its own. The Chromium sandbox is on, as on the Mac (main.cpp's RunWinMain).
    settings.multi_threaded_message_loop = true;
    // Kite.exe's own command line is Kite's (main.cpp), never Chromium switches: without this,
    // CEF reads it as the browser process's, so `Kite.exe /remote-debugging-port=9222` opened a
    // debugging port. The helpers still get theirs, from the command lines Chromium gives them.
    settings.command_line_args_disabled = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.persist_session_cookies = true;
    settings.background_color = kPageBackdrop;
    CefString(&settings.root_cache_path) = resolved.wstring();
    CefString(&settings.cache_path) = (resolved / L"Default").wstring();
    CefString(&settings.log_file) = (resolved / L"chromium.log").wstring();
    CefMainArgs args(instance);
    perf::Mark("cef-init-begin");
    const bool initialized = CefInitialize(args, settings, new KiteApp(shared, std::move(switches)), sandboxInfo);
    perf::Mark("cef-init-end");
    if (!initialized) {
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
        SetAsPage(windowInfo, shared_->window, bounds);
        CefBrowserSettings browserSettings;
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
            // Chrome style's own window, which comes to the front: never in a quiet run.
            if (shared->quiet) {
                LogSkippedModal(L"developer tools");
                break;
            }
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

void Chromium::SetEnergySaverEnabled(bool enabled) {
    shared_->energySaverEnabled = enabled;
    RunOnCefUIThread([shared = shared_] { ApplyEnergySaver(*shared); });
}

void Chromium::ReadEnergySaver(std::function<void(std::optional<int> state)> done) {
    RunOnCefUIThread([shared = shared_, done = std::move(done)]() mutable {
        std::optional<int> state;
        CefRefPtr<CefPreferenceManager> prefs = CefPreferenceManager::GetGlobalPreferenceManager();
        CefRefPtr<CefValue> value = prefs ? prefs->GetPreference(kEnergySaverPref) : nullptr;
        if (value && value->GetType() == VTYPE_INT) state = value->GetInt();
        shared->Post([done = std::move(done), state] { done(state); });
    });
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
