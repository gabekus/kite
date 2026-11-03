#pragma once
// Kite's top-level browser window: a plain Win32 window. The DirectComposition tree
// (sidebar, page, command bar) is hosted in it next; see docs/windows.md.

#include <windows.h>

#include <functional>

namespace kite {

class MainWindow {
public:
    // In points (DIPs), scaled to the monitor. The Mac's BrowserWindowController: a
    // 1280×820 content rect and a 640×420 minimum.
    static constexpr int kDefaultWidth = 1280;
    static constexpr int kDefaultHeight = 820;
    static constexpr int kMinimumWidth = 640;
    static constexpr int kMinimumHeight = 420;

    static bool RegisterWindowClass(HINSTANCE instance);

    explicit MainWindow(HINSTANCE instance);
    ~MainWindow();
    MainWindow(const MainWindow&) = delete;
    MainWindow& operator=(const MainWindow&) = delete;

    bool IsValid() const { return hwnd_ != nullptr; }
    HWND Handle() const { return hwnd_; }
    void Show(int showCommand);
    // Shows the window behind every other one without activating it, for quiet test runs
    // (like the Mac's KITE_DIAGNOSTICS launches). PrintWindow still captures it covered.
    void ShowBehindOtherWindows();
    // Client area in DIPs (96 DPI points), scaled to the window's monitor. Can be larger
    // than the screen, so a capture has the same size on every machine.
    void SetClientSize(int width, int height);
    // Whether the client area is exactly width × height points at the window's scale.
    bool HasClientSize(int width, int height) const;

    // Runs before the window is destroyed (WM_CLOSE), and at logoff or shutdown
    // (WM_ENDSESSION), e.g. to save the session.
    std::function<void()> onClose;

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    void ApplySystemAppearance();
    void ResizeClient(int width, int height);

    HWND hwnd_ = nullptr;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool allowLargerThanScreen_ = false;
};

}  // namespace kite
