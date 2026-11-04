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
//   Kite.exe --capture FILE.png --space-tip N
//                            the same with space N's tip (1-based) over its cell, at rest (the
//                            cell's hover backing isn't drawn: no pointer is on it).
//   Kite.exe --frame-log FILE
//                            a normal window on a test profile that writes each animation
//                            frame (a space switch's slide and crossfade) to FILE as it
//                            closes: one JSON object a line, `t`, `offset` and `theme`.
//   Kite.exe --perf-log FILE [--perf-control] [--chromium-switches "--a --b=c"]
//                            a normal window on a test profile, for windows/tools/perf/kiteperf:
//                            FILE gets JSON lines of QPC marks, present/commit/surface-draw
//                            counters, long dispatches, input→present and frame timings
//                            (shell/PerfLog.h); --perf-control takes requests by WM_COPYDATA
//                            (BrowserWindowController::QueuePerfRequest); --chromium-switches go
//                            on Chromium's command line, from an allow-list (shell/PerfProtocol.h).
//                            Never on the default profile. Opens behind other windows.
//   Kite.exe --backdrop-test draws the theme backdrop on the GPU and checks every pixel against
//                            core's CPU reference of the Mac's shader (shell/BackdropTest.h).
//                            Prints a report; exits 0 when it matches, 5 when it differs, 3
//                            when it couldn't run (no GPU device, no float target).

#include <windows.h>

#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <charconv>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "core/KeyBindings.h"
#include "core/SessionStore.h"
#include "core/SupportDirectory.h"
#include "shell/BackdropTest.h"
#include "shell/BrowserWindowController.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/Capture.h"
#include "shell/MainWindow.h"
#include "shell/PerfLog.h"
#include "shell/Text.h"

namespace {

using kite::Narrow;
using kite::Widen;

enum ExitCode : int { kOk = 0, kUsage = 1, kBadSupportDirectory = 2, kWindowFailed = 3, kSaveFailed = 4, kCaptureFailed = 5 };

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
    // normal launch on the real profile. Windows' switch prefix "/" counts as a flag too, and an
    // option's value never looks like one: it would be a flag swallowed as the value.
    // Chromium never reads this line (Chromium::Start: command_line_args_disabled).
    const auto looksLikeFlag = [](const std::wstring& a) { return a.starts_with(L"-") || a.starts_with(L"/"); };
    for (size_t i = 0; i < args.size(); ++i) {
        const std::wstring& a = args[i];
        if (a == L"--smoke-test" || a == L"--backdrop-test" || a == L"--perf-control") continue;
        if (a == L"--capture" || a == L"--window-size" || a == L"--capture-scale" || a == L"--command-bar" || a == L"--frame-log" ||
            a == L"--space-tip" || a == L"--perf-log" || a == L"--chromium-switches") {
            // --chromium-switches' value is switches ("--a --b"), each checked against its
            // allow-list below.
            if (i + 1 < args.size() && looksLikeFlag(args[i + 1]) && a != L"--chromium-switches") {
                return Fail(true, a + L" takes a value, not " + args[i + 1], kUsage);
            }
            ++i;
            continue;
        }
        if (looksLikeFlag(a)) return Fail(true, L"unknown option " + a, kUsage);
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
    const OptionValue perfLogOption = Option(args, L"--perf-log");
    const bool perfControl = HasFlag(args, L"--perf-control");
    const OptionValue switchesOption = Option(args, L"--chromium-switches");
    // A measured run never shows a dialog or takes the focus (kiteperf runs beside other work).
    const bool quiet = smokeTest || captureOption.present || perfLogOption.present || perfControl || switchesOption.present;
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
    const OptionValue tipOption = Option(args, L"--space-tip");
    std::optional<size_t> tipIndex;
    if (tipOption.present) {
        if (!tipOption.value || tipOption.value->empty() || tipOption.value->size() > 3 ||
            !std::all_of(tipOption.value->begin(), tipOption.value->end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; }) ||
            std::stoi(*tipOption.value) < 1) {
            return Fail(quiet, L"--space-tip takes a space's place, from 1", kUsage);
        }
        tipIndex = static_cast<size_t>(std::stoi(*tipOption.value) - 1);
    }
    if (tipOption.present && !captureOption.present) return Fail(quiet, L"--space-tip only goes with --capture", kUsage);
    const OptionValue frameLogOption = Option(args, L"--frame-log");
    if (frameLogOption.present && !frameLogOption.value) return Fail(quiet, L"--frame-log takes a file", kUsage);
    if (perfLogOption.present && !perfLogOption.value) return Fail(quiet, L"--perf-log takes a file", kUsage);
    // "--name" or "--name=value", split on spaces.
    std::vector<std::string> chromiumSwitches;
    if (switchesOption.present) {
        if (!switchesOption.value) return Fail(quiet, L"--chromium-switches takes Chromium's switches", kUsage);
        const std::wstring& text = *switchesOption.value;
        for (size_t start = 0; start < text.size();) {
            if (text[start] == L' ') {
                ++start;
                continue;
            }
            const size_t end = std::min(text.find(L' ', start), text.size());
            const std::wstring_view token(text.data() + start, end - start);
            const std::string entry = token.starts_with(L"--") ? Narrow(std::wstring(token.substr(2))) : std::string();
            const size_t equals = entry.find('=');
            const std::string_view name = std::string_view(entry).substr(0, equals);
            const std::string_view value = equals == std::string::npos ? std::string_view() : std::string_view(entry).substr(equals + 1);
            // An allow-list (shell/PerfProtocol.h): nothing that weakens the sandbox or web
            // security, opens a debugging port, or changes a path or a launched process.
            if (name.empty() || !kite::perf::AllowedChromiumSwitch(name, value)) {
                return Fail(quiet, L"--chromium-switches doesn't allow " + std::wstring(token), kUsage);
            }
            chromiumSwitches.push_back(entry);
            start = end;
        }
    }

