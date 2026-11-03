// Kite for Windows. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second (with
//                            Chromium: until the selected tab's page has loaded, at most
//                            30 s), saves the session and exits 0 (CI). Errors go to the
//                            exit code, never a dialog.
//   Kite.exe --capture FILE.png [--window-size W,H] [--capture-scale N]
//                            opens the window at W×H points (client area), saves the frame
//                            it presents as a PNG and exits: the Helix UI gate
//                            (docs/helix.md). The window is laid out at N× (default: the
//                            monitor's scale), so a 2× capture lines up with a Retina Mac on
//                            any monitor, and drawn over the solid material fallback rather
//                            than whatever is behind it.
//                            Pair with KITE_SUPPORT_PATH and a session from windows/helix/states.
//   Kite.exe --backdrop-test draws the theme backdrop on the GPU and checks every pixel against
//                            core's CPU reference of the Mac's shader (shell/BackdropTest.h).
//                            Prints a report; exits 0 when it matches, 5 when it differs, 3
//                            when it couldn't run (no GPU device, no float target).

#include <windows.h>

#include <shellapi.h>

#include <algorithm>
#include <charconv>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "core/OKLab.h"
#include "core/SessionStore.h"
#include "core/SupportDirectory.h"
#include "core/ThemeBackdrop.h"
#include "shell/BackdropTest.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/Errors.h"
#include "shell/MainWindow.h"
#include "shell/Renderer.h"

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

// The content card, in points: right of the sidebar, inset on the other three sides
// (BrowserWindowController's Layout.defaultSidebarWidth and ArcMetrics.Content.inset).
constexpr int kSidebarWidth = 240;
constexpr int kContentInset = 10;

// Writes `text` as UTF-8 to a standard handle, if the launcher gave us one (a GUI process
// has no console, but a launcher that redirects stdout or stderr, like CI, gets the text).
void WriteUtf8(DWORD which, const std::wstring& text) {
    HANDLE handle = GetStdHandle(which);
    if (!handle || handle == INVALID_HANDLE_VALUE || text.empty()) return;
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return;
    std::string utf8(static_cast<size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), utf8.data(), bytes, nullptr, nullptr);
    DWORD written = 0;
    WriteFile(handle, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
}

