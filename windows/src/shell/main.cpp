// Kite for Windows. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second, saves
//                            the session and exits 0 (CI). Errors go to the exit code,
//                            never a dialog.
//   Kite.exe --capture FILE.png [--window-size W,H] [--capture-scale N]
//                            opens the window at W×H points (client area), saves it as
//                            a PNG half a second after showing it and exits: the Helix UI
//                            gate (docs/helix.md). --capture-scale fails the capture unless
//                            the window's monitor is at N× (2 to line up with a Retina Mac).
//                            Pair with KITE_SUPPORT_PATH and a session from windows/helix/states.

#include <windows.h>

#include <shellapi.h>

#include <charconv>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>
#include <string_view>
#include <variant>

#include "core/SessionStore.h"
#include "core/SupportDirectory.h"
#include "shell/Capture.h"
#include "shell/MainWindow.h"

namespace {

enum ExitCode : int { kOk = 0, kUsage = 1, kBadSupportDirectory = 2, kWindowFailed = 3, kSaveFailed = 4, kCaptureFailed = 5 };

std::wstring Widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), size);
    return out;
}

// Arguments after the program name, split by CommandLineToArgvW's rules (quotes, backslashes).
std::vector<std::wstring> Arguments() {
    int count = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
    std::vector<std::wstring> out;
    for (int i = 1; argv && i < count; ++i) out.emplace_back(argv[i]);
    if (argv) LocalFree(argv);
    return out;
}

bool HasFlag(const std::vector<std::wstring>& args, std::wstring_view flag) {
    for (const auto& a : args) {
        if (a == flag) return true;
    }
    return false;
}

// An option's value. A flag given without one (last on the line) is a usage error, never
// silently ignored: that would turn a quiet CI run into a normal launch that never exits.
struct OptionValue {
    bool present = false;
    std::optional<std::wstring> value;
};

OptionValue Option(const std::vector<std::wstring>& args, std::wstring_view name) {
    for (size_t i = 0; i < args.size(); ++i) {
        if (args[i] == name) return {true, i + 1 < args.size() ? std::optional<std::wstring>(args[i + 1]) : std::nullopt};
    }
    return {};
}

// One whole decimal number, nothing else ("1280", not " 1280", "+1280" or "1280px").
std::optional<int> ParseInt(std::wstring_view text) {
    std::string narrow;
    for (wchar_t c : text) {
        if (c < L'0' || c > L'9') return std::nullopt;
        narrow += static_cast<char>(c);
    }
    int value = 0;
    auto [end, ec] = std::from_chars(narrow.data(), narrow.data() + narrow.size(), value);
    if (narrow.empty() || ec != std::errc() || end != narrow.data() + narrow.size()) return std::nullopt;
    return value;
}

// "1280,800" → {1280, 800}; nullopt when malformed.
std::optional<std::pair<int, int>> ParseSize(std::wstring_view text) {
    size_t comma = text.find(L',');
    if (comma == std::wstring_view::npos) return std::nullopt;
    auto w = ParseInt(text.substr(0, comma));
    auto h = ParseInt(text.substr(comma + 1));
    if (!w || !h) return std::nullopt;
    if (*w < kite::MainWindow::kMinimumWidth || *h < kite::MainWindow::kMinimumHeight || *w > 8192 || *h > 8192) return std::nullopt;
    return std::make_pair(*w, *h);
}

constexpr UINT_PTR kSmokeTimer = 1;
constexpr UINT_PTR kCaptureTimer = 2;

