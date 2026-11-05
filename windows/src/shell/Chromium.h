#pragma once
// Chromium (CEF) in Kite for Windows: one windowed browser per tab, a child window of the
// main window placed over the content card. The counterpart of the Mac's CEFBridge
// (KCRuntime.mm, KCBrowser.mm) and Engine/ChromiumEngine.swift, on CEF's C++ API directly.
// Browsers are Alloy style, as the Mac's (CEF forces it there for a native parent; on
// Windows the default would be Chrome style, with Chrome's own tab strip and no DoClose).
//
// Threads: CEF runs its own UI thread (multi_threaded_message_loop), so Kite's message loop
// and DirectComposition stay as they are. Everything CEF reports arrives on that thread and
// is handed to Kite's UI thread through PostMessage (MainWindow::kWakeMessage). The page
// windows belong to CEF's thread, so Kite moves and hides them there too (CefPostTask)
// rather than waiting on it. Win32 still makes some calls between the two threads
// synchronous, because a child window on another thread shares its parent's input
// (focus changes, DPI changes, destroying the window); W10's off-screen pages remove the
// child windows and with them those waits. The public methods are for Kite's UI thread only.
//
// Closing the window: the first WM_CLOSE force-closes every browser and is cancelled; as
// each browser is through DoClose or closed, the window is asked to close again, and closes
// once all are. That destroys the browsers' windows, and Shutdown waits for their
// OnBeforeClose before CefShutdown. A page that closes itself (window.close(), as a sign-in
// popup does) takes only its own window with it; so does Close, when Kite closes a tab.

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "core/Downloads.h"
#include "core/KeyBindings.h"
#include "core/ProfileSettings.h"

namespace kite {

// When Chromium started this process as one of its helpers (renderer, GPU, utility), runs it
// and returns its exit code; returns -1 in the browser process. First thing in RunWinMain,
// before Kite parses the command line (helpers get Chromium's own switches). `sandboxInfo` is
// what CEF's bootstrap (Kite.exe) set the sandbox up with; the helper is already in it.
int RunChromiumSubprocess(HINSTANCE instance, void* sandboxInfo);

// What the pages report, on Kite's UI thread.
struct PageEvents {
    std::function<void(const std::string& tabID, const std::string& url)> addressChanged;
    std::function<void(const std::string& tabID, const std::string& title)> titleChanged;
    // The page's favicon: the first it lists, or empty for none (the Mac's faviconDidChange).
    std::function<void(const std::string& tabID, const std::string& url)> faviconChanged;
    // The page started or stopped loading, or its history moved (the Mac's navigationState:
    // OnLoadingStateChange's isLoading, canGoBack and canGoForward).
    std::function<void(const std::string& tabID, bool loading, bool canGoBack, bool canGoForward)> loadingChanged;
    // A page opened a popup or a target=_blank link: Kite hosts it in a new tab with this id,
    // keeping window.opener (sign-in popups need it), as the Mac does. `url` may be empty
    // (window.open('') before the opener writes to it).
    std::function<void(const std::string& openerTabID, const std::string& tabID, const std::string& url)> popupOpened;
    // A link the user opened in a new tab (Ctrl-click or middle-click: background; Ctrl+Shift:
    // foreground), as the Mac's openURLInNewTab. No opener: it's an ordinary new tab.
    std::function<void(const std::string& openerTabID, const std::string& url, bool foreground)> openInNewTab;
    // The tab's page is gone on its own: it closed itself, or its popup was never created.
    std::function<void(const std::string& tabID)> pageClosed;
    // Another launch of Kite found this one running (one Kite per profile, as Chromium allows).
    std::function<void()> relaunched;
    // Ctrl+T in a page: Kite's shortcut, which the page never sees. The keyboard moves to
    // Kite's window at once, so what's typed straight after Ctrl+T lands in the bar, as the
    // Mac holds keys until its field has focus; keys the page had already taken come to Kite
    // too (keyForwarded, in order). Kite answers with BlockInput, true or false.
    std::function<void()> newTab;
    // A key (`character` false: a virtual-key code) or a typed UTF-16 unit (`character` true)
    // that reached a page while its keys go to Kite.
    std::function<void(bool character, unsigned code, bool ctrl, bool shift)> keyForwarded;
    // Kite's shortcuts in a page: which command each key runs, and who gets it first when the
    // page wants it too (ShortcutTable; the Mac's ShortcutPriorityRouter): Prefer Kite runs it
    // before the page sees the key; Prefer Websites only if the page doesn't use it; Use Both
    // lets the page have it, and a second press soon after runs Kite's. Read on CEF's thread,
    // so fixed once Chromium starts (Settings → Shortcuts will swap it atomically).
    ShortcutMap shortcuts;
    // A shortcut's command by id (other than New Tab's, above), on Kite's thread.
    std::function<void(const std::string& command)> command;
    // Past six live pages the least recently shown close (the Mac's PagePool). Asked first:
    // true keeps the tab's page (a popup and its opener, PagePool.isLinkedToPopup).
    std::function<bool(const std::string& tabID)> keepAlive;
    // A page closed for the limit; its tab stays and loads again when it's next shown.
    std::function<void(const std::string& tabID)> pageDiscarded;
    // What Find found in the tab's page (CefFindHandler::OnFindResult): the matches so far, the
    // active one (1-based, 0 before one is), and whether this is the search's last report.
    std::function<void(const std::string& tabID, int count, int activeMatch, bool final)> findResult;
    // A download moved along (the Mac's KCDownloadDidUpdateNotification): Chromium's report,
    // its context "" for the default profile and the folder for another. Chrome Web Store
    // packages never come here. Coalesced on CEF's thread, so however often Chromium reports,
    // Kite's thread gets each download's latest once per wake.
    std::function<void(const DownloadUpdate& update)> downloadUpdated;
    // The renderer process now hosting the tab's main frame, as it reports itself from each new
    // script context there (the Mac's kite.rendererPID, for its Task Manager; here
    // --smoke-test checks that renderer's sandbox).
    std::function<void(const std::string& tabID, DWORD pid)> rendererStarted;
};

class Chromium {
public:
    enum class StartResult { Started, AlreadyRunning, Failed };

