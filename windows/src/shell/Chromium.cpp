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
#include "include/cef_find_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_download_handler.h"
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
#include "core/DownloadsModel.h"
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

struct Chromium::Shared : std::enable_shared_from_this<Chromium::Shared> {
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
    // KeepKeyboard: a navigation doesn't move the keyboard to the page.
    std::atomic<bool> kiteKeepsKeyboard{false};
    // BlockInput(false) is enabling the page windows again (CEF's thread only).
    bool reenabling = false;
    // Use Both's "second press" bookkeeping, on CEF's UI thread only (OnPreKeyEvent, OnKeyEvent).
    ShortcutPriorityGate gate;
    // The Mac's gEnergySaverEnabled: on unless the user turns it off, as in Chrome
    // (SetEnergySaverEnabled).
    std::atomic<bool> energySaverEnabled{true};

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

    // The overlay's hole as each page's window has it: the find bar's rounded rectangle, in the
    // window's own px (its region's), or none.
    struct Hole {
        RECT rect{};
        int radius = 0;
        bool operator==(const Hole& o) const { return EqualRect(&rect, &o.rect) && radius == o.radius; }
    };

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
        Hole hole;                    // the overlay's hole as last sent, in its window's px
        // Find asked for before the browser existed (Ctrl+F straight after a new tab): run once
        // it's made, the last one asked for.
        struct PendingFind {
            std::string text;
            bool forward = true, findNext = false;
        };
        std::optional<PendingFind> pendingFind;
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
    Hole overlayHole;  // SetOverlayHole's, in client px
    LiveTabPolicy policy;  // at most six live pages, as the Mac's PagePool
    ULONGLONG closingSince = 0;  // when MayCloseWindow started closing
    bool closeForced = false;    // the deadline closed the window before every browser was ready

    // MARK: Downloads (KCBrowser.mm's LiveDownloads and its download handler)

    // A download Kite is following. Chromium numbers each browser context's downloads from 1,
    // so a download is its id plus its context's key ("" for the default profile, the folder
    // for another; a page's client knows its profile). Its callback is kept until it completes
    // or is canceled (interrupted too, as it can resume), so Kite can cancel it. Under
    // downloadsMutex: CEF's thread follows them, Kite's cancels and asks which page has one.
    struct LiveDownload {
        std::string context;
        uint32_t id = 0;
        // The browser that last reported it (Chromium carries a download over to another page
        // of its profile when its own closes).
        int browser = 0;
        CefRefPtr<CefDownloadItemCallback> callback;
        // When its bytes last moved (GetTickCount64), for a parked page's stall bound.
        int64_t received = 0;
        ULONGLONG progressedAt = GetTickCount64();
        bool running = true;  // in progress (not interrupted, finished or a store package)
        // A Chrome Web Store package (IsExtensionPackage, decided once, when it's first seen):
        // cancelled until Kite can install extensions (W27a), and never listed.
        bool storePackage = false;
    };
    // Interrupted downloads stay followed and a destroyed browser may never send a final
    // update, so past this many the oldest one not running goes. A running one never does.
    static constexpr size_t kMaxLiveDownloads = 200;
    mutable std::mutex downloadsMutex;
    std::vector<LiveDownload> liveDownloads;
    // The paths given to downloads still running, by download (DownloadKey): reserved as each
    // one's free name is found, so a burst of same-name downloads gets a path each.
    DownloadReservations reservations{[](const std::filesystem::path& a, const std::filesystem::path& b) {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
    }};
    // Downloads whose name is being found on CEF's file thread, with Chromium's callback (held
    // here rather than in the task, so a shutdown lets go of them before CEF goes).
    std::map<std::string, CefRefPtr<CefBeforeDownloadCallback>> resolving;
    static std::string DownloadKey(const std::string& context, uint32_t id) { return context + '\n' + std::to_string(id); }
    // SetDownloadLocations' answer, read as each download starts.
    std::map<std::string, ProfileSettings> downloadSettings;
    std::filesystem::path downloadFolder;
    // Reports waiting for Kite's thread, one per download (a newer one replaces it in place,
    // keeping the order downloads first reported), and whether a delivery is on its way.
    std::vector<DownloadUpdate> downloadReports;
    bool downloadsPosted = false;
    uint64_t reportsFromChromium = 0, reportsDelivered = 0;
    // Pages closed while one of their downloads ran (Kite's UI thread): hidden, muted and on
    // about:blank, and closed once their downloads are done, so Chromium keeps reporting them
    // (Shared::ReleaseParked). Once a page's browser is gone Chromium may stop reporting its
    // downloads (it hands them to another page of the profile only if one is there as it goes,
    // seen both ways on the PC). `window`: a page past DoClose (it closed itself), whose window
    // is destroyed then; else one Kite closed, which CloseBrowser closes then. A parked page opens
    // no popups or tabs, shows no dialogs (Leave Page is answered Leave), and one whose downloads
    // haven't moved for ParkedStallCheck::kStallMs is cancelled and goes.
    struct Parked {
        CefRefPtr<CefBrowser> browser;
        HWND window = nullptr;
    };
    std::vector<Parked> parked;
    // The stall check's timer on Kite's window (BrowserWindowController hands its WM_TIMER to
    // Chromium::HandleTimer), running only while a page is parked (ParkedStallCheck).
    ParkedStallCheck stallCheck;  // Kite's UI thread
    // Under downloadsMutex: which browsers are parked (CEF's thread asks, for popups, dialogs and
    // stalls), and, for --save-log only (logParked), what each parked page was as it went.
    std::set<int> parkedIDs;
    bool logParked = false;
    std::vector<std::pair<std::string, bool>> parkedLog;
    std::atomic<int> parkedLeavesAnswered{0};  // Leave Page dialogs a parked page asked for

