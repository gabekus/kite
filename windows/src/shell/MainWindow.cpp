// Kite's Win32 browser window; see MainWindow.h.

#include "shell/MainWindow.h"

#include <dwmapi.h>
#include <shellapi.h>
#include <windowsx.h>

namespace kite {
namespace {

constexpr wchar_t kClassName[] = L"KiteBrowserWindow";

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
constexpr DWORD DWMWA_USE_IMMERSIVE_DARK_MODE = 20;  // Windows 10 20H1+
#endif
// Windows 11 22H2+ (dwmapi.h in newer SDKs has these; MinGW's doesn't).
constexpr DWORD kSystemBackdropType = 38;    // DWMWA_SYSTEMBACKDROP_TYPE
constexpr int kBackdropTransientWindow = 3;  // DWMSBT_TRANSIENTWINDOW: acrylic

int Scale(int value, UINT dpi) { return MulDiv(value, static_cast<int>(dpi), USER_DEFAULT_SCREEN_DPI); }

constexpr DWORD kStyle = WS_OVERLAPPEDWINDOW;

// Whether an auto-hiding taskbar sits on `edge` (ABE_LEFT…) of `monitor`: a maximized window
// then leaves a pixel there so the pointer can still bring the taskbar up.
bool AutoHideTaskbarOn(UINT edge, const RECT& monitor) {
    APPBARDATA data{};
    data.cbSize = sizeof(data);
    data.uEdge = edge;
    data.rc = monitor;
    return SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &data) != 0;
}

}  // namespace

bool MainWindow::RegisterWindowClass(HINSTANCE instance) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &MainWindow::WindowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;  // DirectComposition draws everything
    wc.lpszClassName = kClassName;
    return RegisterClassExW(&wc) != 0;
}

MainWindow::MainWindow(HINSTANCE instance) {
    // The default size is the client area, like the Mac's content rect; add the frame to it.
    UINT systemDpi = GetDpiForSystem();
    RECT rect{0, 0, Scale(kDefaultWidth, systemDpi), Scale(kDefaultHeight, systemDpi)};
    AdjustWindowRectExForDpi(&rect, kStyle, FALSE, 0, systemDpi);
    rect.top = 0;  // no caption (WM_NCCALCSIZE)
    CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP, kClassName, L"Kite", kStyle, CW_USEDEFAULT, CW_USEDEFAULT,
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

void MainWindow::UseFixedScale(int scale) {
    fixedScale_ = true;
    dpi_ = static_cast<UINT>(USER_DEFAULT_SCREEN_DPI * scale);
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
    // The client area at the layout scale; the frame at the monitor's (they differ under
    // UseFixedScale).
    const RECT rect = FrameAround(Scale(width, dpi_), Scale(height, dpi_));
    SetWindowPos(hwnd_, nullptr, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

RECT MainWindow::FrameAround(int width, int height) const {
    RECT rect{0, 0, width, height};
    AdjustWindowRectExForDpi(&rect, static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_STYLE)), FALSE,
                             static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_EXSTYLE)), GetDpiForWindow(hwnd_));
    rect.top = 0;  // the caption WM_NCCALCSIZE takes off
    return rect;
}

int MainWindow::ResizeBorder() const {
    const UINT dpi = GetDpiForWindow(hwnd_);
    return GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

void MainWindow::SetDarkAppearance(bool dark) {
    BOOL value = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &value, sizeof(value));
}

bool MainWindow::UseSystemBackdrop() {
    int type = kBackdropTransientWindow;
    if (FAILED(DwmSetWindowAttribute(hwnd_, kSystemBackdropType, &type, sizeof(type)))) return false;
    // The backdrop shows through the client area only where the frame extends into it.
    MARGINS everywhere{-1, -1, -1, -1};
    return SUCCEEDED(DwmExtendFrameIntoClientArea(hwnd_, &everywhere));
}

LRESULT CALLBACK MainWindow::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* window = static_cast<MainWindow*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
        window->hwnd_ = hwnd;
        window->dpi_ = GetDpiForWindow(hwnd);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window));
    }
    auto* window = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!window) return DefWindowProcW(hwnd, message, wParam, lParam);
    return window->Handle(message, wParam, lParam);
}

