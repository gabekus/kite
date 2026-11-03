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

// "1280,800" → {1280, 800}; nullopt when malformed.
std::optional<std::pair<int, int>> ParseSize(const std::wstring& text) {
    size_t comma = text.find(L',');
    if (comma == std::wstring::npos) return std::nullopt;
    try {
        int w = std::stoi(text.substr(0, comma));
        int h = std::stoi(text.substr(comma + 1));
        if (w < kite::MainWindow::kMinimumWidth || h < kite::MainWindow::kMinimumHeight || w > 16384 || h > 16384) return std::nullopt;
        return std::make_pair(w, h);
    } catch (...) {
        return std::nullopt;
    }
}

constexpr UINT_PTR kSmokeTimer = 1;
constexpr UINT_PTR kCaptureTimer = 2;

int Fail(bool quiet, const std::wstring& message, int code) {
    OutputDebugStringW((L"Kite: " + message + L"\n").c_str());
    if (!quiet) MessageBoxW(nullptr, message.c_str(), L"Kite", MB_OK | MB_ICONERROR);
    return code;
}

// What --capture saves and why it failed, read back after the message loop.
std::filesystem::path gCapturePath;
std::wstring gCaptureError;

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    const std::vector<std::wstring> args = Arguments();
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

    auto resolved = kite::ResolveSupportDirectory(kite::EnvironmentPath("KITE_SUPPORT_PATH"), kite::EnvironmentPath("LOCALAPPDATA"));
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
    if (size) window.SetClientSize(size->first, size->second);
    window.Show(showCommand);

    if (smokeTest) {
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
