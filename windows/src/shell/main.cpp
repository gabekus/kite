// Kite for Windows. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second (with
//                            Chromium: until the selected tab's page has loaded, at most
//                            30 s, then one WM_CLOSE must close every browser in time),
//                            saves the session and exits 0 (CI). Errors go to the exit
//                            code, never a dialog.
//   Kite.exe --capture FILE.png [--window-size W,H] [--capture-scale N]
//                            opens the window at W×H points (client area), saves the frame
//                            it presents as a PNG and exits: the Helix UI gate
//                            (docs/helix.md). The window is laid out at N× (default: the
//                            monitor's scale), so a 2× capture lines up with a Retina Mac on
//                            any monitor, and drawn over the solid material fallback rather
//                            than whatever is behind it.
//                            Pair with KITE_SUPPORT_PATH and a session from windows/helix/states.
//   Kite.exe --capture FILE.png --command-bar TEXT
//                            the same with the command bar open (Ctrl+T) and TEXT typed in
//                            it, composed over the window's frame as DirectComposition shows it.
//   Kite.exe --backdrop-test draws the theme backdrop on the GPU and checks every pixel against
//                            core's CPU reference of the Mac's shader (shell/BackdropTest.h).
//                            Prints a report; exits 0 when it matches, 5 when it differs, 3
//                            when it couldn't run (no GPU device, no float target).

#include <windows.h>

#include <shellapi.h>

#include <algorithm>
#include <charconv>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "core/CommandBar.h"
#include "core/KeyBindings.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/SessionStore.h"
#include "core/SupportDirectory.h"
#include "core/ThemeBackdrop.h"
#include "core/TitleBar.h"
#include "shell/BackdropTest.h"
#include "shell/CaptionButtonsView.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/Capture.h"
#include "shell/CommandBarView.h"
#include "shell/Compositor.h"
#include "shell/Errors.h"
#include "shell/Favicons.h"
#include "shell/Keys.h"
#include "shell/MainWindow.h"
#include "shell/Renderer.h"
#include "shell/SidebarView.h"

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
// The auto-archive's pass, every 15 minutes as on the Mac (AppDelegate's archiveTimer).
constexpr UINT_PTR kArchiveTimer = 2;
constexpr UINT kArchiveIntervalMs = 15 * 60 * 1000;
// Posted by the favicon worker when icons arrive (Favicons.h).
constexpr UINT kFaviconsMessage = WM_APP + 4;

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

std::string Narrow(const std::wstring& text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(std::max(size, 0)), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr);
    return out;
}

// Puts `top` (premultiplied BGRA) over `base` with its top-left at `origin`, as
// DirectComposition puts the command bar's target over the window's.
void ComposeOver(kite::Pixels& base, const kite::Pixels& top, POINT origin) {
    for (UINT y = 0; y < top.height; ++y) {
        const LONG by = origin.y + static_cast<LONG>(y);
        if (by < 0 || by >= static_cast<LONG>(base.height)) continue;
        for (UINT x = 0; x < top.width; ++x) {
            const LONG bx = origin.x + static_cast<LONG>(x);
            if (bx < 0 || bx >= static_cast<LONG>(base.width)) continue;
            const uint8_t* src = &top.bgra[(static_cast<size_t>(y) * top.width + x) * 4];
            uint8_t* dst = &base.bgra[(static_cast<size_t>(by) * base.width + static_cast<size_t>(bx)) * 4];
            const unsigned keep = 255u - src[3];
            for (int c = 0; c < 4; ++c) dst[c] = static_cast<uint8_t>(src[c] + (dst[c] * keep + 127) / 255);
        }
    }
}

// The user's shortcut changes (keybindings.json, the Mac's KeyBindingsStore): none when the
// file isn't there, or can't be read (the defaults then, as the Mac does).
kite::KeyBindings LoadKeyBindings(const std::filesystem::path& file) {
    std::ifstream in(file, std::ios::binary);
    if (!in) return {};
    const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    if (auto bindings = kite::KeyBindings::FromText(text)) return *bindings;
    OutputDebugStringW(L"Kite: couldn't read keybindings.json, using the default shortcuts\n");
    return {};
}

