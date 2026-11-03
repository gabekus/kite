import KiteCore
import WinSDK

/// Kite's top-level browser window on Windows: a plain Win32 window that the
/// composition tree (sidebar, page texture, command bar) will be hosted in.
/// See docs/windows.md for the layering plan.
final class MainWindow {
    static let className = "KiteBrowserWindow"
    /// Window size at 96 DPI before any saved frame exists. Scaled per monitor.
    static let defaultSize = (width: Int32(1280), height: Int32(800))
    static let minimumSize = (width: Int32(500), height: Int32(400))

    private(set) var hwnd: HWND?
    var onClose: (() -> Void)?
    private var dpi: UINT = 96

    /// Every live window, keyed by its HWND, so the C window procedure can find its Swift object.
    nonisolated(unsafe) private static var windows: [HWND: MainWindow] = [:]

    static func registerClass(instance: HINSTANCE?) -> Bool {
        className.wide.withUnsafeBufferPointer { name in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = Win32.CS_HREDRAW | Win32.CS_VREDRAW
            wc.lpfnWndProc = { hwnd, message, wParam, lParam in
                MainWindow.handle(hwnd, message, wParam, lParam)
            }
            wc.hInstance = instance
            wc.hCursor = LoadCursorW(nil, Win32.arrowCursor)
            wc.lpszClassName = name.baseAddress
            return RegisterClassExW(&wc) != 0
        }
    }

    init?(instance: HINSTANCE?, title: String) {
        let systemDPI = GetDpiForSystem()
        let width = MulDiv(Self.defaultSize.width, Int32(systemDPI), 96)
        let height = MulDiv(Self.defaultSize.height, Int32(systemDPI), 96)
        let created = Self.className.wide.withUnsafeBufferPointer { cls in
            title.wide.withUnsafeBufferPointer { text in
                CreateWindowExW(
                    0, cls.baseAddress, text.baseAddress, Win32.WS_OVERLAPPEDWINDOW,
                    Win32.CW_USEDEFAULT, Win32.CW_USEDEFAULT, width, height,
                    nil, nil, instance, nil)
            }
        }
        guard let created else { return nil }
        hwnd = created
        dpi = GetDpiForWindow(created)
        Self.windows[created] = self
        applySystemAppearance()
    }

    func show() {
        guard let hwnd else { return }
        _ = ShowWindow(hwnd, Win32.SW_SHOWDEFAULT)
        _ = UpdateWindow(hwnd)
    }

    func setTitle(_ title: String) {
        guard let hwnd else { return }
        _ = title.wide.withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) }
    }

    func close() {
        guard let hwnd else { return }
        _ = PostMessageW(hwnd, Win32.WM_CLOSE, 0, 0)
    }

    /// Dark title bar when Windows apps are set to dark, the way every Win32 app opts in.
    private func applySystemAppearance() {
        guard let hwnd else { return }
        var dark: Int32 = SystemAppearance.appsUseDarkTheme ? 1 : 0
        _ = DwmSetWindowAttribute(hwnd, Win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, DWORD(MemoryLayout<Int32>.size))
    }

    private static func handle(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        guard let hwnd, let window = windows[hwnd] else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        switch message {
        case Win32.WM_DPICHANGED:
            // Use the rect Windows suggests so the window keeps its physical size on the new monitor.
            window.dpi = UINT(hiWord(wParam))
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                _ = SetWindowPos(hwnd, nil, suggested.left, suggested.top,
                             suggested.right - suggested.left, suggested.bottom - suggested.top,
                             Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE)
            }
            return 0
        case Win32.WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                let scale = Int32(window.dpi == 0 ? 96 : window.dpi)
                info.pointee.ptMinTrackSize.x = MulDiv(minimumSize.width, scale, 96)
                info.pointee.ptMinTrackSize.y = MulDiv(minimumSize.height, scale, 96)
            }
            return 0
        case Win32.WM_SETTINGCHANGE:
            window.applySystemAppearance()
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case Win32.WM_CLOSE:
            window.onClose?()
            _ = DestroyWindow(hwnd)
            return 0
        case Win32.WM_DESTROY:
            windows[hwnd] = nil
            window.hwnd = nil
            if windows.isEmpty { PostQuitMessage(0) }
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