    bool IsParked(int browser) const {
        std::lock_guard lock(downloadsMutex);
        return parkedIDs.contains(browser);
    }
    // Any thread: the page is parked from now on (before it's quietened, so the Leave Page dialog
    // its navigation asks for is answered as a parked page's).
    void MarkParked(int browser) {
        std::lock_guard lock(downloadsMutex);
        parkedIDs.insert(browser);
    }
    // Kite's thread. Parks a page (or gives a parked one the window it now has to destroy).
    void Park(const CefRefPtr<CefBrowser>& browser, HWND pageWindow) {
        for (Parked& page : parked) {
            if (!page.browser->IsSame(browser)) continue;
            if (pageWindow) page.window = pageWindow;
            return;
        }
        parked.push_back({browser, pageWindow});
        MarkParked(browser->GetIdentifier());
        FollowParked();
    }
    // CEF's thread: a page that's parked plays nothing and runs nothing (its camera, microphone,
    // sound and scripts go with the navigation); its downloads belong to its profile, not the
    // page, and go on (checked on the PC).
    static void Quieten(const CefRefPtr<CefBrowser>& browser) {
        browser->GetHost()->SetAudioMuted(true);
        if (const CefRefPtr<CefFrame> frame = browser->GetMainFrame()) frame->LoadURL("about:blank");
    }
    // Closes a parked page now, on CEF's thread, noting what it was for --save-log.
    void CloseParked(const Parked& page) {
        bool log = false;
        {
            std::lock_guard lock(downloadsMutex);
            parkedIDs.erase(page.browser->GetIdentifier());
            log = logParked;
        }
        RunOnCefUIThread([this, page, log] {
            if (log) {
                const CefRefPtr<CefFrame> frame = page.browser->GetMainFrame();
                std::pair<std::string, bool> entry(frame ? frame->GetURL().ToString() : std::string(), page.browser->GetHost()->IsAudioMuted());
                std::lock_guard lock(downloadsMutex);
                parkedLog.push_back(std::move(entry));
            }
            if (page.window) DestroyWindow(page.window);
            else page.browser->GetHost()->CloseBrowser(true);
        });
    }
    // Kite's thread: the stall check's timer runs exactly while a page is parked.
    void FollowParked() {
        switch (stallCheck.Parked(closing ? 0 : parked.size())) {
        case ParkedStallCheck::Timer::Start:
            SetTimer(window, Chromium::kStallTimer, static_cast<UINT>(ParkedStallCheck::kEveryMs), nullptr);
            break;
        case ParkedStallCheck::Timer::Stop: KillTimer(window, Chromium::kStallTimer); break;
        case ParkedStallCheck::Timer::Leave: break;
        }
    }
    // Kite's thread, the timer's tick: a parked page's downloads that haven't moved for kStallMs
    // are cancelled (CefDownloadItemCallback may be called on any thread); their page then goes.
    int stallTicks = 0;  // the timer's ticks (Kite's thread), for the save log
    void CancelStalled() {
        ++stallTicks;
        std::vector<CefRefPtr<CefDownloadItemCallback>> stalled;
        {
            std::lock_guard lock(downloadsMutex);
            const ULONGLONG now = GetTickCount64();
            for (const LiveDownload& download : liveDownloads) {
                if (download.running && download.callback && parkedIDs.contains(download.browser) &&
                    ParkedStallCheck::Stalled(download.progressedAt, now)) {
                    stalled.push_back(download.callback);
                }
            }
        }
        for (const auto& callback : stalled) callback->Cancel();
    }

    LiveDownload* FindLiveDownload(const std::string& context, uint32_t id) {
        for (LiveDownload& download : liveDownloads) {
            if (download.id == id && download.context == context) return &download;
        }
        return nullptr;
    }
    LiveDownload& AddLiveDownload(const std::string& context, uint32_t id) {
        if (liveDownloads.size() >= kMaxLiveDownloads) {
            auto stale = std::find_if(liveDownloads.begin(), liveDownloads.end(), [](const LiveDownload& d) { return !d.running; });
            if (stale != liveDownloads.end()) {
                reservations.Release(DownloadKey(stale->context, stale->id));
                liveDownloads.erase(stale);
            }
        }
        LiveDownload download;
        download.context = context;
        download.id = id;
        liveDownloads.push_back(std::move(download));
        return liveDownloads.back();
    }