// Puts text on the clipboard as Unicode text. False when the clipboard couldn't be had.
bool CopyText(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return false;
    bool copied = false;
    if (EmptyClipboard()) {
        const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
        if (HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
            if (void* data = GlobalLock(memory)) {
                std::memcpy(data, text.c_str(), bytes);
                GlobalUnlock(memory);
                copied = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
            }
            if (!copied) GlobalFree(memory);  // the clipboard owns it only once it's set
        }
    }
    CloseClipboard();
    return copied;
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
        if (a == L"--capture" || a == L"--window-size" || a == L"--capture-scale" || a == L"--command-bar") { ++i; continue; }
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
    const OptionValue commandBarOption = Option(args, L"--command-bar");
    if (commandBarOption.present && !commandBarOption.value) return Fail(quiet, L"--command-bar takes the text typed in it", kUsage);
    if (commandBarOption.present && !captureOption.present) return Fail(quiet, L"--command-bar only goes with --capture", kUsage);

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
    // Kite's shortcuts (core/KeyBindings.h): each command's default, after the user's
    // keybindings.json, read with the session before the window exists. Read once, as nothing
    // changes them yet (Settings → Shortcuts comes later).
    const kite::ShortcutMap shortcuts = kite::ShortcutTable(LoadKeyBindings(supportDirectory / L"keybindings.json"));
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
    // Unpinned tabs left unused past Archive Tabs After go to the archive as Kite starts, as
    // the Mac's applicationDidFinishLaunching does (and every 15 minutes, below). A capture
    // shows its session as given.
    if (!capture) {
        if (auto interval = state.ArchiveAfterSeconds()) state.ArchiveStaleTabs(*interval);
    }

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
#ifdef KITE_HAS_CEF
        // What the pages reported and Kite hasn't run yet (at logoff no WM_CLOSE comes first).
        if (chromium) chromium->RunPending();
#endif
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

    // The sidebar, over the backdrop: what the session lists, with favicons fetched off the UI
    // thread (none in a capture, which mustn't depend on the network).
    std::unique_ptr<kite::Favicons> favicons = capture ? nullptr : kite::Favicons::Create(window.Handle(), kFaviconsMessage);
    std::unique_ptr<kite::SidebarView> sidebar = kite::SidebarView::Create(window.Handle(), favicons.get(), gpuError);
    if (!sidebar) return Fail(quiet, L"Kite couldn't make the sidebar: " + gpuError, kWindowFailed);
    sidebar->UseCompositor(compositor.get());
    sidebar->Layout(static_cast<float>(kSidebarWidth), window.Dpi());
    sidebar->Update(state);

    // Windows' minimize, maximize and close buttons, top-right over the backdrop (the window
    // has no caption), and where dragging moves the window.
    std::unique_ptr<kite::CaptionButtonsView> caption = kite::CaptionButtonsView::Create(window.Handle(), gpuError);
    if (!caption) return Fail(quiet, L"Kite couldn't make the caption buttons: " + gpuError, kWindowFailed);
    caption->UseCompositor(compositor.get());
    caption->Layout(window.Dpi());
    caption->SetDark(dark);
    window.hitTest = [&](float x, float y) {
        RECT client{};
        GetClientRect(window.Handle(), &client);
        const float scale = static_cast<float>(window.Dpi()) / USER_DEFAULT_SCREEN_DPI;
        return kite::TitleBarAreaAt(static_cast<float>(client.right) / scale, static_cast<float>(kSidebarWidth), x, y, scale);
    };

    // The command bar (Ctrl+T), over everything in the window. What it does with a row, and
    // how a page shows, depend on Chromium, so they're filled in with it below.
    std::unique_ptr<kite::CommandBarView> commandBar;
    // The session changed under the window: the sidebar and an open bar show it.
    auto stateChanged = [&] {
        sidebar->Update(state);
        caption->SetDark(!kite::PrefersDarkForeground(state.SelectedSpace().theme));
        if (commandBar) commandBar->Refresh();
    };
    std::function<void(const std::string& tabID, const std::string& url)> loadInTab = [](const std::string&, const std::string&) {};
    std::function<void()> showPage = [] {};
    // A tab left the session (closed, unloaded or archived): its page goes (Chromium, below).
    std::function<void(const std::string& tabID)> pageGone = [](const std::string&) {};
    std::function<void(bool blocked)> blockPages = [](bool) {};
    std::function<bool()> keysForBar = [] { return false; };
    kite::CommandBarView::Callbacks barCallbacks;
    barCallbacks.suggestions = [&](std::string_view text, kite::CommandBarMode mode) {
        return kite::CommandBarSuggestions(text, state, mode);
    };
    barCallbacks.commit = [&](const kite::CommandSuggestion& row, kite::CommandBarMode mode) {
        // The Mac's BrowserWindowController.commit and open(_:mode:).
        switch (row.kind) {
        case kite::CommandSuggestion::Kind::Open:
        case kite::CommandSuggestion::Kind::Search:
            if (mode == kite::CommandBarMode::EditCurrent && state.SelectedTab()) {
                const std::string id = state.SelectedTab()->id;
                if (auto at = state.Location(id)) {
                    if (kite::Tab* tab = state.TabAt(*at)) tab->url = row.url;
                }
                loadInTab(id, row.url);
            } else {
                state.OpenTab(row.url);
                showPage();
            }
            break;
        case kite::CommandSuggestion::Kind::SwitchTab:
            if (state.Location(row.tabID)) {
                state.Select(row.tabID);
                showPage();
            }
            break;
        }
        stateChanged();
    };
    barCallbacks.opened = [&] {
        blockPages(true);
        sidebar->ClearHover();  // the bar takes the pointer while it's open
    };
    barCallbacks.closed = [&] { blockPages(false); };
    barCallbacks.dpi = [&] { return window.Dpi(); };
    commandBar = kite::CommandBarView::Create(window.Handle(), std::move(barCallbacks), gpuError);
    if (commandBar) {
        commandBar->UseCompositor(compositor.get());
    } else {
        if (commandBarOption.present) return Fail(quiet, L"Kite couldn't make the command bar: " + gpuError, kWindowFailed);
        OutputDebugStringW((L"Kite: no command bar: " + gpuError + L"\n").c_str());
    }
    auto barLook = [&] {
        const kite::Theme& selected = state.SelectedSpace().theme;
        return kite::CommandBarView::Look{!kite::PrefersDarkForeground(selected), kite::Accent(selected)};
    };
    // The Mac's newTab and openLocation: Ctrl+T, and (for the sidebar's address, W4) the
    // current tab's address.
    auto openCommandBar = [&](kite::CommandBarMode mode) {
        if (!commandBar) return blockPages(false);
        const kite::Tab* tab = state.SelectedTab();
        if (!tab) mode = kite::CommandBarMode::NewTab;
        commandBar->Show(mode, mode == kite::CommandBarMode::EditCurrent ? tab->url.value_or("") : "", barLook());
    };
    // The views let go of the compositor's device first, then the compositor goes (so the
    // next draw rebuilds it).
    auto dropCompositor = [&] {
        sidebar->UseCompositor(nullptr);
        caption->UseCompositor(nullptr);
        if (commandBar) commandBar->UseCompositor(nullptr);
        compositor.reset();
    };
    // After the GPU is reset or removed, both are rebuilt on whatever adapter is there now.
    auto rebuild = [&]() -> std::wstring {
        std::wstring problem;
        dropCompositor();  // first: a window holds one composition target at a time
        renderer = kite::Renderer::Create(problem);
        if (renderer) compositor = kite::Compositor::Create(window.Handle(), *renderer, problem);
        if (compositor) {
            sidebar->UseCompositor(compositor.get());
            caption->UseCompositor(compositor.get());
            if (commandBar) commandBar->UseCompositor(compositor.get());
        }
        return problem;
    };
    auto draw = [&](kite::Pixels* readBack = nullptr) -> std::wstring {
        RECT client{};
        GetClientRect(window.Handle(), &client);
        const UINT width = static_cast<UINT>(client.right), height = static_cast<UINT>(client.bottom);
        std::wstring problem;
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (!compositor || compositor->DeviceLost() || sidebar->DeviceLost() || caption->DeviceLost()) {
                if (problem = rebuild(); !problem.empty()) break;
            }
            problem = compositor->Draw(width, height, kite::MakeThemeUniforms(theme, static_cast<float>(width), static_cast<float>(height)),
                                       base, readBack);
            // The sidebar with it, shown together at the commit.
            if (problem.empty()) problem = sidebar->Draw();
            if (problem.empty()) problem = caption->Draw();
            if (problem.empty()) compositor->Commit();
            if (!compositor->DeviceLost() && !sidebar->DeviceLost() && !caption->DeviceLost()) break;
        }
        if (!problem.empty()) OutputDebugStringW((L"Kite: drawing failed: " + problem + L"\n").c_str());
        return problem;
    };
    window.onSize = [&] {
        sidebar->Layout(static_cast<float>(kSidebarWidth), window.Dpi());
        caption->Layout(window.Dpi());
        draw();
        if (commandBar) commandBar->Layout();
    };
    // A hover's redraw found the GPU gone: rebuild and draw everything.
    caption->onDeviceLost = [&] { draw(); };
    // The sidebar's clicks (the Mac's row taps and the header's buttons). With Chromium, a
    // selected tab's page shows too (below).
    kite::SidebarView::Actions sidebarActions;
    sidebarActions.selectTab = [&](const std::string& id) {
        state.Select(id);
        stateChanged();
    };
    sidebarActions.setFolderExpanded = [&](const std::string& id, bool expanded) {
        state.SetFolderExpanded(id, expanded);
        stateChanged();
    };
    sidebarActions.togglePinnedSection = [&](const std::string& spaceID) {
        kite::TogglePinnedSection(state, spaceID);
        stateChanged();
    };
    sidebarActions.newTab = [&] { openCommandBar(kite::CommandBarMode::NewTab); };
    // The Mac's field action: the bar edits the page's address, or opens a new tab with none.
    sidebarActions.editAddress = [&] { openCommandBar(kite::CommandBarMode::EditCurrent); };
    // A tab's close button and Ctrl+W (the Mac's close(tab:)). With Chromium, its page goes too.
    // The id by value: Ctrl+W's is the tab's own, which closing erases.
    auto closeTab = [&](std::string id) {
        if (state.Close(id) == kite::CloseOutcome::NotFound) return;
        // The next page shows first and the closed one hides in the same pass, so the card
        // is never empty in between; then the closed page goes.
        showPage();
        pageGone(id);
        stateChanged();
    };
    sidebarActions.closeTab = [&](const std::string& id) { closeTab(id); };
    // Ctrl+W (Archive Tab): the open command bar closes first, else the selected tab.
    auto archiveTab = [&] {
        if (commandBar && commandBar->IsOpen()) commandBar->Hide();
        else if (const kite::Tab* tab = state.SelectedTab()) closeTab(tab->id);
        else MessageBeep(MB_OK);
    };
    // Ctrl+Shift+T (Restore Last Closed Tab).
    auto reopenClosedTab = [&] {
        if (state.ReopenLastClosed()) {
            showPage();
            stateChanged();
        }
    };
    sidebar->SetActions(sidebarActions);
    // A page's own commands (back, reload, developer tools…), with Chromium (below). False when
    // there's no page to do it to.
    std::function<bool(const std::string& command)> pageCommand = [](const std::string&) { return false; };
    // The selected tab's page shows, and the sidebar with it, after the selection moved.
    auto selectionMoved = [&] {
        showPage();
        stateChanged();
    };
    // What each shortcut's command does: the Mac's menu items of the same ids (MainMenu.swift).
    std::map<std::string, std::function<void()>, std::less<>> commands{
        {"newTab", [&] { openCommandBar(kite::CommandBarMode::NewTab); }},
        {"openLocation", [&] { openCommandBar(kite::CommandBarMode::EditCurrent); }},
        {"archiveTab", [&] { archiveTab(); }},
        {"reopenClosedTab", [&] { reopenClosedTab(); }},
        // One window, so closing it quits, as the Mac's last window does with Kite set so.
        {"closeWindow", [&] { PostMessageW(window.Handle(), WM_CLOSE, 0, 0); }},
        {"quitKite", [&] { PostMessageW(window.Handle(), WM_CLOSE, 0, 0); }},
        {"minimize", [&] { ShowWindow(window.Handle(), SW_MINIMIZE); }},
        // The Mac's copyURL (its "Copied Current URL" toast comes with toasts).
        {"copyCurrentURL",
         [&] {
             const kite::Tab* tab = state.SelectedTab();
             if (!tab || !tab->url || !CopyText(window.Handle(), Widen(*tab->url))) MessageBeep(MB_OK);
         }},
        {"collapsePinnedSection",
         [&] {
             kite::TogglePinnedSection(state, state.SelectedSpace().id);
             stateChanged();
         }},
        // The Mac's viewSource: the page's source in a new tab.
        {"viewSource",
         [&] {
             const kite::Tab* tab = state.SelectedTab();
             if (!tab || !tab->url || tab->url->starts_with("kite:") || tab->url->starts_with("view-source:")) {
                 MessageBeep(MB_OK);
                 return;
             }
             state.OpenTab("view-source:" + *tab->url);
             selectionMoved();
         }},
        {"nextTab",
         [&] {
             state.SelectAdjacentTab(1);
             selectionMoved();
         }},
        {"previousTab",
         [&] {
             state.SelectAdjacentTab(-1);
             selectionMoved();
         }},
        // As the Mac: with no page, Back, Forward, Refresh and Stop do nothing; Print and
        // Developer Tools beep.
        {"goBack", [&] { pageCommand("goBack"); }},
        {"goForward", [&] { pageCommand("goForward"); }},
        {"reloadPage", [&] { pageCommand("reloadPage"); }},
        {"forceReloadPage", [&] { pageCommand("forceReloadPage"); }},
        {"stopLoading", [&] { pageCommand("stopLoading"); }},
        {"printPage", [&] { if (!pageCommand("printPage")) MessageBeep(MB_OK); }},
        {"developerTools", [&] { if (!pageCommand("developerTools")) MessageBeep(MB_OK); }},
    };
    for (int n = 1; n <= 9; ++n) {
        commands[n == 9 ? "lastTab" : "tab" + std::to_string(n)] = [&, n] {
            state.SelectTabNumber(n);
            selectionMoved();
        };
    }
    // Every command the table can name does something: a test run fails on one that doesn't.
    for (const kite::ShortcutCommand& command : kite::ShortcutCommands()) {
        if (!commands.contains(command.id) && (smokeTest || capture)) {
            return Fail(quiet, L"the shortcut command " + Widen(command.id) + L" does nothing", kWindowFailed);
        }
    }
    auto runCommand = [&](const std::string& command) {
        if (auto it = commands.find(command); it != commands.end()) it->second();
    };
    // A shortcut ran from a key: the character Windows makes of that key isn't typed.
    bool dropCharacter = false;
    // The window's own messages, before its default handling: the caption buttons, shortcuts,
    // the command bar, the sidebar.
    window.filter = [&](UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
        // The caption buttons' presses, whatever else is open.
        if (caption->HandleMessage(message, wParam, lParam, result)) return true;
        // A key typed straight after Ctrl+T in a page can come before Chromium's note that
        // Ctrl+T was pressed: it opens the bar itself, and the note then finds it open.
        if ((message == WM_KEYDOWN || message == WM_CHAR) && commandBar && !commandBar->IsOpen() && keysForBar()) {
            openCommandBar(kite::CommandBarMode::NewTab);
        }
        if ((message == WM_CHAR || message == WM_SYSCHAR) && dropCharacter) {
            dropCharacter = false;
            result = 0;
            return true;
        }
        // A key that made no character: its key-up ends the wait for one.
        if (message == WM_KEYUP || message == WM_SYSKEYUP) dropCharacter = false;
        // Kite's shortcuts, wherever the keyboard is in Kite's own window, the bar's field
        // included (as the Mac's menus come before its field editor), but for keys the field
        // edits with (Alt+Left). Alt's come as WM_SYSKEYDOWN. A page's come through Chromium.
        if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
            dropCharacter = false;
            const auto pressed = kite::ShortcutOfKey(static_cast<UINT>(wParam), GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_MENU) < 0,
                                                     GetKeyState(VK_SHIFT) < 0);
            const kite::ShortcutTarget* target = pressed ? kite::FindShortcut(shortcuts, *pressed) : nullptr;
            if (target && !(commandBar && commandBar->IsOpen() && kite::EditsText(*pressed))) {
                // The character TranslateMessage made of it goes too (Alt+K's WM_SYSCHAR would beep).
                dropCharacter = true;
                runCommand(target->command->id);  // a held key repeats it, as the Mac's menus do
                result = 0;
                return true;
            }
        }
        if (commandBar && commandBar->HandleMessage(message, wParam, lParam, result)) {
            if (message == WM_LBUTTONDOWN) sidebar->ForgetActivation();
            return true;
        }
        if (sidebar->HandleMouse(message, wParam, lParam)) return true;
        // The caption buttons' appearance changes with the sidebar's, at its commit.
        if (message == kite::SidebarView::kRedrawMessage) {
            if (std::wstring problem = caption->Draw(); !problem.empty()) {
                OutputDebugStringW((L"Kite: the caption buttons couldn't draw: " + problem + L"\n").c_str());
            }
        }
        if (sidebar->HandleMessage(message)) {
            // Its own redraw found the GPU gone: the window's draw rebuilds everything.
            if (sidebar->DeviceLost() || caption->DeviceLost()) draw();
            return true;
        }
        if (message == WM_TIMER && wParam == kArchiveTimer) {
            if (auto interval = state.ArchiveAfterSeconds()) {
                for (const kite::Tab& tab : state.ArchiveStaleTabs(*interval)) pageGone(tab.id);
                stateChanged();
            }
            return true;
        }
        if (message == kFaviconsMessage) {
            if (favicons && favicons->TakeResults()) sidebar->Invalidate();
            return true;
        }
        return false;
    };
    // On an early return the compositor and the bar go before the window: stop drawing first.
    struct StopDrawing {
        kite::MainWindow& window;
        ~StopDrawing() {
            window.onSize = nullptr;
            window.onFocus = nullptr;
            window.filter = nullptr;
        }
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

    if (smokeTest) {
        // Checked before Chromium starts, so a failure here leaves no browser half-created.
        // The manifest took effect: without it the window would be DPI-unaware and text in the
        // ANSI code page, which a 100% CI display can't tell apart by size alone.
        if (!AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(window.Handle()), DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
            return Fail(quiet, L"the window isn't per-monitor DPI aware (v2): Kite.manifest wasn't embedded", kWindowFailed);
        }
        if (GetACP() != CP_UTF8) return Fail(quiet, L"the process code page isn't UTF-8: Kite.manifest wasn't embedded", kWindowFailed);
    }

#ifdef KITE_HAS_CEF
    // The selected tab's page on the content card. A capture leaves Chromium out: a child
    // window isn't in the composition tree it reads back (until W10 makes pages textures).
    bool pageLoaded = false, pageLoading = false;
    ULONGLONG closeAskedAt = 0;  // when the smoke test asked the window to close
    bool firstPageMade = false;
    // Each open popup's tab and the tab that opened it (the Mac's PagePool.popupOpeners).
    std::map<std::string, std::string> popupOpeners;
    auto contentBounds = [&] {
        RECT client{};
        GetClientRect(window.Handle(), &client);
        const int dpi = static_cast<int>(window.Dpi());
        auto px = [dpi](int points) { return MulDiv(points, dpi, USER_DEFAULT_SCREEN_DPI); };
        // Its top under the caption buttons.
        RECT card{px(kSidebarWidth), px(static_cast<int>(kite::title_bar::kContentTop)), client.right - px(kContentInset),
                  client.bottom - px(kContentInset)};
        card.right = std::max(card.right, card.left + 1);
        card.bottom = std::max(card.bottom, card.top + 1);
        return card;
    };
    auto showSelectedTab = [&] {
        const kite::Tab* tab = state.SelectedTab();
        // No tab: the card shows through (the Mac's "Press ⌘T to open a tab" comes later).
        if (!tab) return chromium->ShowNothing();
        // As the Mac's makePage: the tab's address, or a blank page for none or for one of
        // Kite's own pages (kite://, which come later).
        std::string url = tab->url.value_or("");
        if (url.starts_with("kite:")) url.clear();
        chromium->Show(tab->id, state.SelectedProfileDirectory(), url, contentBounds());
    };
    // The first page is made once the window is on screen and not minimized. Made while the
    // window was still hidden, it came up hidden for good (an empty card until the first
    // click), and the first ShowWindow sends WM_SIZE before the window is visible; made
    // while minimized, it would lay out at 1×1.
    auto showFirstPage = [&] {
        if (firstPageMade || !chromium || !IsWindowVisible(window.Handle()) || IsIconic(window.Handle())) return;
        firstPageMade = true;
        showSelectedTab();
    };
    if (!capture) {
        showPage = showSelectedTab;
        pageGone = [&](const std::string& id) {
            chromium->Close(id);
            // A closed page can't be anyone's opener or popup again.
            std::erase_if(popupOpeners, [&](const auto& entry) { return entry.first == id || entry.second == id; });
        };
        // A tab clicked in the sidebar shows its page.
        sidebarActions.selectTab = [&](const std::string& id) {
            state.Select(id);
            showSelectedTab();
            stateChanged();
        };
        sidebar->SetActions(sidebarActions);
        loadInTab = [&](const std::string& id, const std::string& url) {
            // kite:// pages are drawn by the window, never loaded (the Mac's InternalPage).
            if (url.starts_with("kite:")) return;
            // A tab whose page closed itself (an unloaded pinned tab) gets a new one.
            if (!chromium->Navigate(id, url)) showSelectedTab();
        };
        keysForBar = [&] { return chromium->KeysComeToKite(); };
        pageCommand = [&](const std::string& command) {
            using Action = kite::Chromium::PageAction;
            static const std::map<std::string, Action, std::less<>> actions{
                {"goBack", Action::Back},     {"goForward", Action::Forward},         {"reloadPage", Action::Reload},
                {"forceReloadPage", Action::ReloadIgnoringCache},                     {"stopLoading", Action::Stop},
                {"developerTools", Action::DevTools},                                 {"printPage", Action::Print},
            };
            auto it = actions.find(command);
            return it != actions.end() && chromium->Act(it->second);
        };
        blockPages = [&](bool blocked) {
            chromium->BlockInput(blocked);
            if (!blocked) chromium->Focus();
        };
        auto tabNamed = [&](const std::string& id) -> kite::Tab* {
            auto location = state.Location(id);
            return location ? state.TabAt(*location) : nullptr;
        };
        kite::PageEvents events;
        events.addressChanged = [&, tabNamed](const std::string& id, const std::string& url) {
            if (kite::Tab* tab = tabNamed(id); tab && !url.empty()) tab->url = url;
            stateChanged();
        };
        events.titleChanged = [&, tabNamed](const std::string& id, const std::string& title) {
            // An empty title keeps the last one, as the Mac's BrowserStore does.
            if (kite::Tab* tab = tabNamed(id); tab && !title.empty()) tab->title = title;
            stateChanged();
        };
        events.faviconChanged = [&, tabNamed](const std::string& id, const std::string& url) {
            kite::Tab* tab = tabNamed(id);
            const std::optional<std::string> icon = url.empty() ? std::nullopt : std::optional<std::string>(url);
            if (!tab || tab->faviconURL == icon) return;
            tab->faviconURL = icon;
            stateChanged();
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
            // In the current space, as the Mac's openTab(id:url:). window.open('') has no
            // address yet, which the session keeps as none (the Mac's nil).
            state.OpenTab(url.empty() ? std::nullopt : std::optional<std::string>(url), std::nullopt, true, kite::Now(), id);
            popupOpeners[id] = openerID;
            showSelectedTab();
            stateChanged();
        };
        events.openInNewTab = [&](const std::string&, const std::string& url, bool foreground) {
            // In the current space, as the Mac's openTab(url:select:).
            state.OpenTab(url, std::nullopt, foreground);
            if (foreground) showSelectedTab();
            stateChanged();
        };
        events.pageClosed = [&](const std::string& id) {
            // A page that closed itself (window.close() after a sign-in): its tab closes, and a
            // popup on screen hands it back to its opener, as the Mac's PagePool does.
            const auto opener = popupOpeners.extract(id);
            state.PageClosedItself(id, opener ? std::optional<std::string>(opener.mapped()) : std::nullopt);
            std::erase_if(popupOpeners, [&](const auto& entry) { return entry.second == id; });
            showSelectedTab();
            stateChanged();
        };
        // A popup and its opener keep their pages while both tabs exist; a page closed for the
        // limit can't be anyone's opener or popup again (the Mac's PagePool.discard).
        events.keepAlive = [&](const std::string& id) { return kite::IsLinkedToPopup(popupOpeners, state, id); };
        events.pageDiscarded = [&](const std::string& id) {
            std::erase_if(popupOpeners, [&](const auto& entry) { return entry.first == id || entry.second == id; });
        };
        events.shortcuts = shortcuts;
        events.command = runCommand;
        events.newTab = [&] {
            // Not when the bar has already opened for the keys typed after Ctrl+T and been
            // closed again (closing it gives the keys back to the pages).
            if (chromium->KeysComeToKite()) openCommandBar(kite::CommandBarMode::NewTab);
        };
        events.keyForwarded = [&](bool character, unsigned code, bool ctrl, bool shift) {
            if (!commandBar) return;
            if (character) commandBar->ForwardCharacter(static_cast<wchar_t>(code));
            else commandBar->ForwardKey(code, ctrl, shift);
        };
        events.relaunched = [&] {
            // Kite was launched again: this one comes forward instead.
            if (IsIconic(window.Handle())) ShowWindow(window.Handle(), SW_RESTORE);
            SetForegroundWindow(window.Handle());
        };
        std::wstring chromiumError;
        switch (kite::Chromium::Start(instance, window.Handle(), supportDirectory / L"Chromium", std::move(events), chromium, chromiumError)) {
        case kite::Chromium::StartResult::Started: break;
        // Another Kite has this profile and was told to come forward; this one leaves quietly,
        // before its window shows or it saves anything.
        // A test run that found one tested nothing, so it fails.
        case kite::Chromium::StartResult::AlreadyRunning:
            return quiet ? Fail(quiet, L"another Kite has this profile open", kWindowFailed) : kOk;
        case kite::Chromium::StartResult::Failed: return Fail(quiet, L"Kite couldn't start Chromium: " + chromiumError, kWindowFailed);
        }
        window.onWake = [&] { chromium->RunPending(); };
        window.onMinimize = [&] { chromium->Minimized(); };
        window.onMove = [&] { chromium->WindowMoved(); };
        window.mayClose = [&] { return chromium->MayCloseWindow(); };
        window.onFocus = [&] {
            // The open bar keeps the keyboard in Kite's window.
            if (!commandBar || !commandBar->IsOpen()) chromium->Focus();
        };
        window.onSize = [&] {
            // The page first, so CEF's thread moves it while Kite draws.
            chromium->SetBounds(contentBounds());
            sidebar->Layout(static_cast<float>(kSidebarWidth), window.Dpi());
            caption->Layout(window.Dpi());
            draw();
            if (commandBar) commandBar->Layout();
            chromium->WindowMoved();
            showFirstPage();  // restored after a minimized launch
        };
    }
#endif

    // Quiet runs open behind other windows without focus, and ignore a launcher's "start maximized".
    if (quiet) window.ShowBehindOtherWindows();
    else window.Show(showCommand);
#ifdef KITE_HAS_CEF
    showFirstPage();
#endif
    if (capture && !window.HasClientSize(size->first, size->second)) {
        // A capture is compared pixel for pixel with the Mac's, so a window Windows resized
        // (maximized by the launcher, clamped to 32767 px) would compare the wrong thing.
        return Fail(quiet, L"the window didn't get the size --capture needs", kCaptureFailed);
    }

    if (smokeTest) {
        // The command bar opens over the window, draws with text in it, and closes.
        if (!commandBar) return Fail(quiet, L"Kite couldn't make the command bar", kWindowFailed);
        commandBar->Show(kite::CommandBarMode::NewTab, "", barLook());
        commandBar->Type("kite smoke");
        if (std::wstring problem = commandBar->Draw(); !problem.empty()) {
            return Fail(quiet, L"the command bar couldn't draw: " + problem, kWindowFailed);
        }
        commandBar->Hide();
        // The sidebar draws what the session lists (something, not a blank surface).
        kite::Pixels chrome;
        if (std::wstring problem = sidebar->Draw(&chrome); !problem.empty()) {
            return Fail(quiet, L"the sidebar couldn't draw: " + problem, kWindowFailed);
        }
        bool inked = false;
        for (size_t i = 3; i < chrome.bgra.size() && !inked; i += 4) inked = chrome.bgra[i] != 0;
        if (!inked) return Fail(quiet, L"the sidebar drew nothing", kWindowFailed);
        // And the caption buttons their glyphs.
        kite::Pixels buttons;
        if (std::wstring problem = caption->Draw(&buttons); !problem.empty()) {
            return Fail(quiet, L"the caption buttons couldn't draw: " + problem, kWindowFailed);
        }
        inked = false;
        for (size_t i = 3; i < buttons.bgra.size() && !inked; i += 4) inked = buttons.bgra[i] != 0;
        if (!inked) return Fail(quiet, L"the caption buttons drew nothing", kWindowFailed);
        // The lost-GPU path, once: the renderer, swap chain and composition target are rebuilt
        // and draw again (a real device removal can't be caused from a test).
        dropCompositor();
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
    // The auto-archive's later passes (the launch's ran above). A capture never archives.
    if (!capture) SetTimer(window.Handle(), kArchiveTimer, kArchiveIntervalMs, nullptr);
    std::wstring captureError;
    if (capture) {
        // The window's own frame, read back as it's presented: at --capture-scale× when given
        // (the window is laid out at that scale on any monitor), else at the monitor's.
        kite::Pixels pixels;
        captureError = draw(&pixels);
        if (captureError.empty()) {
            // The sidebar's surface over the backdrop, at the window's top-left.
            kite::Pixels chrome;
            captureError = sidebar->Draw(&chrome);
            if (captureError.empty()) ComposeOver(pixels, chrome, POINT{0, 0});
        }
        if (captureError.empty()) {
            kite::Pixels buttons;
            POINT origin{};
            captureError = caption->Draw(&buttons, &origin);
            if (captureError.empty()) ComposeOver(pixels, buttons, origin);
        }
        if (captureError.empty() && commandBarOption.present) {
            // The bar as Ctrl+T opens it, with the text typed in.
            commandBar->Show(kite::CommandBarMode::NewTab, "", barLook());
            commandBar->Type(Narrow(*commandBarOption.value));
            kite::Pixels bar;
            POINT origin{};
            captureError = commandBar->Draw(&bar, &origin);
            if (captureError.empty()) ComposeOver(pixels, bar, origin);
        }
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
            dropCompositor();  // forces draw() to rebuild
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
    // Every browser closed within the window's 5 s deadline and Chromium's shutdown wait,
    // rather than Chromium going down under one.
    const bool chromiumClosedCleanly = !chromium || chromium->Shutdown();
    if (smokeTest && !chromiumClosedCleanly) return Fail(quiet, L"a browser didn't close in time; Chromium shut down under it", kWindowFailed);
    if (smokeTest && chromium && !pageLoaded) return Fail(quiet, L"the first page didn't finish loading within 30 s", kWindowFailed);
    if (smokeTest && chromium && !chromium->PagesCanBeHidden()) {
        return Fail(quiet, L"a page had no Chromium widget window to hide: background tabs would keep drawing", kWindowFailed);
    }
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