    const auto supportOverride = kite::EnvironmentPath("KITE_SUPPORT_PATH");
    // Test flags only run on a test profile, like the Mac's KITE_WINDOW_SIZE: a smoke test or
    // capture loads and re-saves the session, which must never be the user's own.
    if ((smokeTest || captureOption.present || sizeOption.present || scaleOption.present || frameLogOption.present ||
         perfLogOption.present || perfControl || switchesOption.present) &&
        !supportOverride) {
        return Fail(quiet,
                    L"--smoke-test, --capture, --window-size, --capture-scale, --frame-log, --perf-log, --perf-control and "
                    L"--chromium-switches need KITE_SUPPORT_PATH set to a test profile",
                    kUsage);
    }
    auto resolved = kite::ResolveSupportDirectory(supportOverride, kite::EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<kite::SupportDirectoryError>(&resolved)) {
        return Fail(quiet, Widen(error->message), kBadSupportDirectory);
    }
    const std::filesystem::path supportDirectory = std::get<std::filesystem::path>(resolved);
    const bool perfHooks = perfLogOption.present || perfControl || switchesOption.present;
    if (perfHooks) {
        // Only a profile that says it's a test profile (kiteperf and CI make the marker), and
        // never the real one, however KITE_SUPPORT_PATH spells it.
        std::error_code markerError;
        if (!std::filesystem::is_regular_file(supportDirectory / kite::perf::kTestProfileMarker, markerError)) {
            return Fail(quiet,
                        L"--perf-log, --perf-control and --chromium-switches need a test profile: KITE_SUPPORT_PATH has no " +
                            std::wstring(kite::perf::kTestProfileMarker) + L" file",
                        kUsage);
        }
        const auto normal = [](const std::filesystem::path& p) -> std::optional<std::wstring> {
            std::error_code ec;
            const std::filesystem::path absolute = std::filesystem::absolute(p, ec);
            if (ec) return std::nullopt;
            std::wstring text = std::filesystem::weakly_canonical(absolute, ec).wstring();
            if (ec || text.empty()) return std::nullopt;
            while (text.size() > 3 && (text.back() == L'\\' || text.back() == L'/')) text.pop_back();
            CharLowerBuffW(text.data(), static_cast<DWORD>(text.size()));
            return text;
        };
        const auto test = normal(supportDirectory);
        if (!test) return Fail(quiet, L"--perf-log, --perf-control and --chromium-switches: KITE_SUPPORT_PATH couldn't be resolved", kUsage);
        // The default profile, from the environment and from the known folder (LOCALAPPDATA can be
        // set to anything).
        std::vector<std::filesystem::path> defaults;
        if (auto fromEnvironment = kite::ResolveSupportDirectory(std::nullopt, kite::EnvironmentPath("LOCALAPPDATA"));
            auto* path = std::get_if<std::filesystem::path>(&fromEnvironment)) {
            defaults.push_back(*path);
        }
        PWSTR known = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &known)) && known) {
            if (auto fromShell = kite::ResolveSupportDirectory(std::nullopt, std::filesystem::path(known));
                auto* path = std::get_if<std::filesystem::path>(&fromShell)) {
                defaults.push_back(*path);
            }
        }
        CoTaskMemFree(known);
        for (const auto& real : defaults) {
            if (normal(real) == test) {
                return Fail(quiet, L"--perf-log, --perf-control and --chromium-switches never run on the default profile", kUsage);
            }
        }
    }
    // The perf log is open for the rest of the run, whichever way it ends (its last line, "exit").
    struct PerfLogClose {
        ~PerfLogClose() { kite::perf::Close(); }
    } perfLogClose;
    if (perfLogOption.value) {
        if (std::wstring problem = kite::perf::Open(*perfLogOption.value, chromiumSwitches); !problem.empty()) {
            return Fail(quiet, L"--perf-log: " + problem, kUsage);
        }
        kite::perf::Mark("started");
    }
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

    // The window and everything in it (shell/BrowserWindowController.h).
    std::wstring problem;
    kite::BrowserWindowController::Options options;
    options.capture = capture.has_value();
    options.smokeTest = smokeTest;
    options.frameLog = frameLogOption.present;
    options.perfControl = perfControl;
    options.chromiumSwitches = std::move(chromiumSwitches);
    options.spaceIcons = supportDirectory / L"SpaceIcons";
    // Closing the window, and logoff or shutdown (which skip WM_CLOSE), both save.
    auto save = [&] {
        if (maySave) saveError = session.Save(state);
    };
    auto controller = kite::BrowserWindowController::Create(instance, state, shortcuts, options, save, problem);
    if (!controller) return Fail(quiet, problem, kWindowFailed);
    kite::perf::Mark("window-created");
    if (commandBarOption.present && !controller->CommandBar()) return Fail(quiet, L"Kite couldn't make the command bar: " + controller->CommandBarError(), kWindowFailed);
    kite::MainWindow& window = controller->Window();

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
        if (static_cast<UINT>(std::max(widthPx, heightPx)) > controller->MaxTextureSize()) {
            return Fail(quiet, L"the capture would be " + std::to_wstring(widthPx) + L"×" + std::to_wstring(heightPx) +
                                   L" px, more than this GPU's " + std::to_wstring(controller->MaxTextureSize()) + L" px a side",
                        kUsage);
        }
    }
    if (size) window.SetClientSize(size->first, size->second);
    if (problem = controller->Draw(); !problem.empty()) return Fail(quiet, L"Kite couldn't draw its window: " + problem, kWindowFailed);
    kite::perf::Mark("first-commit");

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
    if (!capture) {
        switch (controller->StartChromium(supportDirectory / L"Chromium", problem)) {
        case kite::Chromium::StartResult::Started: break;
        // Another Kite has this profile and was told to come forward; this one leaves quietly,
        // before its window shows or it saves anything. A test run that found one tested
        // nothing, so it fails.
        case kite::Chromium::StartResult::AlreadyRunning:
            return quiet ? Fail(quiet, L"another Kite has this profile open", kWindowFailed) : kOk;
        case kite::Chromium::StartResult::Failed:
            return Fail(quiet, L"Kite couldn't start Chromium: " + problem, kWindowFailed);
        }
    }