    // Starts Chromium with its profiles under `root` (the Mac's <support>/Chromium): the
    // default profile in root\Default, a space's other profile in root\<directory>.
    // AlreadyRunning: another Kite has this profile and has been told to come forward.
    // `sandboxInfo` is the bootstrap's (RunWinMain): every helper runs in Chromium's sandbox.
    // Pages are always made without activating their windows (SetAsPage in Chromium.cpp), so
    // one made while Kite is behind another app leaves it there. `quiet`: a quiet run (main.cpp's
    // `quiet`), which never comes to the front: the pages never take the focus or activate,
    // and show no dialogs (file choosers cancelled, JavaScript and Leave Page dialogs answered,
    // window.print() and Developer Tools skipped), each with a KITE_TEST_MODAL line; a download
    // whose profile asks where to save is cancelled the same way.
    // `switches` ("name" or "name=value", no leading dashes) go on the browser process's
    // command line (--chromium-switches, test profiles only).
    static StartResult Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, void* sandboxInfo, PageEvents events,
                             bool quiet, std::vector<std::string> switches, std::unique_ptr<Chromium>& out, std::wstring& error);
    // Shuts Chromium down (or does nothing if it already has); the destructor calls it too.
    ~Chromium();
    Chromium(const Chromium&) = delete;
    Chromium& operator=(const Chromium&) = delete;

