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
// popup does) takes only its own window with it.

#include <windows.h>

#include <filesystem>
#include <functional>
#include <memory>
#include <string>

namespace kite {

// When Chromium started this process as one of its helpers (renderer, GPU, utility), runs it
// and returns its exit code; returns -1 in the browser process. First thing in wWinMain,
// before Kite parses the command line (helpers get Chromium's own switches).
int RunChromiumSubprocess(HINSTANCE instance);

// What the pages report, on Kite's UI thread.
struct PageEvents {
    std::function<void(const std::string& tabID, const std::string& url)> addressChanged;
    std::function<void(const std::string& tabID, const std::string& title)> titleChanged;
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
    // Ctrl+T in a page: Kite's shortcut, which the page never sees. Until Kite opens the bar
    // and calls BlockInput, the keys typed into the page after it come to Kite instead
    // (keyForwarded, in order), so what's typed straight after Ctrl+T lands in the bar, as the
    // Mac holds keys until its field has focus. Kite answers with BlockInput, true or false.
    std::function<void()> newTab;
    // A key (`character` false: a virtual-key code) or a typed UTF-16 unit (`character` true)
    // that reached a page while its keys go to Kite.
    std::function<void(bool character, unsigned code, bool ctrl, bool shift)> keyForwarded;
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
    // Unblocked, the keys go to the pages again.
    void BlockInput(bool blocked);
    // Loads `url` in the tab's page (the command bar's Enter on the current tab); a page
    // still being made loads it once it exists. False when the tab has no page (Show makes
    // one with the tab's address).
    bool Navigate(const std::string& tabID, const std::string& url);
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