    // Whether a download of the browser's is still running (any thread).
    bool RunningDownloadsIn(int browser) const {
        std::lock_guard lock(downloadsMutex);
        return std::any_of(liveDownloads.begin(), liveDownloads.end(),
                           [&](const LiveDownload& d) { return d.browser == browser && d.running && !d.storePackage; });
    }
    // Kite's thread: a parked page whose downloads are done closes now.
    void ReleaseParked() {
        for (auto it = parked.begin(); it != parked.end();) {
            if (closing || RunningDownloadsIn(it->browser->GetIdentifier())) {
                ++it;
                continue;
            }
            CloseParked(*it);
            it = parked.erase(it);
        }
        FollowParked();
    }

    // The settings for a download from `profile` (DownloadLocation.settings; a profile Kite
    // doesn't know reads Default's) and the folder for one that chose none. No disk here: the
    // chosen folder's existence is checked with the name, on CEF's file thread.
    std::pair<ProfileSettings, std::filesystem::path> DownloadSettings(const std::string& profile) {
        std::lock_guard lock(downloadsMutex);
        auto it = downloadSettings.find(profile);
        if (it == downloadSettings.end()) it = downloadSettings.find(BrowserState::kDefaultProfile);
        return {it != downloadSettings.end() ? it->second : ProfileSettings(), downloadFolder};
    }

    // CEF's thread: hands the report to Kite's, folded into one still waiting for the same
    // download, so one delivery carries each download's latest however often Chromium reports.
    void ReportDownload(DownloadUpdate update) {
        bool post = false;
        {
            std::lock_guard lock(downloadsMutex);
            ++reportsFromChromium;
            auto waiting = std::find_if(downloadReports.begin(), downloadReports.end(), [&](const DownloadUpdate& u) {
                return u.engineID == update.engineID && u.engineContext == update.engineContext;
            });
            if (waiting != downloadReports.end()) *waiting = std::move(update);
            else downloadReports.push_back(std::move(update));
            post = !std::exchange(downloadsPosted, true);
        }
        if (post) Post([this] { DeliverDownloads(); });
    }

