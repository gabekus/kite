#pragma once
// Chromium (CEF) in Kite for Windows: one windowed browser per tab, a child window of the
// main window placed over the content card. The counterpart of the Mac's CEFBridge
// (KCRuntime.mm, KCBrowser.mm) and Engine/ChromiumEngine.swift, on CEF's C++ API directly.
//
// Threads: CEF runs its own UI thread (multi_threaded_message_loop), so Kite's message loop
// and DirectComposition stay as they are. Everything CEF reports arrives on that thread and
// is handed to Kite's UI thread through PostMessage (MainWindow::kWakeMessage); the public
// methods here are for Kite's UI thread only.
//
// Closing follows CEF's windowed-browser order: the first WM_CLOSE asks every browser to
// close and is cancelled; each browser's DoClose sends WM_CLOSE again; once every browser is
// through DoClose the window may close, which destroys the browsers' windows, and the
// destructor waits for their OnBeforeClose before CefShutdown.

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
    // keeping window.opener (sign-in popups need it), as the Mac does.
    std::function<void(const std::string& openerTabID, const std::string& tabID, const std::string& url)> popupOpened;
};

class Chromium {
public:
    // Starts Chromium with its profiles under `root` (the Mac's <support>/Chromium): the
    // default profile in root\Default, a space's other profile in root\<directory>.
    static std::unique_ptr<Chromium> Start(HINSTANCE instance, HWND window, const std::filesystem::path& root,
                                           PageEvents events, std::wstring& error);
    ~Chromium();
    Chromium(const Chromium&) = delete;
    Chromium& operator=(const Chromium&) = delete;

    // Shows the tab's page in `bounds` (client pixels) and hides every other tab's. The
    // browser is created the first time, in the profile's request context, loading `url`.
    void Show(const std::string& tabID, const std::string& profileDirectory, const std::string& url, const RECT& bounds);
    // Moves the shown page, after the window is resized.
    void SetBounds(const RECT& bounds);
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
