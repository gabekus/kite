// Kite's Win32 browser window; see MainWindow.h.

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
    // Placeholder fill so the client area (and --capture) is deterministic until the
    // composition tree draws the theme backdrop (checkpoint W3).
    wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kClassName;
    return RegisterClassExW(&wc) != 0;
}

MainWindow::MainWindow(HINSTANCE instance) {
    // The default size is the client area, like the Mac's content rect; add the frame to it.
    UINT systemDpi = GetDpiForSystem();
    RECT rect{0, 0, Scale(kDefaultWidth, systemDpi), Scale(kDefaultHeight, systemDpi)};
    AdjustWindowRectExForDpi(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0, systemDpi);
    CreateWindowExW(0, kClassName, L"Kite", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                    rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, instance, this);
    // Windows sends no WM_DPICHANGED at creation, so a window that lands on a monitor with
    // another scale than the system's is resized for that monitor here.
    if (hwnd_ && dpi_ != systemDpi) ResizeClient(kDefaultWidth, kDefaultHeight);
}

MainWindow::~MainWindow() {
    if (hwnd_) DestroyWindow(hwnd_);
}

void MainWindow::Show(int showCommand) {
    ShowWindow(hwnd_, showCommand);
    UpdateWindow(hwnd_);
}

void MainWindow::ShowBehindOtherWindows() {
    SetWindowPos(hwnd_, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    UpdateWindow(hwnd_);
}

void MainWindow::SetClientSize(int width, int height) {
    // Windows otherwise caps a window at the screen size (WM_GETMINMAXINFO's ptMaxTrackSize).
    allowLargerThanScreen_ = true;
    ResizeClient(width, height);
}

bool MainWindow::HasClientSize(int width, int height) const {
    RECT client{};
    GetClientRect(hwnd_, &client);
    return client.right - client.left == Scale(width, dpi_) && client.bottom - client.top == Scale(height, dpi_);
}

void MainWindow::ResizeClient(int width, int height) {
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
        // The minimum is the client area, like the Mac's (whose frame is its content with
        // .fullSizeContentView); Windows wants the outer size, so add the frame.
        RECT frame{0, 0, Scale(kMinimumWidth, dpi_), Scale(kMinimumHeight, dpi_)};
        AdjustWindowRectExForDpi(&frame, static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_STYLE)), FALSE,
                                 static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_EXSTYLE)), dpi_);
        info->ptMinTrackSize.x = frame.right - frame.left;
        info->ptMinTrackSize.y = frame.bottom - frame.top;
        if (allowLargerThanScreen_) info->ptMaxTrackSize = {32767, 32767};
        return 0;
    }
    case WM_SETTINGCHANGE:
        // Light/dark changes arrive as "ImmersiveColorSet"; skip the many other broadcasts.
        if (lParam && lstrcmpW(reinterpret_cast<const wchar_t*>(lParam), L"ImmersiveColorSet") == 0) ApplySystemAppearance();
        break;
    case WM_ENDSESSION:
        if (wParam && onClose) onClose();
        return 0;
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
