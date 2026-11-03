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
// windows belong to CEF's thread, so Kite moves and hides them there too (CefPostTask),
// never waiting on it. The public methods here are for Kite's UI thread only.
//
// Closing the window: the first WM_CLOSE force-closes every browser and is cancelled; as
// each browser is through DoClose or closed, the window is asked to close again, and closes
// once all are. That destroys the browsers' windows, and the destructor waits for their
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
    // The tab's page is gone on its own: it closed itself, or its popup was never created.
    std::function<void(const std::string& tabID)> pageClosed;
    // Another launch of Kite found this one running (one Kite per profile, as Chromium allows).
    std::function<void()> relaunched;
};

class Chromium {
public:
    enum class StartResult { Started, AlreadyRunning, Failed };

    // Starts Chromium with its profiles under `root` (the Mac's <support>/Chromium): the
    // default profile in root\Default, a space's other profile in root\<directory>.
    // AlreadyRunning: another Kite has this profile and has been told to come forward.
    static StartResult Start(HINSTANCE instance, HWND window, const std::filesystem::path& root, PageEvents events,
                             std::unique_ptr<Chromium>& out, std::wstring& error);
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
    // Gives the shown page keyboard focus (the window was activated).
    void Focus();
    // Whether the window may close now. The first call starts closing every browser and
    // returns false (unless there are none); WM_CLOSE comes again as each one is ready.
    bool MayCloseWindow();
    // Runs what CEF's thread handed over. MainWindow::kWakeMessage calls it.
    void RunPending();

    struct Shared;  // state both threads touch, behind a mutex (Chromium.cpp)

private:
    explicit Chromium(std::shared_ptr<Shared> shared);
    std::shared_ptr<Shared> shared_;
};

}  // namespace kite
