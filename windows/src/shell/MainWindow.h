#pragma once
// Kite's top-level browser window: a Win32 window with no redirection bitmap, so all it shows
// is its DirectComposition tree (shell/Compositor.h) over the system backdrop; see docs/windows.md.
// It has no caption: the client area runs up to the window's top edge (the Mac's
// .fullSizeContentView), keeping Windows' resize borders, and the title bar's buttons and drag
// areas are Kite's (hitTest, shell/CaptionButtonsView.h).

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

    // Posted to the window to run work another thread handed over (onWake).
    static constexpr UINT kWakeMessage = WM_APP + 1;

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
    // Client area in DIPs (96 DPI points), scaled to the window's monitor (or to the fixed
    // scale, after UseFixedScale). Can be larger
    // than the screen, so a capture has the same size on every machine.
    void SetClientSize(int width, int height);
    // The DPI the window is laid out at (its monitor's, or the fixed scale's).
    UINT Dpi() const { return dpi_; }
    // Whether the client area is exactly width × height points at the window's scale.
    bool HasClientSize(int width, int height) const;

    // Light or dark title bar and backdrop material. The Mac picks its material's appearance
    // from the space's theme (dark text on a light theme), not from the system setting.
    void SetDarkAppearance(bool dark);
    // Windows 11's acrylic behind the client area, the counterpart of the Mac's .sidebar
    // material blended behind the window. False where there's none (Windows 10, Windows 11
    // before 22H2, Server): the caller then draws an opaque base colour.
    bool UseSystemBackdrop();

    // Asked on WM_CLOSE; false keeps the window open for now (Chromium closes its browsers
    // first, and WM_CLOSE comes again once they're ready).
    std::function<bool()> mayClose;
    // Runs before the window is destroyed (WM_CLOSE), and at logoff or shutdown
    // (WM_ENDSESSION), e.g. to save the session.
    std::function<void()> onClose;
    // kWakeMessage arrived.
    std::function<void()> onWake;
    // The window got keyboard focus (activated, or restored from minimized).
    std::function<void()> onFocus;
    // The window was minimized (onSize follows when it's restored).
    std::function<void()> onMinimize;
    // The window moved on screen.
    std::function<void()> onMove;
    // The client area changed size (also after a DPI change); GetClientRect has the new one.
    std::function<void()> onSize;
    // What a client point (px) is, below the top resize border: HTCLIENT, HTCAPTION (drags the
    // window) or HTMINBUTTON, HTMAXBUTTON or HTCLOSE (Windows 11 shows Snap Layouts over
    // HTMAXBUTTON). Unset, all of it is HTCLIENT.
    std::function<LRESULT(POINT client)> hitTest;
    // Sees every message first (the command bar takes the keyboard and mouse while it's
    // open); true when it handled the message, with `result`.
    std::function<bool(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result)> filter;

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    void ResizeClient(int width, int height);
    // The window rect around a client area `width` × `height` px: the frame's borders but no
    // caption (WM_NCCALCSIZE takes it off).
    RECT FrameAround(int width, int height) const;
    // The resize border's thickness, in the monitor's px (a maximized window hangs this far off
    // the screen on every side).
    int ResizeBorder() const;

    HWND hwnd_ = nullptr;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool allowLargerThanScreen_ = false;
    bool fixedScale_ = false;
};

}  // namespace kite
