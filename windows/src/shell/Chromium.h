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

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>

#include "core/KeyBindings.h"

namespace kite {

// When Chromium started this process as one of its helpers (renderer, GPU, utility), runs it
// and returns its exit code; returns -1 in the browser process. First thing in wWinMain,
// before Kite parses the command line (helpers get Chromium's own switches).
int RunChromiumSubprocess(HINSTANCE instance);

// What the pages report, on Kite's UI thread.
struct PageEvents {
    std::function<void(const std::string& tabID, const std::string& url)> addressChanged;
    std::function<void(const std::string& tabID, const std::string& title)> titleChanged;
    // The page's favicon: the first it lists, or empty for none (the Mac's faviconDidChange).
    std::function<void(const std::string& tabID, const std::string& url)> faviconChanged;
    std::function<void(const std::string& tabID, bool loading)> loadingChanged;
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
    // Kite's shortcuts in a page: which command each key runs (ShortcutTable), and who gets it
    // first when the page wants it too, by the command's priority (the Mac's
    // ShortcutPriorityRouter): Prefer Kite runs it before the page sees the key; Prefer
    // Websites only if the page doesn't use it; Use Both lets the page have it, and a second
    // press soon after runs Kite's. Read on CEF's thread: fixed once Chromium starts.
    std::map<KeyShortcut, std::string> shortcuts;
    KeyBindings keyBindings;
    // A shortcut's command (other than newTab's Ctrl+T, above), on Kite's thread.
    std::function<void(const std::string& command)> command;
    // Past six live pages the least recently shown close (the Mac's PagePool). Asked first:
    // true keeps the tab's page (a popup and its opener, PagePool.isLinkedToPopup).
    std::function<bool(const std::string& tabID)> keepAlive;
    // A page closed for the limit; its tab stays and loads again when it's next shown.
    std::function<void(const std::string& tabID)> pageDiscarded;
};

class Chromium {
public:
    enum class StartResult { Started, AlreadyRunning, Failed };

    // Starts Chromium with its profiles under `root` (the Mac's <support>/Chromium): the
    // default profile in root\Default, a space's other profile in root\<directory>.
    // AlreadyRunning: another Kite has this profile and has been told to come forward.
    static StartResult Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, PageEvents events,
                             std::unique_ptr<Chromium>& out, std::wstring& error);
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
    // showDevTools, printPage…). False when no page is shown yet.
    enum class PageAction { Back, Forward, Reload, ReloadIgnoringCache, Stop, DevTools, Print };
    bool Act(PageAction action);
    // Ctrl+T was pressed in a page and the keyboard moved to Kite's window, but Kite hasn't
    // answered yet (PageEvents::newTab is on its way): keys arriving now are for the bar.
    bool KeysComeToKite() const;
    // Whether the window may close now. The first call starts closing every browser and
    // returns false (unless there are none); WM_CLOSE comes again as each one is ready.
    bool MayCloseWindow();
    // Runs what CEF's thread handed over. MainWindow::kWakeMessage calls it.
    void RunPending();
    // False when a page's Chromium widget window wasn't where Kite looks for it, so hidden
    // tabs would keep drawing (a CEF update moved it). --smoke-test fails on it.
    bool PagesCanBeHidden() const;
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
