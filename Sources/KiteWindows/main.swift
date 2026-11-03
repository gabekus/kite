import Foundation
import KiteCore
import WinSDK

// Kite for Windows: the Win32 shell on top of KiteCore. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a
//                           second, saves the session and exits 0 (CI)

let arguments = CommandLine.arguments.dropFirst()
let smokeTest = arguments.contains("--smoke-test")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Kite: \(message)\n".utf8))
    exit(1)
}

// Per-monitor DPI awareness v2, so text and the window frame stay sharp on mixed-DPI setups.
// It has to be set before any window exists.
if SetProcessDpiAwarenessContext(Win32.perMonitorAwareV2) == false {
    FileHandle.standardError.write(Data("Kite: couldn't set per-monitor DPI awareness\n".utf8))
}

let supportDirectory: URL
do {
    guard let fallback = SupportDirectory.windowsDefault() else { fail("LOCALAPPDATA isn't set") }
    supportDirectory = try SupportDirectory.resolve(platformDefault: fallback)
} catch {
    fail("\(error)")
}

let session = SessionStore(fileURL: supportDirectory.appendingPathComponent("session.json"))
var state: BrowserState
do {
    state = try session.load() ?? BrowserState.makeDefault()
} catch {
    // load() already moved the unreadable file aside.
    FileHandle.standardError.write(Data("Kite: session unreadable, starting fresh: \(error)\n".utf8))
    state = BrowserState.makeDefault()
}

let instance = GetModuleHandleW(nil)
guard MainWindow.registerClass(instance: instance) else { fail("RegisterClassExW failed (\(GetLastError()))") }
guard let window = MainWindow(instance: instance, title: "Kite") else { fail("CreateWindowExW failed (\(GetLastError()))") }

func saveSession() {
    do { try session.save(state) } catch {
        FileHandle.standardError.write(Data("Kite: couldn't save the session: \(error)\n".utf8))
    }
}

window.onClose = saveSession
window.show()

if smokeTest {
    // A thread timer (no window): WM_TIMER goes through DispatchMessageW to this proc.
    _ = SetTimer(nil, 0, 1000) { _, _, _, _ in PostQuitMessage(0) }
}

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    _ = TranslateMessage(&message)
    _ = DispatchMessageW(&message)
}

if smokeTest {
    saveSession()
    print("smoke test ok: \(supportDirectory.appendingPathComponent("session.json").path)")
}