int Fail(bool quiet, const std::wstring& message, int code) {
    OutputDebugStringW((L"Kite: " + message + L"\n").c_str());
    // A GUI process has no console, but a launcher that redirects stderr (CI) gets the reason.
    HANDLE stderrHandle = GetStdHandle(STD_ERROR_HANDLE);
    if (stderrHandle && stderrHandle != INVALID_HANDLE_VALUE) {
        std::wstring line = L"Kite: " + message + L"\n";
        int bytes = WideCharToMultiByte(CP_UTF8, 0, line.c_str(), static_cast<int>(line.size()), nullptr, 0, nullptr, nullptr);
        std::string utf8(static_cast<size_t>(bytes > 0 ? bytes : 0), '\0');
        if (bytes > 0) WideCharToMultiByte(CP_UTF8, 0, line.c_str(), static_cast<int>(line.size()), utf8.data(), bytes, nullptr, nullptr);
        DWORD written = 0;
        WriteFile(stderrHandle, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
    }
    if (!quiet) MessageBoxW(nullptr, message.c_str(), L"Kite", MB_OK | MB_ICONERROR);
    return code;
}

// What --capture saves and why it failed, read back after the message loop.
std::filesystem::path gCapturePath;
std::wstring gCaptureError;

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    const std::vector<std::wstring> args = Arguments();
    // An unknown flag (a typo like --smoketest or --capture-scale=2) is an error, never a
    // normal launch on the real profile.
    for (size_t i = 0; i < args.size(); ++i) {
        const std::wstring& a = args[i];
        if (a == L"--smoke-test") continue;
        if (a == L"--capture" || a == L"--window-size" || a == L"--capture-scale") { ++i; continue; }
        if (a.starts_with(L"-")) return Fail(true, L"unknown option " + a, kUsage);
    }
    const bool smokeTest = HasFlag(args, L"--smoke-test");
    const OptionValue captureOption = Option(args, L"--capture");
    const OptionValue sizeOption = Option(args, L"--window-size");
    const std::optional<std::wstring>& capture = captureOption.value;
    const bool quiet = smokeTest || captureOption.present;
    if (captureOption.present && !capture) return Fail(quiet, L"--capture takes a PNG path", kUsage);
    const OptionValue scaleOption = Option(args, L"--capture-scale");
    int captureScale = 0;
    if (scaleOption.present) {
        if (scaleOption.value && scaleOption.value->size() == 1 && (*scaleOption.value)[0] >= L'1' && (*scaleOption.value)[0] <= L'4') {
            captureScale = (*scaleOption.value)[0] - L'0';
        } else {
            return Fail(quiet, L"--capture-scale takes 1 to 4", kUsage);
        }
    }
    std::optional<std::pair<int, int>> size;
    if (sizeOption.present && !(sizeOption.value && (size = ParseSize(*sizeOption.value)))) {
        return Fail(quiet, L"--window-size takes W,H in points", kUsage);
    }

    const auto supportOverride = kite::EnvironmentPath("KITE_SUPPORT_PATH");
    // Test flags only run on a test profile, like the Mac's KITE_WINDOW_SIZE: a smoke test or
    // capture loads and re-saves the session, which must never be the user's own.
    if ((smokeTest || captureOption.present || sizeOption.present || scaleOption.present) && !supportOverride) {
        return Fail(quiet, L"--smoke-test, --capture, --window-size and --capture-scale need KITE_SUPPORT_PATH set to a test profile", kUsage);
    }
    auto resolved = kite::ResolveSupportDirectory(supportOverride, kite::EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<kite::SupportDirectoryError>(&resolved)) {
        return Fail(quiet, Widen(error->message), kBadSupportDirectory);
    }
    const std::filesystem::path supportDirectory = std::get<std::filesystem::path>(resolved);
    std::error_code ignored;
    std::filesystem::create_directories(supportDirectory, ignored);

    // The session: the Mac's session.json format (core/SessionStore.h). Loaded before the
    // window exists and saved as it closes, the two places the UI thread may touch it
    // (docs/windows-architecture.md).
    kite::SessionStore session(supportDirectory / L"session.json");
    kite::BrowserState state;
    auto loaded = session.Load();
    // When the file is still there but unreadable (locked, couldn't be moved aside), run
    // without saving rather than replace the user's tabs with a fresh session.
    const bool maySave = kite::SessionStore::MaySave(loaded);
    if (auto* existing = std::get_if<kite::BrowserState>(&loaded)) {
        state = std::move(*existing);
    } else {
        if (auto* error = std::get_if<kite::SessionStore::Error>(&loaded)) {
            OutputDebugStringW((L"Kite: session unreadable, starting fresh" + std::wstring(maySave ? L"" : L" without saving") +
                                L": " + Widen(error->message) + L"\n").c_str());
        }
        state = kite::BrowserState::MakeDefault();
    }
    // A test run must show the session it was given, never a default in its place.
    if (quiet && std::holds_alternative<kite::SessionStore::Error>(loaded)) {
        return Fail(quiet, L"couldn't read the session: " + Widen(std::get<kite::SessionStore::Error>(loaded).message), kSaveFailed);
    }
    std::string saveError;
    std::wstring loadError;
    if (auto* error = std::get_if<kite::SessionStore::Error>(&loaded); error && !maySave) loadError = Widen(error->message);

    if (!kite::MainWindow::RegisterWindowClass(instance)) {
        return Fail(quiet, L"RegisterClassExW failed", kWindowFailed);
    }
    kite::MainWindow window(instance);
    if (!window.IsValid()) return Fail(quiet, L"CreateWindowExW failed", kWindowFailed);
    // Closing the window, and logoff or shutdown (which skip WM_CLOSE), both save.
    window.onClose = [&] {
        if (maySave) saveError = session.Save(state);
    };
    // A capture always has a set size (the Mac's default unless asked), even on a small screen.
    if (capture && !size) size = std::make_pair(kite::MainWindow::kDefaultWidth, kite::MainWindow::kDefaultHeight);
    if (size) window.SetClientSize(size->first, size->second);
    // Quiet runs open behind other windows without focus, and ignore a launcher's "start maximized".
    if (quiet) window.ShowBehindOtherWindows();
    else window.Show(showCommand);
    if (capture && !window.HasClientSize(size->first, size->second)) {
        // A capture is compared pixel for pixel with the Mac's, so a window Windows resized
        // (maximized by the launcher, clamped to 32767 px) would compare the wrong thing.
        return Fail(quiet, L"the window didn't get the size --capture needs", kCaptureFailed);
    }

    if (smokeTest) {
        // The manifest took effect: without it the window would be DPI-unaware and text in the
        // ANSI code page, which a 100% CI display can't tell apart by size alone.
        if (!AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(window.Handle()), DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
            return Fail(quiet, L"the window isn't per-monitor DPI aware (v2): Kite.manifest wasn't embedded", kWindowFailed);
        }
        if (GetACP() != CP_UTF8) return Fail(quiet, L"the process code page isn't UTF-8: Kite.manifest wasn't embedded", kWindowFailed);
        SetTimer(window.Handle(), kSmokeTimer, 1000, [](HWND hwnd, UINT, UINT_PTR, DWORD) { PostMessageW(hwnd, WM_CLOSE, 0, 0); });
    }
    if (capture && captureScale) {
        // Captures are compared pixel for pixel, so the scale has to match the reference's.
        UINT dpi = GetDpiForWindow(window.Handle());
        if (dpi != static_cast<UINT>(captureScale) * USER_DEFAULT_SCREEN_DPI) {
            return Fail(quiet, L"the window is at " + std::to_wstring(dpi * 100 / USER_DEFAULT_SCREEN_DPI) + L"% scale; --capture-scale " +
                                   std::to_wstring(captureScale) + L" needs " + std::to_wstring(captureScale * 100) + L"%",
                        kCaptureFailed);
        }
    }
    if (capture) {
        // A fixed half second for now; from W3 the capture waits for the compositor's first
        // presented frame instead (windows/helix/checkpoints.md).
        gCapturePath = *capture;
        SetTimer(window.Handle(), kCaptureTimer, 500, [](HWND hwnd, UINT, UINT_PTR id, DWORD) {
            KillTimer(hwnd, id);
            gCaptureError = kite::CaptureClientToPng(hwnd, gCapturePath);
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
        });
    }

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (capture && !gCaptureError.empty()) return Fail(quiet, L"Capture failed: " + gCaptureError, kCaptureFailed);
    if (!maySave) {
        return Fail(quiet, L"Kite couldn't read your session (" + loadError + L"), so it left the file as it was and didn't save this run's tabs.",
                    kSaveFailed);
    }
    if (!saveError.empty()) return Fail(quiet, L"Couldn't save the session: " + Widen(saveError), kSaveFailed);
    return kOk;
}