#endif

    controller->Show(showCommand, quiet);
    kite::perf::Mark("shown");
    if (capture && !window.HasClientSize(size->first, size->second)) {
        // A capture is compared pixel for pixel with the Mac's, so a window Windows resized
        // (maximized by the launcher, clamped to 32767 px) would compare the wrong thing.
        return Fail(quiet, L"the window didn't get the size --capture needs", kCaptureFailed);
    }
    if (smokeTest) {
        if (problem = controller->SmokeTest(); !problem.empty()) return Fail(quiet, problem, kWindowFailed);
    }
    std::wstring captureError;
    if (capture) {
        // The window's own frame as presented: at --capture-scale× when given (the window is
        // laid out at that scale on any monitor), else at the monitor's.
        kite::Pixels pixels;
        const std::optional<std::string> barText =
            commandBarOption.present ? std::optional<std::string>(Narrow(*commandBarOption.value)) : std::nullopt;
        captureError = controller->Capture(pixels, barText, tipIndex);
        if (captureError.empty()) captureError = kite::SavePng(pixels, *capture);
        PostMessageW(window.Handle(), WM_CLOSE, 0, 0);
    }

    controller->RunMessageLoop();
    kite::perf::Mark("loop-end");
    if (capture && !captureError.empty()) return Fail(quiet, L"Capture failed: " + captureError, kCaptureFailed);
    if (frameLogOption.value) {
        if (problem = controller->SaveFrameLog(*frameLogOption.value); !problem.empty()) {
            return Fail(quiet, L"Couldn't write the frame log: " + problem, kSaveFailed);
        }
    }
#ifdef KITE_HAS_CEF
    if (problem = controller->ShutDownChromium(); !problem.empty()) return Fail(quiet, problem, kWindowFailed);
#endif
    if (!maySave) {
        return Fail(quiet, L"Kite couldn't read your session (" + loadError + L"), so it left the file as it was and didn't save this run's tabs.",
                    kSaveFailed);
    }
    if (!saveError.empty()) return Fail(quiet, L"Couldn't save the session: " + Widen(saveError), kSaveFailed);
    return kOk;
}