    // Shows the tab's page in `bounds` (client pixels) and hides every other tab's. The
    // browser is created the first time, in the profile's request context, loading `url`.
    void Show(const std::string& tabID, const std::string& profileDirectory, const std::string& url, const RECT& bounds);
    // No tab is selected: every page is hidden (the card shows through), and the keyboard
    // comes back to Kite's window.
    void ShowNothing();
    // Kite closed the tab, or unloaded it (a pinned tab): its page closes, without a
    // pageClosed, and Show makes a new one if it comes back. A page still being made closes
    // once it exists. Back/forward history goes with it (the Mac keeps none either here).
    void Close(const std::string& tabID);
    // Moves the shown page, after the window is resized (and shows it again after a minimize).
    void SetBounds(const RECT& bounds);
    // The window was minimized: the shown page is hidden too, so Chromium stops drawing it.
    void Minimized();
    // The window is being moved or resized: open <select> and autofill popups follow it.
    void WindowMoved();
    // Gives the shown page keyboard focus (the window was activated), unless input is blocked.
    void Focus();
    // While something of Kite's is over the pages (the command bar), they take no input:
    // their windows are disabled, so clicks go to Kite's window; they don't take the focus
    // back (on a navigation, say); and keys that still reach one come to Kite (keyForwarded).
    // Unblocked, the keys go to the pages again. The windows are disabled on CEF's thread, so
    // a click in the moment before that runs (CEF's thread busy with a heavy page) still
    // reaches the page; keys don't, since they follow the focus.
    void BlockInput(bool blocked);
    // Loads `url` in the tab's page (the command bar's Enter on the current tab); a page
    // still being made loads it once it exists. False when the tab has no page (Show makes
    // one with the tab's address).
    bool Navigate(const std::string& tabID, const std::string& url);
    // What the menu's page commands do to the shown page (the Mac's goBack, reload,
    // showDevTools…). False when no page is shown yet.
    enum class PageAction { Back, Forward, Reload, ReloadIgnoringCache, Stop, DevTools };
    bool Act(PageAction action);
    // Whether the shown tab has a page, made or being made (what find needs; the Mac's shownPage,
    // which a new tab has at once).
    bool CanFind() const;
    // Finds `text` in the shown page, as the Mac's ChromiumEngine.find: `findNext` moves through
    // the matches of the same text; a new search also steps once, so its first match is active
    // (1/N), as in Chrome. A page still being made searches once it exists (the last search
    // asked for). Reports come as PageEvents::findResult, a replaced search's dropped. False when
    // no page is shown.
    bool Find(const std::string& text, bool forward, bool findNext);
    // Ends the shown page's search and its highlights, keeping the active match selected, as
    // Chrome and Arc do.
    void StopFinding();
    // Where something of Kite's sits over the shown page (the find bar), in client px, with its
    // corners' radius in px; empty for nothing. The page's window has a hole there, so clicks on it
    // come to Kite's window while the rest of the page keeps taking input. It follows the shown
    // page; whoever moves the card (a resize, later the sidebar's toggle and splits) sets it again.
    void SetOverlayHole(const RECT& hole, int cornerRadius);
    // While Kite's own field has the keyboard (the find bar's), a page doesn't take it back: not on
    // a navigation (as the Mac's field stays first responder while the page loads), not from Kite's
    // own Focus() (checked again on CEF's thread as it runs), and not from Chromium's focus of a page
    // whose windows BlockInput(false) is enabling again (the command bar closing under Ctrl+F).
    void KeepKeyboard(bool keep);
    // Test-only: whether a click at `client` (client px) would reach the shown page's window,
    // asked of its region the way Windows hit-tests (the smoke test's check of the hole).
    bool PageTakesClickAt(POINT client) const;
    // Ctrl+T was pressed in a page and the keyboard moved to Kite's window, but Kite hasn't
    // answered yet (PageEvents::newTab is on its way): keys arriving now are for the bar.
    bool KeysComeToKite() const;
    // Whether the window may close now. The first call starts closing every browser and
    // returns false (unless there are none); WM_CLOSE comes again as each one is ready.
    bool MayCloseWindow();
    // Memory is low (the Mac's watchMemoryPressure): every page but the shown one closes,
    // unless it's playing sound, using the camera or microphone, tied to a popup, or shown
    // again before it answers. Their tabs stay and load again when next shown (pageDiscarded).
    void DiscardHiddenPages();
    // Where each profile's downloads go (DownloadLocation.installForChromium): its settings by
    // profile folder (one not listed reads Default's), and the folder for a profile that chose
    // none (or whose chosen one has gone). Read on CEF's thread as each download starts.
    void SetDownloadLocations(std::map<std::string, ProfileSettings> byProfile, std::filesystem::path defaultFolder);
    // Cancels live downloads, by engine id and context (KCBrowser.cancelDownload). `gone` runs on
    // Kite's thread for each one Chromium had already let go (it finished in between).
    using DownloadKey = std::pair<int64_t, std::string>;
    void CancelDownloads(std::vector<DownloadKey> downloads, std::function<void(const DownloadKey&)> gone = nullptr);
    // Chromium's download reports so far, and how many reached Kite's thread (the rest were
    // folded into a later one): for the save log.
    std::pair<uint64_t, uint64_t> DownloadReports() const;
    // Each page that was kept for its downloads after its tab closed, as it went: its address
    // and whether it was muted (it's put on about:blank, muted, when it's kept). For the save log.
    std::vector<std::pair<std::string, bool>> ParkedPages() const;
    // A test profile's live check of a burst of downloads (--save-log with
    // KITE_TEST_AUTOMATIC_DOWNLOADS=ORIGIN): pages from `origin` (a local test server) may start
    // many downloads with no click, which Chromium otherwise stops after the first.
    void AllowAutomaticDownloads(const std::string& origin);
    // The parked pages' stall check runs on a timer of Kite's window (the controller's timer 11),
    // only while a page is parked. The window hands its WM_TIMER here: true when it was this one.
    static constexpr UINT_PTR kStallTimer = 11;
    bool HandleTimer(UINT_PTR id);
    bool StallCheckRunning() const;
    int StallCheckTicks() const;  // how often it ran (the save log)
    // --save-log: each parked page's address and whether it was muted are kept (ParkedPages),
    // and how many Leave Page dialogs parked pages asked for (each answered Leave).
    void LogParkedPages();
    // A test run's stand-in for a click (the test tab close): the shown page runs a script as if
    // the user had clicked (DevTools' Runtime.evaluate with userGesture), which gives it the user
    // activation Chromium wants before a page may ask Leave Page. False with no page shown.
    bool TestUserGesture();
    int ParkedLeavePagesAnswered() const;
    // Runs what CEF's thread handed over. MainWindow::kWakeMessage calls it.
    void RunPending();
    // False when a page's Chromium widget window wasn't where Kite looks for it, so hidden
    // tabs would keep drawing (a CEF update moved it). --smoke-test fails on it.
    bool PagesCanBeHidden() const;
    // Chromium's Energy Saver, which drops pages to 30 fps on battery below 20%: the Mac's
    // KCRuntime.energySaverEnabled. Off unless the user turns it on, so pages run at the
    // display's full rate; set as Chromium starts, and again on each change. Nothing turns it
    // on yet (Windows has no Settings toggle for it).
    void SetEnergySaverEnabled(bool enabled);
    // For --smoke-test: Chromium's Energy Saver preference as Chromium has it (nullopt: it has
    // none), read on CEF's thread; `done` runs on Kite's UI thread, ahead of the answer to
    // anything Kite asks of CEF after this call (CloseBrowser's DoClose). Only a fresh profile
    // shows that Kite set it: Local State keeps a value an earlier run wrote.
    void ReadEnergySaver(std::function<void(std::optional<int> state)> done);
    // After the main window is gone: waits (at most 10 s) for every browser to close, then
    // shuts Chromium down. False when a browser didn't close in time, here or within the
    // window's 5 s close deadline, so Chromium went down under it. --smoke-test fails on it.
    bool Shutdown();

    struct Shared;  // state both threads touch, behind a mutex (Chromium.cpp)

private:
    explicit Chromium(std::shared_ptr<Shared> shared);
    std::shared_ptr<Shared> shared_;
    bool shutDown_ = false;
    bool cleanShutdown_ = false;
};

}  // namespace kite
