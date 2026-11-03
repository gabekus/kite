#pragma once
// Kite's top-level browser window: a plain Win32 window. The DirectComposition tree
// (sidebar, page, command bar) is hosted in it next; see docs/windows.md.

#include <windows.h>

#include <functional>

namespace kite {

class MainWindow {
public:
    // Window size at 96 DPI before a saved frame exists, scaled to the monitor.
    static constexpr int kDefaultWidth = 1280;
    static constexpr int kDefaultHeight = 800;
    static constexpr int kMinimumWidth = 500;
    static constexpr int kMinimumHeight = 400;

    static bool RegisterWindowClass(HINSTANCE instance);

    explicit MainWindow(HINSTANCE instance);
    ~MainWindow();
    MainWindow(const MainWindow&) = delete;
    MainWindow& operator=(const MainWindow&) = delete;

    bool IsValid() const { return hwnd_ != nullptr; }
    HWND Handle() const { return hwnd_; }
    void Show(int showCommand);

    // Runs before the window is destroyed, e.g. to save the session.
    std::function<void()> onClose;

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    void ApplySystemAppearance();

    HWND hwnd_ = nullptr;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
};

}  // namespace kite