int Fail(bool quiet, const std::wstring& message, int code) {
    OutputDebugStringW((L"Kite: " + message + L"\n").c_str());
    WriteUtf8(STD_ERROR_HANDLE, L"Kite: " + message + L"\n");
    if (!quiet) MessageBoxW(nullptr, message.c_str(), L"Kite", MB_OK | MB_ICONERROR);
    return code;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
#ifdef KITE_HAS_CEF
    // Chromium starts Kite.exe again for its renderer, GPU and utility processes.
    if (const int code = kite::RunChromiumSubprocess(instance); code >= 0) return code;
#endif
    const std::vector<std::wstring> args = Arguments();
    // An unknown flag (a typo like --smoketest or --capture-scale=2) is an error, never a
    // normal launch on the real profile.
    for (size_t i = 0; i < args.size(); ++i) {
        const std::wstring& a = args[i];
        if (a == L"--smoke-test" || a == L"--backdrop-test") continue;
        if (a == L"--capture" || a == L"--window-size" || a == L"--capture-scale") { ++i; continue; }
        if (a.starts_with(L"-")) return Fail(true, L"unknown option " + a, kUsage);
    }
    if (HasFlag(args, L"--backdrop-test")) {
        // Touches no profile, so it needs no KITE_SUPPORT_PATH.
        std::wstring report, problem;
        const kite::BackdropTestOutcome outcome = kite::RunBackdropTest(report, problem);
        OutputDebugStringW(report.c_str());
        WriteUtf8(STD_OUTPUT_HANDLE, report);
        switch (outcome) {
        case kite::BackdropTestOutcome::Matches: return kOk;
        case kite::BackdropTestOutcome::Differs: return Fail(true, L"the GPU backdrop doesn't match the reference:\n" + problem, kCaptureFailed);
        case kite::BackdropTestOutcome::CouldNotRun: return Fail(true, L"the GPU couldn't draw the backdrop: " + problem, kWindowFailed);
        }
        return kWindowFailed;
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
    if (scaleOption.present && !captureOption.present) return Fail(quiet, L"--capture-scale only goes with --capture", kUsage);

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

    // The GPU first: everything below is set up before the window shows, so it never
    // appears empty or with the wrong title bar.
    std::wstring gpuError;
    std::unique_ptr<kite::Renderer> renderer = kite::Renderer::Create(gpuError);
    if (!renderer) return Fail(quiet, L"Kite couldn't start Direct3D: " + gpuError, kWindowFailed);

    if (!kite::MainWindow::RegisterWindowClass(instance)) {
        return Fail(quiet, L"RegisterClassExW failed", kWindowFailed);
    }
#ifdef KITE_HAS_CEF
    // Declared before the window so it goes after it: closing the window destroys the
    // browsers' windows, which Chromium's shutdown waits for.
    std::unique_ptr<kite::Chromium> chromium;
#endif
    kite::MainWindow window(instance);
    if (!window.IsValid()) return Fail(quiet, L"CreateWindowExW failed", kWindowFailed);
    // Closing the window, and logoff or shutdown (which skip WM_CLOSE), both save.
    window.onClose = [&] {
        if (maySave) saveError = session.Save(state);
    };

    // The backdrop: the selected space's theme over the system's acrylic, or over a solid
    // colour where there's none. A capture always uses the solid colour, so it doesn't depend
    // on what's behind the window. Drawn now and then only when something changes; W9 adds
    // the space-switch crossfade.
    const kite::Theme theme = state.SelectedSpace().theme;
    const bool dark = !kite::PrefersDarkForeground(theme);
    window.SetDarkAppearance(dark);
    const bool systemBackdrop = !capture && window.UseSystemBackdrop();
    const kite::Rgba base = systemBackdrop ? kite::Rgba{} : kite::MaterialFallback(dark);
    std::unique_ptr<kite::Compositor> compositor = kite::Compositor::Create(window.Handle(), *renderer, gpuError);
    if (!compositor) return Fail(quiet, L"Kite couldn't start DirectComposition: " + gpuError, kWindowFailed);
    // After the GPU is reset or removed, both are rebuilt on whatever adapter is there now.
    auto rebuild = [&]() -> std::wstring {
        std::wstring problem;
        compositor.reset();  // first: a window holds one composition target at a time
        renderer = kite::Renderer::Create(problem);
        if (renderer) compositor = kite::Compositor::Create(window.Handle(), *renderer, problem);
        return problem;
    };
    auto draw = [&](kite::Pixels* readBack = nullptr) -> std::wstring {
        RECT client{};
        GetClientRect(window.Handle(), &client);
        const UINT width = static_cast<UINT>(client.right), height = static_cast<UINT>(client.bottom);
        std::wstring problem;
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (!compositor || compositor->DeviceLost()) {
                if (problem = rebuild(); !problem.empty()) break;
            }
            problem = compositor->Draw(width, height, kite::MakeThemeUniforms(theme, static_cast<float>(width), static_cast<float>(height)),
                                       base, readBack);
            if (!compositor->DeviceLost()) break;
        }
        if (!problem.empty()) OutputDebugStringW((L"Kite: drawing failed: " + problem + L"\n").c_str());
        return problem;
    };
    window.onSize = [&] { draw(); };
    // On an early return the compositor goes before the window: stop drawing first.
    struct StopDrawing {
        kite::MainWindow& window;
        ~StopDrawing() { window.onSize = nullptr; }
    } stopDrawing{window};

    // Sized after the swap chain exists, so a capture also goes through a resize, as a real
    // window does when it's moved to another monitor or maximized.
    if (captureScale) window.UseFixedScale(captureScale);
    // A capture always has a set size (the Mac's default unless asked), even on a small screen.
    if (capture && !size) size = std::make_pair(kite::MainWindow::kDefaultWidth, kite::MainWindow::kDefaultHeight);
    if (capture) {
        // A capture is one texture: refuse one the GPU can't hold, before sizing (and so
        // drawing) the window that big, rather than save it stretched.
        const int dpi = captureScale ? USER_DEFAULT_SCREEN_DPI * captureScale : static_cast<int>(GetDpiForWindow(window.Handle()));
        const int widthPx = MulDiv(size->first, dpi, USER_DEFAULT_SCREEN_DPI);
        const int heightPx = MulDiv(size->second, dpi, USER_DEFAULT_SCREEN_DPI);
        if (static_cast<UINT>(std::max(widthPx, heightPx)) > renderer->MaxTextureSize()) {
            return Fail(quiet, L"the capture would be " + std::to_wstring(widthPx) + L"×" + std::to_wstring(heightPx) +
                                   L" px, more than this GPU's " + std::to_wstring(renderer->MaxTextureSize()) + L" px a side",
                        kUsage);
        }
    }
    if (size) window.SetClientSize(size->first, size->second);
    if (std::wstring problem = draw(); !problem.empty()) {
        return Fail(quiet, L"Kite couldn't draw its window: " + problem, kWindowFailed);
    }

#ifdef KITE_HAS_CEF
    // The selected tab's page on the content card. A capture leaves Chromium out: it saves
    // the backdrop alone until W4 captures the composed window.
    bool pageLoaded = false, pageLoading = false;
    ULONGLONG closeAskedAt = 0;  // when the smoke test asked the window to close
    auto contentBounds = [&] {
        RECT client{};
        GetClientRect(window.Handle(), &client);
        const int dpi = static_cast<int>(window.Dpi());
        auto px = [dpi](int points) { return MulDiv(points, dpi, USER_DEFAULT_SCREEN_DPI); };
        RECT card{px(kSidebarWidth), px(kContentInset), client.right - px(kContentInset), client.bottom - px(kContentInset)};
        card.right = std::max(card.right, card.left + 1);
        card.bottom = std::max(card.bottom, card.top + 1);
        return card;
    };
    auto showSelectedTab = [&] {
        const kite::Tab* tab = state.SelectedTab();
        if (!tab) return;  // the Mac's empty state arrives with the command bar (W7)
        const std::string url = tab->url ? *tab->url : tab->pinnedURL.value_or("");
        chromium->Show(tab->id, state.SelectedProfileDirectory(), url, contentBounds());
    };
    if (!capture) {
        auto tabNamed = [&](const std::string& id) -> kite::Tab* {
            auto location = state.Location(id);
            return location ? state.TabAt(*location) : nullptr;
        };
        kite::PageEvents events;
        events.addressChanged = [&, tabNamed](const std::string& id, const std::string& url) {
            if (kite::Tab* tab = tabNamed(id)) tab->url = url;
        };
        events.titleChanged = [&, tabNamed](const std::string& id, const std::string& title) {
            if (kite::Tab* tab = tabNamed(id)) tab->title = title;
        };
        events.loadingChanged = [&](const std::string&, bool loading) {
            // A smoke test closes once the first page has loaded (or shown its error page).
            if (loading) pageLoading = true;
            else if (pageLoading && !pageLoaded) {
                pageLoaded = true;
                if (smokeTest) {
                    closeAskedAt = GetTickCount64();
                    PostMessageW(window.Handle(), WM_CLOSE, 0, 0);
                }
            }
        };
        events.popupOpened = [&](const std::string& openerID, const std::string& id, const std::string& url) {
            std::optional<std::string> spaceID;
            if (auto location = state.Location(openerID); location && location->space) spaceID = state.spaces[*location->space].id;
            state.OpenTab(url, spaceID, true, kite::Now(), id);
            showSelectedTab();
        };
        std::wstring chromiumError;
        chromium = kite::Chromium::Start(instance, window.Handle(), supportDirectory / L"Chromium", std::move(events), chromiumError);
        if (!chromium) return Fail(quiet, L"Kite couldn't start Chromium: " + chromiumError, kWindowFailed);
        window.onWake = [&] { chromium->RunPending(); };
        window.mayClose = [&] { return chromium->MayCloseWindow(); };
        window.onFocus = [&] { chromium->Focus(); };
        window.onSize = [&] {
            draw();
            chromium->SetBounds(contentBounds());
        };
        showSelectedTab();
    }
#endif

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
        // The lost-GPU path, once: the renderer, swap chain and composition target are rebuilt
        // and draw again (a real device removal can't be caused from a test).
        compositor.reset();
        if (std::wstring problem = draw(); !problem.empty()) {
            return Fail(quiet, L"Kite couldn't rebuild its renderer: " + problem, kWindowFailed);
        }
        // With Chromium it waits for the first page instead, for at most 30 s.
        UINT smokeMs = 1000;
#ifdef KITE_HAS_CEF
        if (chromium) smokeMs = 30'000;
#endif
        SetTimer(window.Handle(), kSmokeTimer, smokeMs, [](HWND hwnd, UINT, UINT_PTR, DWORD) { PostMessageW(hwnd, WM_CLOSE, 0, 0); });
    }
    std::wstring captureError;
    if (capture) {
        // The window's own frame, read back as it's presented: at --capture-scale× when given
        // (the window is laid out at that scale on any monitor), else at the monitor's.
        kite::Pixels pixels;
        captureError = draw(&pixels);
        RECT client{};
        GetClientRect(window.Handle(), &client);
        if (captureError.empty() && (pixels.width != static_cast<UINT>(client.right) || pixels.height != static_cast<UINT>(client.bottom))) {
            captureError = L"the frame isn't the window's size";
        }
        if (captureError.empty()) captureError = kite::SavePng(pixels, *capture);
        PostMessageW(window.Handle(), WM_CLOSE, 0, 0);
    }

    // Messages, and the GPU's device-removed signal so a lost device is rebuilt even while
    // nothing is drawing (the composition would otherwise stay blank until the next resize).
    // If a rebuild failed (no adapter yet, mid driver update), it's retried every second for a
    // minute; after that only a resize retries, so a machine with no usable GPU doesn't wake
    // Kite every second for good.
    constexpr ULONGLONG kRetryForMs = 60'000;
    ULONGLONG retryUntil = 0;
    for (bool running = true; running;) {
        HANDLE removed = renderer && compositor ? renderer->DeviceRemovedEvent() : nullptr;
        DWORD timeout = INFINITE;
        if (!compositor) {
            const ULONGLONG now = GetTickCount64();
            if (!retryUntil) retryUntil = now + kRetryForMs;
            if (now < retryUntil) timeout = 1000;
        } else {
            retryUntil = 0;
        }
        const DWORD woke = MsgWaitForMultipleObjectsEx(removed ? 1 : 0, removed ? &removed : nullptr, timeout,
                                                       QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if ((removed && woke == WAIT_OBJECT_0) || woke == WAIT_TIMEOUT) {
            if (renderer && compositor) {
                const HRESULT reason = renderer->Device()->GetDeviceRemovedReason();
                OutputDebugStringW(kite::HResultMessage(L"Kite: the GPU device was removed", reason).append(L"\n").c_str());
            }
            compositor.reset();  // forces draw() to rebuild
            draw();
            continue;
        }
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                running = false;
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    if (capture && !captureError.empty()) return Fail(quiet, L"Capture failed: " + captureError, kCaptureFailed);
#ifdef KITE_HAS_CEF
    if (smokeTest && chromium && !pageLoaded) return Fail(quiet, L"the first page didn't finish loading within 30 s", kWindowFailed);
    // One WM_CLOSE must close the window (the browsers first); the 30 s timer's second one
    // would otherwise hide a close that hangs.
    if (smokeTest && chromium && GetTickCount64() - closeAskedAt > 5'000) {
        return Fail(quiet, L"the window took " + std::to_wstring((GetTickCount64() - closeAskedAt) / 1000) + L" s to close", kWindowFailed);
    }
#endif
    if (!maySave) {
        return Fail(quiet, L"Kite couldn't read your session (" + loadError + L"), so it left the file as it was and didn't save this run's tabs.",
                    kSaveFailed);
    }
    if (!saveError.empty()) return Fail(quiet, L"Couldn't save the session: " + Widen(saveError), kSaveFailed);
    return kOk;
}
