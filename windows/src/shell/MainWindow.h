#pragma once
// Kite's top-level browser window: a Win32 window with no redirection bitmap, so all it shows
// is its DirectComposition tree (shell/Compositor.h) over the system backdrop; see docs/windows.md.

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
    // (like the Mac's KITE_DIAGNOSTICS launches).
    void ShowBehindOtherWindows();
    // Lays the window out at `scale`× (96 × scale DPI) whatever its monitor's scale, for
    // captures that must compare with the Mac's 2× ones on any display. Monitor changes then
    // keep this scale. Call before SetClientSize.
    void UseFixedScale(int scale);
    // Client area in DIPs (96 DPI points), scaled to the window's monitor. Can be larger
    // than the screen, so a capture has the same size on every machine.
    void SetClientSize(int width, int height);
    // Whether the client area is exactly width × height points at the window's scale.
    bool HasClientSize(int width, int height) const;

    // Light or dark title bar and backdrop material. The Mac picks its material's appearance
    // from the space's theme (dark text on a light theme), not from the system setting.
    void SetDarkAppearance(bool dark);
    // Windows 11's acrylic behind the client area, the counterpart of the Mac's .sidebar
    // material blended behind the window. False where there's none (Windows 10, Windows 11
    // before 22H2, Server): the caller then draws an opaque base colour.
    bool UseSystemBackdrop();

    // Runs before the window is destroyed (WM_CLOSE), and at logoff or shutdown
    // (WM_ENDSESSION), e.g. to save the session.
    std::function<void()> onClose;
    // The client area changed size (also after a DPI change); GetClientRect has the new one.
    std::function<void()> onSize;

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    void ResizeClient(int width, int height);

    HWND hwnd_ = nullptr;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool allowLargerThanScreen_ = false;
    bool fixedScale_ = false;
};

}  // namespace kite
