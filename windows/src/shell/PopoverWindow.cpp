// See PopoverWindow.h. Moved out of W9e's SpaceIconPickerView for W9f's ThemeSwatchesView.

#include "shell/PopoverWindow.h"

#include <windowsx.h>

namespace kite {

namespace {

constexpr wchar_t kClassName[] = L"KitePopover";

bool RegisterOnce(HINSTANCE instance, WNDPROC proc) {
    static const bool registered = [&] {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = proc;
        wc.hInstance = instance;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kClassName;
        return RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
    }();
    return registered;
}

}  // namespace

PopoverWindow::~PopoverWindow() {
    target_.Reset();
    callbacks_ = {};
    if (window_) DestroyWindow(window_);
}

std::wstring PopoverWindow::Make() {
    if (window_) return {};
    const HINSTANCE instance = reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(owner_, GWLP_HINSTANCE));
    if (!RegisterOnce(instance, &PopoverWindow::WindowProc)) return L"registering the popover's window class failed";
    // Owned by the browser window (over it, minimized with it), never activated, never in the
    // taskbar or Alt+Tab; DirectComposition draws all of it.
    const HWND made = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName, L"", WS_POPUP, 0, 0, 1, 1,
                                      owner_, nullptr, instance, this);
    if (!made) return L"creating the popover's window failed";
    window_ = made;
    return {};
}

LRESULT CALLBACK PopoverWindow::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
    }
    auto* popover = reinterpret_cast<PopoverWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    // Only once CreateWindowExW has returned it (WM_NCCREATE, WM_CREATE and the rest before that
    // are the default's), and never after it's gone.
    if (popover && popover->window_ == hwnd) return popover->Handle(message, wParam, lParam);
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

LRESULT PopoverWindow::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;  // the browser window keeps the keyboard
    case WM_NCHITTEST: {
        if (!callbacks_.onPopover) break;
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(window_, &at);
        return callbacks_.onPopover(at) ? HTCLIENT : HTTRANSPARENT;
    }
    // Windows shows an owned window again with its restored owner: only its view shows it.
    case WM_SHOWWINDOW:
        if (wParam && lParam == SW_PARENTOPENING) return 0;
        break;
    case WM_NCDESTROY: {
        // Destroyed with its owner (the browser window's close): forgotten, never used again.
        const HWND gone = window_;
        window_ = nullptr;
        target_.Reset();
        if (callbacks_.destroyed) callbacks_.destroyed();
        return DefWindowProcW(gone, message, wParam, lParam);
    }
    default: break;
    }
    if (callbacks_.message) {
        if (const std::optional<LRESULT> handled = callbacks_.message(message, wParam, lParam)) return *handled;
    }
    return DefWindowProcW(window_, message, wParam, lParam);
}

HRESULT PopoverWindow::MakeTarget(IDCompositionDevice* device, IDCompositionVisual* root) {
    if (target_) return S_OK;
    if (!window_) return E_HANDLE;
    HRESULT hr = device->CreateTargetForHwnd(window_, TRUE, target_.GetAddressOf());
    if (SUCCEEDED(hr)) hr = target_->SetRoot(root);
    if (FAILED(hr)) target_.Reset();
    return hr;
}

void PopoverWindow::Place(POINT topLeft, UINT width, UINT height, bool show) {
    if (!window_) return;
    // Its place in the z-order kept: just over its owner (an owned window always is), never over
    // another app's window that covers Kite's.
    SetWindowPos(window_, nullptr, topLeft.x, topLeft.y, static_cast<int>(width), static_cast<int>(height),
                 SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : 0) | SWP_NOOWNERZORDER | SWP_NOZORDER);
}

void PopoverWindow::Hide() {
    if (!window_) return;
    if (GetCapture() == window_) ReleaseCapture();
    ShowWindow(window_, SW_HIDE);
}

RECT PopoverWindow::WorkArea(POINT screen) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoW(MonitorFromPoint(screen, MONITOR_DEFAULTTONEAREST), &monitor)) return RECT{-100000, -100000, 100000, 100000};
    return monitor.rcWork;
}

}  // namespace kite
