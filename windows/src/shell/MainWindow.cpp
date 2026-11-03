#include "shell/MainWindow.h"

#include <dwmapi.h>

#include "shell/SystemAppearance.h"

namespace kite {
namespace {

constexpr wchar_t kClassName[] = L"KiteBrowserWindow";

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
constexpr DWORD DWMWA_USE_IMMERSIVE_DARK_MODE = 20;  // Windows 10 20H1+
#endif

int Scale(int value, UINT dpi) { return MulDiv(value, static_cast<int>(dpi), USER_DEFAULT_SCREEN_DPI); }

}  // namespace

bool MainWindow::RegisterWindowClass(HINSTANCE instance) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &MainWindow::WindowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    return RegisterClassExW(&wc) != 0;
}

MainWindow::MainWindow(HINSTANCE instance) {
    UINT systemDpi = GetDpiForSystem();
    CreateWindowExW(0, kClassName, L"Kite", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                    Scale(kDefaultWidth, systemDpi), Scale(kDefaultHeight, systemDpi), nullptr, nullptr,
                    instance, this);
}

MainWindow::~MainWindow() {
    if (hwnd_) DestroyWindow(hwnd_);
}

void MainWindow::Show(int showCommand) {
    ShowWindow(hwnd_, showCommand);
    UpdateWindow(hwnd_);
}

void MainWindow::SetClientSize(int width, int height) {
    // Windows otherwise caps a window at the screen size (WM_GETMINMAXINFO's ptMaxTrackSize).
    allowLargerThanScreen_ = true;
    RECT rect{0, 0, Scale(width, dpi_), Scale(height, dpi_)};
    AdjustWindowRectExForDpi(&rect, static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_STYLE)), FALSE,
                             static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_EXSTYLE)), dpi_);
    SetWindowPos(hwnd_, nullptr, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void MainWindow::ApplySystemAppearance() {
    BOOL dark = AppsUseDarkTheme() ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

LRESULT CALLBACK MainWindow::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* window = static_cast<MainWindow*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
        window->hwnd_ = hwnd;
        window->dpi_ = GetDpiForWindow(hwnd);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window));
        window->ApplySystemAppearance();
    }
    auto* window = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!window) return DefWindowProcW(hwnd, message, wParam, lParam);
    return window->Handle(message, wParam, lParam);
}

LRESULT MainWindow::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_DPICHANGED: {
        // Take the rect Windows suggests so the window keeps its physical size on the new monitor.
        dpi_ = HIWORD(wParam);
        const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_GETMINMAXINFO: {
        auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
        info->ptMinTrackSize.x = Scale(kMinimumWidth, dpi_);
        info->ptMinTrackSize.y = Scale(kMinimumHeight, dpi_);
        if (allowLargerThanScreen_) info->ptMaxTrackSize = {32767, 32767};
        return 0;
    }
    case WM_SETTINGCHANGE:
        ApplySystemAppearance();
        break;
    case WM_CLOSE:
        if (onClose) onClose();
        DestroyWindow(hwnd_);
        return 0;
    case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
        hwnd_ = nullptr;
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd_, message, wParam, lParam);
}

}  // namespace kite