LRESULT MainWindow::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    if (filter) {
        LRESULT result = 0;
        if (filter(message, wParam, lParam, result)) return result;
    }
    switch (message) {
    case WM_NCCALCSIZE: {
        if (!wParam) break;
        // Windows' frame on the left, right and bottom (its resize borders, invisible on
        // Windows 10 and 11), but none at the top: the client area starts at the window's top
        // edge, and its top resize border is hit-tested in it (WM_NCHITTEST).
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lParam);
        const LONG top = params->rgrc[0].top;
        if (const LRESULT result = DefWindowProcW(hwnd_, message, wParam, lParam); result != 0) return result;
        params->rgrc[0].top = top;
        if (IsZoomed(hwnd_)) {
            // A maximized window hangs off the screen by its resize border; the client area
            // starts on the screen.
            params->rgrc[0].top += ResizeBorder();
            // And it leaves a pixel for an auto-hiding taskbar to come up from.
            MONITORINFO monitor{};
            monitor.cbSize = sizeof(monitor);
            if (GetMonitorInfoW(MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST), &monitor)) {
                RECT& client = params->rgrc[0];
                if (AutoHideTaskbarOn(ABE_TOP, monitor.rcMonitor)) client.top += 1;
                if (AutoHideTaskbarOn(ABE_BOTTOM, monitor.rcMonitor)) client.bottom -= 1;
                if (AutoHideTaskbarOn(ABE_LEFT, monitor.rcMonitor)) client.left += 1;
                if (AutoHideTaskbarOn(ABE_RIGHT, monitor.rcMonitor)) client.right -= 1;
            }
        }
        return 0;
    }
    case WM_NCHITTEST: {
        // The left, right and bottom borders are still Windows' frame.
        const LRESULT frame = DefWindowProcW(hwnd_, message, wParam, lParam);
        if (frame != HTCLIENT) return frame;
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(hwnd_, &at);
        // The top resize border, over everything (as over a standard title bar), but for a
        // maximized window, which doesn't resize.
        const int border = ResizeBorder();
        if (!IsZoomed(hwnd_) && at.y < border) {
            RECT client{};
            GetClientRect(hwnd_, &client);
            if (at.x < border) return HTTOPLEFT;
            if (at.x >= client.right - border) return HTTOPRIGHT;
            return HTTOP;
        }
        return hitTest ? hitTest(at) : HTCLIENT;
    }
    case WM_DPICHANGED: {
        if (fixedScale_) return 0;
        // Take the rect Windows suggests so the window keeps its physical size on the new monitor.
        dpi_ = HIWORD(wParam);
        const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
        RECT before{}, after{};
        GetClientRect(hwnd_, &before);
        SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        // A window whose size in pixels stays the same (a maximized one, when the monitor's
        // scale changes) gets no WM_SIZE: lay it out at the new scale here.
        GetClientRect(hwnd_, &after);
        if (after.right == before.right && after.bottom == before.bottom && !IsIconic(hwnd_) && onSize) onSize();
        return 0;
    }
    case WM_GETMINMAXINFO: {
        auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
        // The minimum is the client area, like the Mac's (whose frame is its content with
        // .fullSizeContentView); Windows wants the outer size, so add the frame.
        const RECT frame = FrameAround(Scale(kMinimumWidth, dpi_), Scale(kMinimumHeight, dpi_));
        info->ptMinTrackSize.x = frame.right - frame.left;
        info->ptMinTrackSize.y = frame.bottom - frame.top;
        if (allowLargerThanScreen_) info->ptMaxTrackSize = {32767, 32767};
        return 0;
    }
    case WM_SIZE:
        if (wParam == SIZE_MINIMIZED) {
            if (onMinimize) onMinimize();
        } else if (onSize) {
            onSize();
        }
        return 0;
    case WM_MOVE:
        if (onMove) onMove();
        return 0;
    case WM_ERASEBKGND:
        return 1;  // nothing to erase: there's no redirection bitmap
    case WM_PAINT: {
        PAINTSTRUCT paint;
        BeginPaint(hwnd_, &paint);  // validates; the composition tree is already on screen
        EndPaint(hwnd_, &paint);
        return 0;
    }
    case kWakeMessage:
        if (onWake) onWake();
        return 0;
    case WM_SETFOCUS:
        if (onFocus) onFocus();
        return 0;
    case WM_ENDSESSION:
        if (wParam && onClose) onClose();
        return 0;
    case WM_CLOSE:
        if (mayClose && !mayClose()) return 0;
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
