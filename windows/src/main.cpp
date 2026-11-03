// Kite for Windows. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second and
//                            exits 0 (CI). Errors go to the exit code, never a dialog.

#include <windows.h>

#include <filesystem>
#include <string>
#include <string_view>
#include <variant>

#include "core/SupportDirectory.h"
#include "shell/MainWindow.h"

namespace {

enum ExitCode : int { kOk = 0, kBadSupportDirectory = 2, kWindowFailed = 3 };

bool HasArgument(const wchar_t* commandLine, std::wstring_view argument) {
    std::wstring_view rest(commandLine ? commandLine : L"");
    while (!rest.empty()) {
        size_t start = rest.find_first_not_of(L' ');
        if (start == std::wstring_view::npos) break;
        rest.remove_prefix(start);
        size_t end = rest.find(L' ');
        if (rest.substr(0, end) == argument) return true;
        if (end == std::wstring_view::npos) break;
        rest.remove_prefix(end);
    }
    return false;
}

int Fail(bool quiet, const std::wstring& message, int code) {
    OutputDebugStringW((L"Kite: " + message + L"\n").c_str());
    if (!quiet) MessageBoxW(nullptr, message.c_str(), L"Kite", MB_OK | MB_ICONERROR);
    return code;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR commandLine, int showCommand) {
    const bool smokeTest = HasArgument(commandLine, L"--smoke-test");

    auto resolved = kite::ResolveSupportDirectory(kite::EnvironmentVariable(L"KITE_SUPPORT_PATH"),
                                                  kite::EnvironmentVariable(L"LOCALAPPDATA"));
    if (auto* error = std::get_if<kite::SupportDirectoryError>(&resolved)) {
        return Fail(smokeTest, error->message, kBadSupportDirectory);
    }
    const std::filesystem::path supportDirectory = std::get<std::filesystem::path>(resolved);
    std::error_code ignored;
    std::filesystem::create_directories(supportDirectory, ignored);

    if (!kite::MainWindow::RegisterWindowClass(instance)) {
        return Fail(smokeTest, L"RegisterClassExW failed", kWindowFailed);
    }
    kite::MainWindow window(instance);
    if (!window.IsValid()) return Fail(smokeTest, L"CreateWindowExW failed", kWindowFailed);
    window.Show(showCommand);

    if (smokeTest) SetTimer(window.Handle(), 1, 1000, [](HWND hwnd, UINT, UINT_PTR, DWORD) { PostMessageW(hwnd, WM_CLOSE, 0, 0); });

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return kOk;
}