    // Kite's thread.
    void DeliverDownloads() {
        std::vector<DownloadUpdate> reports;
        {
            std::lock_guard lock(downloadsMutex);
            reports.swap(downloadReports);
            downloadsPosted = false;
            reportsDelivered += reports.size();
        }
        if (!events.downloadUpdated) return;
        for (const DownloadUpdate& update : reports) events.downloadUpdated(update);
    }

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
    // Also the overlay's hole: in the shown page's window, in none of the others. A window's
    // region clips its hit-testing (and its drawing, where the bar covers it anyway), so a click
    // there falls through to Kite's window behind it. One task on CEF's thread places and cuts
    // each window that changed; a region set just before the window moves is set without its own
    // repaint (bRedraw FALSE), so a resize step repaints once.
    void Layout() {
        const RECT card = Bounds();
        struct Change {
            HWND host;
            std::optional<Placement> placement;  // when it moved, showed or hid
            std::optional<Hole> hole;            // when its hole changed
        };
        std::vector<Change> changes;
        for (auto& [id, page] : pages) {
            if (!page.hwnd) continue;
            Change change{page.hwnd, std::nullopt, std::nullopt};
            Placement wanted;
            wanted.visible = id == shown && !minimized;
            wanted.rect = wanted.visible ? card : page.placed.rect;
            if (!(wanted == page.placed)) {
                page.placed = wanted;
                change.placement = wanted;
            }
            Hole hole;
            if (wanted.visible && !IsRectEmpty(&overlayHole.rect)) {
                hole = overlayHole;
                OffsetRect(&hole.rect, -card.left, -card.top);
            }
            if (!(hole == page.hole)) {
                page.hole = hole;
                change.hole = hole;
            }
            if (change.placement || change.hole) changes.push_back(change);
        }
        if (changes.empty()) return;
        // Shown first, then hidden, so the card is never empty in between.
        std::stable_partition(changes.begin(), changes.end(), [](const Change& c) { return !c.placement || c.placement->visible; });
        RunOnCefUIThread([changes = std::move(changes)] {
            for (const Change& change : changes) {
                const HWND host = change.host;
                if (change.hole) {
                    // Repainted by the move that follows, when one does.
                    const BOOL redraw = change.placement && change.placement->visible ? FALSE : TRUE;
                    const Hole& hole = *change.hole;
                    if (IsRectEmpty(&hole.rect)) {
                        SetWindowRgn(host, nullptr, redraw);
                    } else {
                        // As big as a window can be, less the hole, so it holds through any resize.
                        // CreateRoundRectRgn leaves out its right and bottom edges, as RECTs do.
                        HRGN region = CreateRectRgn(0, 0, 32767, 32767);
                        HRGN cut = CreateRoundRectRgn(hole.rect.left, hole.rect.top, hole.rect.right + 1, hole.rect.bottom + 1,
                                                      2 * hole.radius, 2 * hole.radius);
                        if (region && cut) CombineRgn(region, region, cut, RGN_DIFF);
                        if (cut) DeleteObject(cut);
                        // The window owns the region once it's set.
                        if (region && !SetWindowRgn(host, region, redraw)) DeleteObject(region);
                    }
                }
                if (!change.placement) continue;
                const HWND widget = FindPageWidget(host);
                if (change.placement->visible) {
                    const RECT& r = change.placement->rect;
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

    // As the Mac's ChromiumEngine.find: a new search only highlights, so it steps once more to
    // make the first match active (1/N), as Chrome does.
    static void RunFind(CefRefPtr<CefBrowser> browser, std::string text, bool forward, bool findNext) {
        RunOnCefUIThread([browser, text = std::move(text), forward, findNext] {
            CefRefPtr<CefBrowserHost> host = browser->GetHost();
            host->Find(text, forward, false, findNext);
            if (!findNext) host->Find(text, forward, false, true);
        });
    }

    void FocusShown() {
        // Nor while Kite's find field has it: a page made after Ctrl+F (its Attach) leaves it there.
        if (inputBlocked || kiteKeepsKeyboard) return;
        auto it = pages.find(shown);
        if (it == pages.end() || !it->second.browser) return;
        // Asked again on CEF's thread, as it runs: a field of Kite's may have taken the keyboard
        // since (Ctrl+F as the command bar closed), and the page doesn't take it back then.
        RunOnCefUIThread([shared = shared_from_this(), browser = it->second.browser] {
            if (!shared->inputBlocked && !shared->kiteKeepsKeyboard) browser->GetHost()->SetFocus(true);
        });
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
        // One of its downloads is running: the page stays, hidden, until it's done, so Chromium
        // keeps reporting it (Shared::ReleaseParked); the window's close still closes it.
        const bool park = !closing && RunningDownloadsIn(browser->GetIdentifier());
        if (park) Park(browser, nullptr);
        RunOnCefUIThread([browser, hwnd, park] {
            if (hwnd) {
                if (const HWND widget = FindPageWidget(hwnd)) ShowWindow(widget, SW_HIDE);
                ShowWindow(hwnd, SW_HIDE);
            }
            if (park) Quieten(browser);
            else browser->GetHost()->CloseBrowser(true);
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
            it->second.mediaInUse || RunningDownloadsIn(browser->GetIdentifier()) || (events.keepAlive && events.keepAlive(tabID))) {
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
        if (page.pendingFind) {
            RunFind(browser, page.pendingFind->text, page.pendingFind->forward, page.pendingFind->findNext);
            page.pendingFind.reset();
        }
        // The window got focus before this page existed (at launch, or when a popup tab
        // replaced its opener): hand it over now.
        if (tabID == shown && GetForegroundWindow() == window) FocusShown();
    }
};

namespace {

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
// On a quiet run's renderers' command lines: the renderer skips window.print() (KiteHelperApp)
// and sends this process message instead.
constexpr char kQuietSwitch[] = "kite-quiet-run";
constexpr char kPrintSkipped[] = "kite.printSkipped";

// Kite's CefApp in the browser process: one Kite per profile, as Chromium allows. A second
// launch hands over to this one instead of opening a Chrome window of its own.
class KiteApp : public CefApp, public CefBrowserProcessHandler {
public:
    KiteApp(std::shared_ptr<Chromium::Shared> shared, std::vector<std::string> switches)
        : shared_(std::move(shared)), switches_(std::move(switches)) {}
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    // Where the Mac applies Energy Saver after CefInitialize, and again at its first browser in
    // case the context wasn't ready: here the global preferences exist, and no browser does
    // yet, so one try covers both, and the browsers Chromium makes itself (the Mac's
    // KCDefaultClient) too.
    void OnContextInitialized() override { ApplyEnergySaver(*shared_); }
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
                   public CefDownloadHandler,
                   public CefFocusHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefKeyboardHandler,
                   public CefLoadHandler,
                   public CefRequestHandler,
                   public CefDevToolsMessageObserver {
public:
    // `firstURL` is loaded once the browser exists, after the white-background override.
    // `profile`: the profile folder whose request context the page is in (a popup is in its
    // opener's), which names its downloads' context.
    PageClient(std::string tabID, std::shared_ptr<Chromium::Shared> shared, std::string profile, std::string firstURL = {})
        : tabID_(std::move(tabID)), shared_(std::move(shared)), profile_(std::move(profile)), firstURL_(std::move(firstURL)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    // Only in a quiet run, which shows no dialog: otherwise Chromium's own.
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return shared_->quiet ? this : nullptr; }
    // Always: a parked page's dialogs are answered here too (its tab has closed); others go on to
    // Chromium's own unless the run is quiet.
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
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
        // A parked page's tab has closed: it opens nothing.
        if (shared_->closing || shared_->IsParked(browser->GetIdentifier())) return true;
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
        client = new PageClient(id, shared_, profile_);
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
            const HWND hwnd = browser->GetHost()->GetWindowHandle();
            // A page that closed itself while one of its downloads runs is hidden instead, and its
            // window destroyed once the download is done, so Chromium keeps reporting it.
            const bool park = shared_->RunningDownloadsIn(browser->GetIdentifier());
            if (park) {
                if (const HWND widget = FindPageWidget(hwnd)) ShowWindow(widget, SW_HIDE);
                ShowWindow(hwnd, SW_HIDE);
                shared_->MarkParked(browser->GetIdentifier());
                Chromium::Shared::Quieten(browser);
            } else {
                RunOnCefUIThread([hwnd] { DestroyWindow(hwnd); });
            }
            shared_->Post([shared = shared_, id = tabID_, browser, park, hwnd] {
                // Still its tab's page: it closed itself (window.close(), as a sign-in popup
                // does when it's done), and Kite hears of it. Otherwise Kite closed it.
                if (shared->PageFor(id, browser)) {
                    if (shared->shown == id) shared->shown.clear();
                    shared->pages.erase(id);
                    if (park) {
                        // The window's close waits for it, as for a page Kite closed.
                        shared->retiring.push_back(browser);
                        shared->Park(browser, hwnd);
                        // Its download may have finished on the way here.
                        shared->ReleaseParked();
                    }
                    if (shared->events.pageClosed) shared->events.pageClosed(id);
                } else if (park) {
                    // Kite had closed it (it's retiring already): a parked page that closed itself,
                    // or one whose download started after ClosePage looked. Its window, kept for
                    // the download, is destroyed once that's done.
                    shared->Park(browser, hwnd);
                    shared->ReleaseParked();
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

    // CefDownloadHandler (KCBrowser.mm's)

    // The context key of this page's downloads ("" for the default profile, as the Mac's).
    std::string DownloadContext() const { return profile_ == BrowserState::kDefaultProfile ? std::string() : profile_; }

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, const CefString& suggestedName,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        const std::string context = DownloadContext();
        const uint32_t id = item->GetId();
        bool store = false;
        {
            std::lock_guard lock(shared_->downloadsMutex);
            Chromium::Shared::LiveDownload* live = shared_->FindLiveDownload(context, id);
            if (!live) {
                live = &shared_->AddLiveDownload(context, id);
                live->storePackage =
                    IsExtensionPackage(item->GetMimeType().ToString(), suggestedName.ToString(), item->GetOriginalUrl().ToString());
            }
            live->browser = browser->GetIdentifier();
            store = live->storePackage;
        }
        if (store) {
            // Nothing on Windows installs extensions yet (W27a): cancelled, rather than left in a
            // folder nobody reads. Returning false cancels it (Alloy's default).
            OutputDebugStringW((L"Kite: cancelled a Chrome Web Store package (" + suggestedName.ToWString() +
                                L"): extensions can't be installed yet\n").c_str());
            return false;
        }
        auto [settings, fallback] = shared_->DownloadSettings(profile_);
        if (settings.promptsForDownload && shared_->quiet) {
            // A quiet run shows no save panel: it answers as a dismissed one (SkippedModal's
            // openOrSavePanel), and Chromium cancels the download. Refused, it no longer holds
            // its page open.
            LogSkippedModal(L"save panel: " + suggestedName.ToWString());
            {
                std::lock_guard lock(shared_->downloadsMutex);
                if (auto* live = shared_->FindLiveDownload(context, id)) live->running = false;
            }
            shared_->Post([shared = shared_] { shared->ReleaseParked(); });
            return false;
        }
        Resolve(shared_, context, id, suggestedName.ToString(), std::move(settings), std::move(fallback), callback);
        return true;
    }

    // The download's folder and free name are found on CEF's file thread (a chosen folder can be
    // a network share that takes seconds to answer), where DownloadReservations finds and holds
    // the name in one step, so no two downloads get one path; then it's handed to Chromium on its
    // UI thread. Kite's download lock is never held while the disk is asked.
    static void Resolve(std::shared_ptr<Chromium::Shared> shared, std::string context, uint32_t id, std::string name,
                        ProfileSettings settings, std::filesystem::path fallback, CefRefPtr<CefBeforeDownloadCallback> callback) {
        namespace fs = std::filesystem;
        const std::string key = Chromium::Shared::DownloadKey(context, id);
        {
            std::lock_guard lock(shared->downloadsMutex);
            shared->resolving[key] = callback;
        }
        CefPostTask(TID_FILE_USER_BLOCKING, new FunctionTask([shared, context, id, key, name, settings, fallback] {
            const fs::path folder = settings.DownloadFolder(fallback, [](const std::string& chosen) {
                std::error_code error;
                return fs::is_directory(fs::path(std::u8string(chosen.begin(), chosen.end())), error);
            });
            std::error_code ignored;
            fs::create_directories(folder, ignored);
            // A path that can't be checked counts as free, as the Mac's fileExists says no. The
            // whole path stays within MAX_PATH, as Chrome keeps it.
            const std::optional<fs::path> path = shared->reservations.Reserve(
                key, name, folder,
                [](const fs::path& candidate) {
                    std::error_code error;
                    return fs::exists(candidate, error);
                },
                MAX_PATH - 1);
            RunOnCefUIThread([shared, context, id, key, path, prompt = settings.promptsForDownload] {
                CefRefPtr<CefBeforeDownloadCallback> callback;
                {
                    std::lock_guard lock(shared->downloadsMutex);
                    if (auto it = shared->resolving.find(key); it != shared->resolving.end()) {
                        callback = it->second;
                        shared->resolving.erase(it);
                    }
                    Chromium::Shared::LiveDownload* live = shared->FindLiveDownload(context, id);
                    // Shut down, or canceled while its name was found: its name goes back.
                    if (!callback || !live) {
                        shared->reservations.Release(key);
                        return;
                    }
                    if (!path) {
                        // kUniqueNameTries names taken: the callback goes unused, which cancels it,
                        // and a page parked meanwhile may go.
                        live->running = false;
                        OutputDebugStringW(L"Kite: no free name for a download; cancelled\n");
                        shared->Post([shared] { shared->ReleaseParked(); });
                        return;
                    }
                }
                // With Ask, Chromium's Save As opens in the folder with the name filled in.
                callback->Continue(path->wstring(), prompt);
            });
        }));
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        const std::string context = DownloadContext();
        const std::wstring fullPath = item->GetFullPath().ToWString();
        const bool finished = item->IsComplete() || item->IsCanceled();
        bool settled = false;
        {
            std::lock_guard lock(shared_->downloadsMutex);
            Chromium::Shared::LiveDownload* live = shared_->FindLiveDownload(context, item->GetId());
            // A repeat after the download finished (Kite already let it go): nothing new to report.
            if (!live && !item->IsInProgress() && !item->IsInterrupted()) return;
            if (!live) {
                // Chromium can report a download before asking where it goes: decided now, once.
                live = &shared_->AddLiveDownload(context, item->GetId());
                live->storePackage = IsExtensionPackage(item->GetMimeType().ToString(), item->GetSuggestedFileName().ToString(),
                                                        item->GetOriginalUrl().ToString());
            }
            live->browser = browser->GetIdentifier();
            // A store package isn't the user's download: never listed.
            const bool store = live->storePackage;
            const std::string key = Chromium::Shared::DownloadKey(context, item->GetId());
            if (!store) {
                // The Save As dialog may have put it somewhere else: hold the path it really uses.
                if (!fullPath.empty()) shared_->reservations.Hold(key, std::filesystem::path(fullPath));
                live->callback = callback;
            }
            if (item->GetReceivedBytes() != live->received) {
                live->received = item->GetReceivedBytes();
                live->progressedAt = GetTickCount64();
            }
            const bool wasRunning = live->running;
            live->running = item->IsInProgress();
            settled = wasRunning && !live->running;
            if (finished) {
                shared_->reservations.Release(key);
                shared_->liveDownloads.erase(shared_->liveDownloads.begin() + (live - shared_->liveDownloads.data()));
            }
            if (store) return;
        }
        // A page Kite closed while this ran may close now.
        if (settled) shared_->Post([shared = shared_] { shared->ReleaseParked(); });
        DownloadUpdate update;
        update.engineID = item->GetId();
        update.engineContext = context;
        if (!context.empty()) update.profileDirectory = profile_;
        update.url = item->GetOriginalUrl().ToString();
        update.path = Narrow(fullPath);
        update.state = item->IsComplete()      ? DownloadState::Complete
                       : item->IsCanceled()    ? DownloadState::Canceled
                       : item->IsInterrupted() ? DownloadState::Interrupted
                                               : DownloadState::InProgress;
        update.receivedBytes = item->GetReceivedBytes();
        update.totalBytes = item->GetTotalBytes();
        update.speed = item->GetCurrentSpeed();
        shared_->ReportDownload(std::move(update));
    }

    // CefDialogHandler (a quiet run's pages only) and CefJSDialogHandler (every page: a quiet
    // run's and a parked page's dialogs are answered here, the rest go on to Chromium's own)

    // No file chooser: cancelled, as if dismissed.
    bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode, const CefString& title, const CefString&,
                      const std::vector<CefString>&, const std::vector<CefString>&, const std::vector<CefString>&,
                      CefRefPtr<CefFileDialogCallback> callback) override {
        LogSkippedModal(std::wstring(mode == FILE_DIALOG_SAVE ? L"save" : L"open") + L" panel: " + title.ToWString());
        callback->Cancel();
        return true;
    }

    // alert, confirm and prompt from a parked page or in a quiet run are suppressed: they return
    // at once, as a dismissed one does. Any other page's are Chromium's own.
    bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString&, JSDialogType type, const CefString& message, const CefString&,
                    CefRefPtr<CefJSDialogCallback>, bool& suppressMessage) override {
        // A parked page's tab has closed: nothing it says is shown.
        if (shared_->IsParked(browser->GetIdentifier())) {
            suppressMessage = true;
            return false;
        }
        if (!shared_->quiet) return false;  // Chromium's own dialog
        const wchar_t* kind = type == JSDIALOGTYPE_CONFIRM ? L"confirm" : type == JSDIALOGTYPE_PROMPT ? L"prompt" : L"alert";
        LogSkippedModal(std::wstring(L"javascript ") + kind + L": " + message.ToWString());
        suppressMessage = true;
        return false;
    }

    // Leave Page, from a parked page or in a quiet run: Left, as the Mac's forced close and quit
    // answer it (KCBrowser.mm's OnBeforeUnloadDialog), and like it on a later turn of CEF's thread:
    // answering inside this call slowed Chromium's teardown there. Any other page's is Chromium's.
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString&, bool isReload, CefRefPtr<CefJSDialogCallback> callback) override {
        // A parked page leaves, as the Mac's closed pages do (KCBrowser.mm's OnBeforeUnloadDialog):
        // its tab is gone, so there's no one to ask, and Stay would keep it running on its page.
        if (shared_->IsParked(browser->GetIdentifier())) {
            ++shared_->parkedLeavesAnswered;
            RunOnCefUIThread([callback] { callback->Continue(true, CefString()); });
            return true;
        }
        if (!shared_->quiet) return false;  // Chromium's own dialog
        LogSkippedModal(isReload ? L"reload page dialog" : L"leave page dialog");
        RunOnCefUIThread([callback] { callback->Continue(true, CefString()); });
        return true;
    }

    // CefFocusHandler

    // While Kite's command bar is open, a page never takes the keyboard back (Chromium
    // focuses a page as it navigates), as the Mac blurs its pages while the bar is open. A
    // quiet run's pages never take it: focusing a page's window activates Kite's. Nor, while Kite's find field has the keyboard, on a navigation (a click is the system's).
    // Nor as its window is enabled again (the command bar closing, which Chromium answers with a
    // focus of its own, inside EnableWindow) while Kite keeps the keyboard: Ctrl+F over the bar.
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) override {
        if (shared_->kiteKeepsKeyboard && (source == FOCUS_SOURCE_NAVIGATION || shared_->reenabling)) return true;
        return shared_->inputBlocked || shared_->quiet;
    }

    // CefFindHandler

    // Every report, the interim ones too, as the Mac's KCBrowser passes them on: the count grows
    // as Chromium scans the page.
    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect&, int activeMatchOrdinal,
                      bool finalUpdate) override {
        // A search replaced since (each Find has a higher identifier) reports nothing more.
        if (identifier < lastFindIdentifier_) return;
        lastFindIdentifier_ = identifier;
        shared_->Post([shared = shared_, id = tabID_, browser, count, activeMatchOrdinal, finalUpdate] {
            if (shared->PageFor(id, browser) && shared->events.findResult) shared->events.findResult(id, count, activeMatchOrdinal, finalUpdate);
        });
    }

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

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
        perf::Mark(isLoading ? "load-begin" : "load-end", tabID_);
        shared_->Post([shared = shared_, id = tabID_, browser, isLoading, canGoBack, canGoForward] {
            if (shared->PageFor(id, browser) && shared->events.loadingChanged) {
                shared->events.loadingChanged(id, isLoading, canGoBack, canGoForward);
            }
        });
    }

    // CefRequestHandler

    // Ctrl-click and middle-click (a background tab), Ctrl+Shift-click (a foreground one): a
    // new Kite tab, as the Mac's KCBrowser does. Otherwise Alloy would load the link in this
    // tab, replacing the page. Anything else, or without a click, goes on as Chromium decides.
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, const CefString& targetURL,
                          cef_window_open_disposition_t disposition, bool userGesture) override {
        if (shared_->IsParked(browser->GetIdentifier())) return true;  // its tab has closed
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
    const std::string profile_;
    const std::string firstURL_;
    // CEF's UI thread only.
    CefRefPtr<CefRegistration> devTools_;
    std::vector<int> busyChecks_;  // Runtime.evaluate message ids awaiting an answer
    int lastFindIdentifier_ = 0;   // OnFindResult's highest
    IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

void Chromium::Shared::Evict() {
    if (pages.size() <= policy.maxLiveTabs) return;
    for (const std::string& id : OverTheLimit()) {
        const Page& page = pages.at(id);
        // A page still being made can't be asked; it counts, and goes on a later pass.
        if (!page.browser || page.mediaInUse || RunningDownloadsIn(page.browser->GetIdentifier()) ||
            (events.keepAlive && events.keepAlive(id))) {
            continue;
        }
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
        if (!page.browser || page.mediaInUse || RunningDownloadsIn(page.browser->GetIdentifier()) ||
            (events.keepAlive && events.keepAlive(id))) {
            continue;
        }
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
    for (const auto& page : shared_->parked) shared_->CloseParked(page);
    shared_->parked.clear();
    shared_->FollowParked();
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
    {
        // The downloads' callbacks are CEF's objects: let go of them before CEF goes.
        std::lock_guard lock(shared_->downloadsMutex);
        shared_->liveDownloads.clear();
        shared_->downloadReports.clear();
        shared_->resolving.clear();  // a name search still running finds nothing to continue
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
        if (!CefBrowserHost::CreateBrowser(windowInfo, new PageClient(tabID, shared_, profileDirectory, url.empty() ? "about:blank" : url), "",
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

bool Chromium::HasPage(const std::string& tabID) const {
    const auto it = shared_->pages.find(tabID);
    return it != shared_->pages.end() && !it->second.closeWhenMade;
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
        RunOnCefUIThread([shared = shared_, hosts = std::move(hosts), blocked] {
            shared->reenabling = !blocked;
            for (HWND host : hosts) EnableWindow(host, blocked ? FALSE : TRUE);
            shared->reenabling = false;
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

bool Chromium::CanFind() const {
    auto it = shared_->pages.find(shared_->shown);
    return it != shared_->pages.end() && !it->second.closeWhenMade && !shared_->closing;
}

bool Chromium::Find(const std::string& text, bool forward, bool findNext) {
    if (!CanFind()) return false;
    Shared::Page& page = shared_->pages.at(shared_->shown);
    if (!page.browser) {
        page.pendingFind = Shared::Page::PendingFind{text, forward, findNext};
        return true;
    }
    Shared::RunFind(page.browser, text, forward, findNext);
    return true;
}

void Chromium::StopFinding() {
    if (!CanFind()) return;
    Shared::Page& page = shared_->pages.at(shared_->shown);
    page.pendingFind.reset();
    // Keep the active match selected, like Chrome and Arc.
    if (page.browser) RunOnCefUIThread([browser = page.browser] { browser->GetHost()->StopFinding(false); });
}

void Chromium::SetOverlayHole(const RECT& hole, int cornerRadius) {
    shared_->overlayHole = Shared::Hole{hole, IsRectEmpty(&hole) ? 0 : cornerRadius};
    shared_->Layout();
}

void Chromium::KeepKeyboard(bool keep) { shared_->kiteKeepsKeyboard = keep; }

bool Chromium::PageTakesClickAt(POINT client) const {
    auto it = shared_->pages.find(shared_->shown);
    if (it == shared_->pages.end() || !it->second.hwnd) return false;
    // Windows' own search for the child window under a point, which honours window regions.
    return ChildWindowFromPointEx(shared_->window, client, CWP_SKIPINVISIBLE | CWP_SKIPDISABLED) == it->second.hwnd;
}

bool Chromium::MayCloseWindow() {
    const bool started = !shared_->closing.exchange(true);  // before the queue, so it opens no new page
    RunPending();  // a DoClose or OnBeforeClose that just ran may have its note queued
    if (started) {
        shared_->closingSince = GetTickCount64();
        for (auto& [id, page] : shared_->pages) {
            if (page.browser) page.browser->GetHost()->CloseBrowser(true);
        }
        // Pages kept for their downloads go too (quitting cancels those downloads first).
        for (const auto& page : shared_->parked) shared_->CloseParked(page);
        shared_->parked.clear();
        shared_->FollowParked();
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

void Chromium::SetDownloadLocations(std::map<std::string, ProfileSettings> byProfile, std::filesystem::path defaultFolder) {
    std::lock_guard lock(shared_->downloadsMutex);
    shared_->downloadSettings = std::move(byProfile);
    shared_->downloadFolder = std::move(defaultFolder);
}

void Chromium::CancelDownloads(std::vector<DownloadKey> downloads, std::function<void(const DownloadKey&)> gone) {
    if (downloads.empty()) return;
    // On CEF's thread, which runs the callbacks; Chromium reports each one canceled.
    RunOnCefUIThread([shared = shared_, downloads = std::move(downloads), gone = std::move(gone)] {
        for (const DownloadKey& key : downloads) {
            CefRefPtr<CefDownloadItemCallback> callback;
            {
                std::lock_guard lock(shared->downloadsMutex);
                if (key.first >= 0 && key.first <= static_cast<int64_t>(UINT32_MAX)) {
                    if (auto* live = shared->FindLiveDownload(key.second, static_cast<uint32_t>(key.first))) callback = live->callback;
                }
            }
            if (callback) callback->Cancel();
            else if (gone) shared->Post([gone, key] { gone(key); });
        }
    });
}

void Chromium::AllowAutomaticDownloads(const std::string& origin) {
    RunOnCefUIThread([origin] {
        if (CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext()) {
            context->SetContentSetting(origin, origin, CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS, CEF_CONTENT_SETTING_VALUE_ALLOW);
        }
    });
}

bool Chromium::HandleTimer(UINT_PTR id) {
    if (id != kStallTimer) return false;
    // A tick already queued when the timer stopped: nothing is parked, so nothing to look at.
    if (shared_->stallCheck.running) shared_->CancelStalled();
    return true;
}

bool Chromium::TestUserGesture() {
    auto it = shared_->pages.find(shared_->shown);
    if (it == shared_->pages.end() || !it->second.browser) return false;
    RunOnCefUIThread([browser = it->second.browser] {
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetString("expression", "document.title = 'clicked'");
        params->SetBool("userGesture", true);
        browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
    });
    return true;
}

void Chromium::LogParkedPages() {
    std::lock_guard lock(shared_->downloadsMutex);
    shared_->logParked = true;
}

int Chromium::ParkedLeavePagesAnswered() const { return shared_->parkedLeavesAnswered; }

bool Chromium::StallCheckRunning() const { return shared_->stallCheck.running; }

int Chromium::StallCheckTicks() const { return shared_->stallTicks; }

std::vector<std::pair<std::string, bool>> Chromium::ParkedPages() const {
    std::lock_guard lock(shared_->downloadsMutex);
    return shared_->parkedLog;
}

std::pair<uint64_t, uint64_t> Chromium::DownloadReports() const {
    std::lock_guard lock(shared_->downloadsMutex);
    return {shared_->reportsFromChromium, shared_->reportsDelivered};
}

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
