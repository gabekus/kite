import WinSDK

// Win32 constants that are C macros Swift can't import (casts, MAKEINTRESOURCE),
// written out with their values from the Windows SDK headers.
enum Win32 {
    static let CW_USEDEFAULT = Int32(bitPattern: 0x8000_0000)
    static let WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000
    static let WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x0020_0000

    static let CS_VREDRAW: UINT = 0x0001
    static let CS_HREDRAW: UINT = 0x0002

    static let WM_DESTROY: UINT = 0x0002
    static let WM_SIZE: UINT = 0x0005
    static let WM_CLOSE: UINT = 0x0010
    static let WM_ERASEBKGND: UINT = 0x0014
    static let WM_SETTINGCHANGE: UINT = 0x001A
    static let WM_GETMINMAXINFO: UINT = 0x0024
    static let WM_TIMER: UINT = 0x0113
    static let WM_DPICHANGED: UINT = 0x02E0

    static let SW_SHOWDEFAULT: Int32 = 10
    static let SWP_NOZORDER: UINT = 0x0004
    static let SWP_NOACTIVATE: UINT = 0x0010

    /// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, ((DPI_AWARENESS_CONTEXT)-4).
    static let perMonitorAwareV2 = DPI_AWARENESS_CONTEXT(bitPattern: -4)
    /// IDC_ARROW, MAKEINTRESOURCE(32512).
    static let arrowCursor = UnsafePointer<WCHAR>(bitPattern: 32512)

    /// HKEY_CURRENT_USER, ((HKEY)(ULONG_PTR)((LONG)0x80000001)).
    static let HKEY_CURRENT_USER = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
    static let RRF_RT_REG_DWORD: DWORD = 0x0000_0010

    /// DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1 and later).
    static let DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20
}

extension String {
    /// NUL-terminated UTF-16, for the W functions.
    var wide: [WCHAR] { Array(utf16) + [0] }
}

/// LOWORD/HIWORD of a WPARAM or LPARAM.
@inline(__always) func loWord<T: BinaryInteger>(_ value: T) -> Int { Int(UInt64(truncatingIfNeeded: value) & 0xFFFF) }
@inline(__always) func hiWord<T: BinaryInteger>(_ value: T) -> Int { Int((UInt64(truncatingIfNeeded: value) >> 16) & 0xFFFF) }
