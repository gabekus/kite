import WinSDK

enum SystemAppearance {
    /// Settings › Personalization › Colors › "Choose your default app mode".
    /// HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize, AppsUseLightTheme (0 = dark).
    static var appsUseDarkTheme: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let key = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#.wide
        let name = "AppsUseLightTheme".wide
        let status = key.withUnsafeBufferPointer { k in
            name.withUnsafeBufferPointer { n in
                RegGetValueW(Win32.HKEY_CURRENT_USER, k.baseAddress, n.baseAddress, Win32.RRF_RT_REG_DWORD, nil, &value, &size)
            }
        }
        return status == 0 && value == 0
    }
}
