// Kite for Windows. See docs/windows.md. With Chromium this is Kite.dll, and Kite.exe is CEF's
// bootstrap, which puts Chromium's helpers in the sandbox and calls RunWinMain below (the Mac's
// KiteHelper/main.mm enters the sandbox the same way, before the framework loads).
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second (with
//                            Chromium: until the selected tab's page has loaded, at most
//                            30 s, then one WM_CLOSE must close every browser in time),
//                            saves the session and exits 0 (CI). Errors go to the exit
//                            code, never a dialog. Fails if any window of Kite's (Chromium's
//                            too) became the foreground window: a quiet run stays behind.
//   Kite.exe --capture FILE.png [--window-size W,H] [--capture-scale N]   (absolute paths)
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
//   Kite.exe --capture FILE.png --swipe DX
//                            the same with two fingers on a touchpad holding the sidebar's
//                            content dragged DX points sideways (positive towards the previous
//                            space): the pages, the bar's light and the theme as they follow.
//   Kite.exe --capture FILE.png --space-drag N,X | --space-drop N,X
//                            the same with space N's cell in the bar (from 1) pressed and dragged
//                            to X points along the bar and held there (the ghost and the open
//                            slot), or let go there and settled (the space moved).
//   Kite.exe --capture FILE.png --space-menu N
//                            the same with space N's menu open over its cell, as a right-click
//                            there opens it (Windows' own menu, read back from its window).
//   Kite.exe --capture FILE.png --rename-space N
//                            the same with space N's header renaming it (Rename Space…), its name
//                            all selected.
//   Kite.exe --frame-log FILE
//                            a normal window on a test profile that writes each animation
//                            frame (a space switch's slide and crossfade) to FILE as it
//                            closes: one JSON object a line, `t`, `offset` and `theme`.
//   Kite.exe --save-log FILE  a quiet window (behind other windows, no dialogs) on a test profile
//                            that stays open until it's closed, then writes each session save
//                            it made (when, and its cost on the UI thread) and the writer's
//                            statistics to FILE as JSON: the live check of saving as it changes.
//                            KITE_TEST_SLOW_BACKUP_MS=N makes each backup take N ms more
//                            (the live check of a relaunch while Kite quits).
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
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "core/CommandLine.h"
#include "core/KeyBindings.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/SupportDirectory.h"
#include "shell/BackdropTest.h"
#include "shell/BrowserWindowController.h"
#ifdef KITE_HAS_CEF
#include "include/cef_sandbox_win.h"
#include "include/cef_version.h"
#include "shell/Chromium.h"
#endif
#include "shell/Capture.h"
#include "shell/MainWindow.h"
#include "shell/PerfLog.h"
#include "shell/QuietRun.h"
#include "shell/Text.h"

namespace {

using kite::Narrow;
using kite::Widen;
using kite::WriteUtf8;

// How long Kite waits, once its window is gone, for the session's last write.
constexpr std::chrono::milliseconds kQuitFlush{10'000};

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

#ifdef KITE_HAS_CEF
// Ends the process now, with `code` (Fail has already written why): what CEF asks for when
// CefInitialize fails.
[[noreturn]] void ExitNow(int code) {
    TerminateProcess(GetCurrentProcess(), static_cast<UINT>(code));
    ExitProcess(static_cast<UINT>(code));  // not reached
}
#endif

// Every path Kite is given (a file option, KITE_SUPPORT_PATH) must be absolute: Kite.exe runs
// from its own folder (CEF's bootstrap makes it the working directory, docs/windows.md
// "Chromium's sandbox"), so a relative one would land there rather than where it was typed.
// The refusal for `what`, or empty when `path` is absolute.
std::wstring RelativePathProblem(std::wstring_view what, const std::filesystem::path& path) {
    if (path.is_absolute()) return {};
    return std::wstring(what) + L" takes an absolute path (Kite.exe runs from its own folder)";
}

// A file option (--capture, --frame-log, --save-log, --perf-log): its value, and the usage error
// when it's given without one (`takes` says what it wants) or with a relative path. Every option
// naming a file goes through here.
struct PathOptionValue {
    bool present = false;
    std::optional<std::wstring> value;
    std::wstring problem;
};

PathOptionValue PathOption(const std::vector<std::wstring>& args, std::wstring_view name, std::wstring_view takes) {
    const OptionValue option = Option(args, name);
    PathOptionValue out{option.present, option.value, {}};
    if (option.present && !option.value) out.problem = std::wstring(name) + L" takes " + std::wstring(takes);
    else if (option.value) out.problem = RelativePathProblem(name, *option.value);
    return out;
}

int RunKite(HINSTANCE instance, int showCommand, [[maybe_unused]] void* sandboxInfo) {
    const std::vector<std::wstring> args = Arguments();
    std::vector<std::string> utf8;
    for (const std::wstring& a : args) utf8.push_back(Narrow(a));
#ifdef KITE_HAS_CEF
    // Chromium starts Kite.exe again for its renderer, GPU and utility processes, and reads the
    // raw command line in each (CefExecuteProcess parses GetCommandLineW itself). Those launches
    // are Chromium's own, so a --type spelled any other way, or naming a helper Kite doesn't run
    // (a crashpad handler, say), is someone else's: it ends here. The bootstrap has already put
    // each helper in its sandbox, and Kite.dll does nothing else in them.
    if (const auto type = kite::command_line::ChromiumProcessType(utf8)) {
        static constexpr std::string_view kHelpers[] = {"renderer", "gpu-process", "utility"};
        if (!type->canonical || std::find(std::begin(kHelpers), std::end(kHelpers), type->value) == std::end(kHelpers)) return kUsage;
    }
    if (const int code = kite::RunChromiumSubprocess(instance, sandboxInfo); code >= 0) return code;
#endif
    // Kite takes only its own flags and their values: anything else is an error, never a normal
    // launch on the real profile (a typo like --smoketest or --capture-scale=2). Chromium reads
    // the raw line too, before CEF stops it (command_line_args_disabled stops only the browser
    // process's later reads), trimming Unicode whitespace and taking "--", "-" and "/" as switch
    // prefixes; so no argument Chromium could read as a switch gets past this, not even as a
    // value (core/CommandLine.h).
    kite::command_line::Spec spec;
    spec.flags = {"--smoke-test", "--backdrop-test", "--perf-control"};
    spec.valueOptions = {"--capture", "--window-size", "--capture-scale", "--command-bar", "--frame-log", "--space-tip", "--swipe", "--space-drag", "--space-drop", "--space-menu", "--rename-space", "--save-log", "--perf-log"};
    // Its value is switches ("--a --b"), each checked against the allow-list below; Chromium's
    // raw read sees them too, so only allowed ones get this far.
    spec.switchValueOptions = {"--chromium-switches"};
    if (const auto problem = kite::command_line::Check(utf8, spec)) return Fail(true, Widen(*problem), kUsage);
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
    const PathOptionValue captureOption = PathOption(args, L"--capture", L"a PNG path");
    const OptionValue sizeOption = Option(args, L"--window-size");
    const std::optional<std::wstring>& capture = captureOption.value;
    const PathOptionValue saveLogOption = PathOption(args, L"--save-log", L"a file");
    const PathOptionValue perfLogOption = PathOption(args, L"--perf-log", L"a file");
    const bool perfControl = HasFlag(args, L"--perf-control");
    const OptionValue switchesOption = Option(args, L"--chromium-switches");
    // A quiet run: the one place that decides it (everything else reads Options::quiet). It
    // never comes to the front, takes the focus or shows a dialog (shell/QuietRun.h, the Mac's
    // KITE_DIAGNOSTICS test-safe mode): watched from here on, and --smoke-test fails if it did.
    // A capture, a save log and a measured run (kiteperf runs beside other work) are watched
    // too, and say so on stderr.
    const bool quiet = smokeTest || captureOption.present || saveLogOption.present || perfLogOption.present || perfControl ||
                       switchesOption.present;
    std::optional<kite::ForegroundWatch> foreground;
    if (quiet) foreground.emplace();
    if (!saveLogOption.problem.empty()) return Fail(quiet, saveLogOption.problem, kUsage);
    if (!captureOption.problem.empty()) return Fail(quiet, captureOption.problem, kUsage);
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
    const OptionValue swipeOption = Option(args, L"--swipe");
    std::optional<double> swipe;
    if (swipeOption.present) {
        const std::string text = swipeOption.value ? Narrow(*swipeOption.value) : std::string();
        double dx = 0;
        auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), dx);
        if (text.empty() || error != std::errc() || end != text.data() + text.size() || dx == 0 || !(std::abs(dx) <= 10000)) {
            return Fail(quiet, L"--swipe takes the points the fingers dragged, -10000 to 10000 and not 0", kUsage);
        }
        swipe = dx;
    }
    if (swipeOption.present && !captureOption.present) return Fail(quiet, L"--swipe only goes with --capture", kUsage);
    // The space bar's and the header's editing states: a space's place (from 1), and for a drag
    // the points along the bar it's dragged to.
    const auto place = [](const std::wstring& text) -> std::optional<size_t> {
        if (text.empty() || text.size() > 3 || !std::all_of(text.begin(), text.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; })) {
            return std::nullopt;
        }
        const int n = std::stoi(text);
        return n >= 1 ? std::optional<size_t>(static_cast<size_t>(n - 1)) : std::nullopt;
    };
    struct HeldDrag {
        size_t index;
        float x;
        bool drop;
    };
    std::optional<HeldDrag> heldDrag;
    for (const wchar_t* flag : {L"--space-drag", L"--space-drop"}) {
        const OptionValue option = Option(args, flag);
        if (!option.present) continue;
        const std::string text = option.value ? Narrow(*option.value) : std::string();
        const size_t comma = text.find(',');
        float x = 0;
        const char* begin = comma == std::string::npos ? nullptr : text.data() + comma + 1;
        const auto [end, failed] = begin ? std::from_chars(begin, text.data() + text.size(), x) : std::from_chars_result{nullptr, std::errc::invalid_argument};
        const std::optional<size_t> index = comma == std::string::npos ? std::nullopt : place(Widen(text.substr(0, comma)));
        if (!index || failed != std::errc() || end != text.data() + text.size() || !(std::abs(x) <= 10000) || heldDrag) {
            return Fail(quiet, std::wstring(flag) + L" takes a space's place from 1 and the points along the bar, N,X (one of --space-drag and --space-drop)", kUsage);
        }
        if (!captureOption.present) return Fail(quiet, std::wstring(flag) + L" only goes with --capture", kUsage);
        heldDrag = HeldDrag{*index, x, std::wstring(flag) == L"--space-drop"};
    }
    std::optional<size_t> heldMenu, heldRename;
    for (const auto& [flag, out] : {std::pair<const wchar_t*, std::optional<size_t>*>{L"--space-menu", &heldMenu}, {L"--rename-space", &heldRename}}) {
        const OptionValue option = Option(args, flag);
        if (!option.present) continue;
        *out = option.value ? place(*option.value) : std::nullopt;
        if (!*out) return Fail(quiet, std::wstring(flag) + L" takes a space's place, from 1", kUsage);
        if (!captureOption.present) return Fail(quiet, std::wstring(flag) + L" only goes with --capture", kUsage);
    }
    const PathOptionValue frameLogOption = PathOption(args, L"--frame-log", L"a file");
    if (!frameLogOption.problem.empty()) return Fail(quiet, frameLogOption.problem, kUsage);
    if (!perfLogOption.problem.empty()) return Fail(quiet, perfLogOption.problem, kUsage);
    // "--name" or "--name=value", split on spaces, from an allow-list (shell/PerfProtocol.h):
    // nothing that weakens the sandbox, site isolation or web security, opens a debugging port,
    // or changes a path or a launched process.
    std::vector<std::string> chromiumSwitches;
    if (switchesOption.present) {
        if (!switchesOption.value) return Fail(quiet, L"--chromium-switches takes Chromium's switches", kUsage);
        std::wstring refused;
        auto parsed = kite::perf::ParseChromiumSwitches(*switchesOption.value, refused);
        if (!parsed) return Fail(quiet, L"--chromium-switches doesn't allow " + refused, kUsage);
        chromiumSwitches = std::move(*parsed);
    }

    const auto supportOverride = kite::EnvironmentPath("KITE_SUPPORT_PATH");
    // Test flags only run on a test profile, like the Mac's KITE_WINDOW_SIZE: a smoke test or
    // capture loads and re-saves the session, which must never be the user's own.
    if ((smokeTest || captureOption.present || sizeOption.present || scaleOption.present || frameLogOption.present ||
         saveLogOption.present || perfLogOption.present || perfControl || switchesOption.present) &&
        !supportOverride) {
        return Fail(quiet,
                    L"--smoke-test, --capture, --window-size, --capture-scale, --frame-log, --save-log, --perf-log, --perf-control "
                    L"and --chromium-switches need KITE_SUPPORT_PATH set to a test profile",
                    kUsage);
    }
    if (supportOverride && !supportOverride->empty()) {
        if (const std::wstring problem = RelativePathProblem(L"KITE_SUPPORT_PATH", *supportOverride); !problem.empty()) {
            return Fail(quiet, problem, kBadSupportDirectory);
        }
    }
    auto resolved = kite::ResolveSupportDirectory(supportOverride, kite::EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<kite::SupportDirectoryError>(&resolved)) {
        return Fail(quiet, Widen(error->message), kBadSupportDirectory);
    }
    std::filesystem::path supportDirectory = std::get<std::filesystem::path>(resolved);
    const bool perfHooks = perfLogOption.present || perfControl || switchesOption.present;
    // Held open for the whole run, without FILE_SHARE_DELETE, so the profile the hooks were
    // allowed on can't be renamed away and another put in its place.
    struct Handle {
        HANDLE h = INVALID_HANDLE_VALUE;
        ~Handle() {
            if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
        }
    } profileHandle;
    if (perfHooks) {
        const auto openDirectory = [](const std::filesystem::path& p, DWORD share) {
            return CreateFileW(p.c_str(), FILE_READ_ATTRIBUTES, share, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        };
        // A directory's identity: its volume and file id, the same however it's spelled (a
        // different case, a junction, a UNC path or a share alias).
        const auto identity = [](HANDLE h) -> std::optional<FILE_ID_INFO> {
            FILE_ID_INFO id{};
            if (h == INVALID_HANDLE_VALUE || !GetFileInformationByHandleEx(h, FileIdInfo, &id, sizeof id)) return std::nullopt;
            return id;
        };
        const auto same = [](const FILE_ID_INFO& a, const FILE_ID_INFO& b) {
            return a.VolumeSerialNumber == b.VolumeSerialNumber && std::memcmp(&a.FileId, &b.FileId, sizeof a.FileId) == 0;
        };
        profileHandle.h = openDirectory(supportDirectory, FILE_SHARE_READ | FILE_SHARE_WRITE);
        const auto test = identity(profileHandle.h);
        wchar_t finalPath[MAX_PATH * 4];
        const DWORD length = profileHandle.h == INVALID_HANDLE_VALUE
                                 ? 0
                                 : GetFinalPathNameByHandleW(profileHandle.h, finalPath, static_cast<DWORD>(std::size(finalPath)), FILE_NAME_NORMALIZED);
        if (!test || length == 0 || length >= std::size(finalPath)) {
            return Fail(quiet, L"--perf-log, --perf-control and --chromium-switches: KITE_SUPPORT_PATH couldn't be resolved", kUsage);
        }
        // The rest of the run uses the directory that was checked, by its resolved path.
        std::wstring resolvedPath(finalPath, length);
        if (resolvedPath.starts_with(L"\\\\?\\UNC\\")) resolvedPath = L"\\\\" + resolvedPath.substr(8);
        else if (resolvedPath.starts_with(L"\\\\?\\")) resolvedPath = resolvedPath.substr(4);
        supportDirectory = resolvedPath;
        // Never the default profile: from the environment and from the known folder (LOCALAPPDATA
        // can be set to anything).
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
            HANDLE h = openDirectory(real, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
            const auto id = identity(h);
            if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
            if (id && same(*id, *test)) {
                return Fail(quiet, L"--perf-log, --perf-control and --chromium-switches never run on the default profile", kUsage);
            }
        }
        // And only a profile that says it's a test profile (kiteperf and CI make the marker).
        std::error_code markerError;
        if (!std::filesystem::is_regular_file(supportDirectory / kite::perf::kTestProfileMarker, markerError)) {
            return Fail(quiet,
                        L"--perf-log, --perf-control and --chromium-switches need a test profile: KITE_SUPPORT_PATH has no " +
                            std::wstring(kite::perf::kTestProfileMarker) + L" file",
                        kUsage);
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
    // window exists (the one read the UI thread may make, docs/windows-architecture.md); an
    // unreadable one is moved aside and the newest backup that reads stands in for it.
    kite::SessionStore session(supportDirectory / L"session.json");
    kite::BrowserState state;
    std::optional<kite::SessionBackups::Backup> recoveredFrom;
    auto loaded = session.Load(kite::SessionStore::Unreadable::MoveAside, &recoveredFrom);
    if (recoveredFrom) {
        // The Mac says so in a toast ("Kite restored your tabs from a backup made <date>"); until
        // Windows has toasts, the debugger hears it, and so does a quiet run's stderr.
        const std::string stamp = kite::SessionBackups::Stamp(recoveredFrom->date);
        const std::wstring message = L"Kite restored your tabs from a backup made " + Widen(stamp.substr(0, 10)) + L" " +
                                     Widen(stamp.substr(11, 2)) + L":" + Widen(stamp.substr(14, 2)) + L" UTC (" +
                                     recoveredFrom->file.filename().wstring() + L"): session.json couldn't be read and was moved aside\n";
        OutputDebugStringW((L"Kite: " + message).c_str());
        if (quiet) WriteUtf8(STD_ERROR_HANDLE, L"Kite: " + message);
    }
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
    // The session is written as it changes, on the writer's thread (core/SessionWriter.h); it
    // outlives the window, whose close saves once more, and Kite waits for that write once the
    // window is gone. Never when the file is still there unread.
    // The live check of a relaunch while Kite quits: a --save-log run (a test profile) with
    // KITE_TEST_SLOW_BACKUP_MS set takes that long over each backup (the clock the writer dates
    // them by), so the wait at quit lasts long enough for a relaunch to land in it.
    std::function<double()> clock = kite::SessionBackups::Now;
    if (const DWORD slowMs = saveLogOption.present ? GetEnvironmentVariableW(L"KITE_TEST_SLOW_BACKUP_MS", nullptr, 0) : 0; slowMs) {
        std::wstring value(slowMs, L'\0');
        value.resize(GetEnvironmentVariableW(L"KITE_TEST_SLOW_BACKUP_MS", value.data(), slowMs));
        if (auto ms = ParseInt(value); ms && *ms <= 60'000) {
            clock = [ms = *ms] {
                Sleep(static_cast<DWORD>(ms));
                return kite::SessionBackups::Now();
            };
        }
    }
    kite::SessionWriter writer(session, maySave, std::move(clock));
    // A write still stuck as Kite ends (a disk that hangs past kQuitFlush), the session's or
    // history's: the process ends there, without the C++ library's teardown running under the
    // writer's thread. The file is the old one or the new one (the writes are atomic); the run is
    // a failed save.
    const auto endStuck = [quiet] {
        const std::wstring message = L"Kite: a last write (the session or history) didn't finish; Kite ended without waiting for it\n";
        OutputDebugStringW(message.c_str());
        if (quiet) WriteUtf8(STD_ERROR_HANDLE, message);
        TerminateProcess(GetCurrentProcess(), kSaveFailed);
    };
    writer.OnStuck(endStuck);
    // Browsing history (core/HistoryStore.h): every profile's file read and written on history's
    // own worker, once this launch is Kite's (Start, below: a second launch, which hands over to
    // the running Kite, never opens its history). Until a file is in, visits are kept and
    // replayed over it. Like the session's writer, it outlives the window.
    kite::HistoryStores history(supportDirectory);
    history.OnStuck(endStuck);
    // As the Mac does once per launch, the session as found (read, recovered or a fresh one, as
    // BrowserStore.init) is kept as a launch backup: before the auto-archive, as the Mac's is
    // before its first pass, but handed over only once this launch is Kite's (not a second one
    // that hands over to the running Kite, which the Mac never even starts).
    std::optional<kite::BrowserState> found;
    if (!std::holds_alternative<kite::SessionStore::Error>(loaded)) found = state;
    // A test run must show the session it was given, never a default in its place.
    if (quiet && std::holds_alternative<kite::SessionStore::Error>(loaded)) {
        return Fail(quiet, L"couldn't read the session: " + Widen(std::get<kite::SessionStore::Error>(loaded).message), kSaveFailed);
    }
    std::wstring loadError;
    if (auto* error = std::get_if<kite::SessionStore::Error>(&loaded); error && !maySave) loadError = Widen(error->message);
    // Unpinned tabs left unused past Archive Tabs After go to the archive as Kite starts, as
    // the Mac's applicationDidFinishLaunching does (and every 15 minutes, below). A capture
    // shows its session as given.
    bool archivedAtLaunch = false;
    if (!capture) {
        if (auto interval = state.ArchiveAfterSeconds()) archivedAtLaunch = !state.ArchiveStaleTabs(*interval).empty();
    }

    // The window and everything in it (shell/BrowserWindowController.h).
    std::wstring problem;
    kite::BrowserWindowController::Options options;
    options.capture = capture.has_value();
    options.smokeTest = smokeTest;
    options.frameLog = frameLogOption.present;
    options.perfControl = perfControl;
    options.chromiumSwitches = std::move(chromiumSwitches);
    options.saveLog = saveLogOption.present;
    options.quiet = quiet;
    options.spaceIcons = supportDirectory / L"SpaceIcons";
    auto controller = kite::BrowserWindowController::Create(instance, state, shortcuts, options, &writer, &history, problem);
    if (!controller) return Fail(quiet, problem, kWindowFailed);
    kite::perf::Mark("window-created");
    if (commandBarOption.present && !controller->CommandBar()) return Fail(quiet, L"Kite couldn't make the command bar: " + controller->CommandBarError(), kWindowFailed);
    if (archivedAtLaunch) controller->SessionChanged();
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
        // Kite.rc's icon is in the module the window code is in (Kite.dll with Chromium, else
        // Kite.exe), and the window has it for the taskbar and Alt+Tab.
        const HWND hwnd = window.Handle();
        if (!GetClassLongPtrW(hwnd, GCLP_HICON) || !GetClassLongPtrW(hwnd, GCLP_HICONSM)) {
            return Fail(quiet, L"the window's class has no icon: Kite.rc's icon wasn't embedded in Kite's module (Kite.dll with Chromium, else Kite.exe)", kWindowFailed);
        }
        if (!SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0) || !SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0)) {
            return Fail(quiet, L"the window has no icon of its own (WM_SETICON)", kWindowFailed);
        }
    }

#ifdef KITE_HAS_CEF
    // The selected tab's page on the content card. A capture leaves Chromium out: a child
    // window isn't in the composition tree it reads back (until W10 makes pages textures).
    if (!capture) {
        switch (controller->StartChromium(supportDirectory / L"Chromium", sandboxInfo, problem)) {
        case kite::Chromium::StartResult::Started: break;
        // Another Kite has this profile and was told to come forward; this one leaves quietly,
        // before its window shows or it saves anything. A test run that found one tested
        // nothing, so it fails.
        // CefInitialize returned false either way: CEF requires the process to end at once, with
        // no CefShutdown and none of Chromium's or Kite's teardown after it.
        case kite::Chromium::StartResult::AlreadyRunning:
            ExitNow(quiet ? Fail(quiet, L"another Kite has this profile open", kWindowFailed) : kOk);
        case kite::Chromium::StartResult::Failed:
            ExitNow(Fail(quiet, L"Kite couldn't start Chromium: " + problem, kWindowFailed));
        }
    }
#endif
    if (found) writer.BackUpLaunch(std::move(*found));
    // This launch is Kite's (or a capture's): history's files may be read now.
    history.Start();

    controller->Show(showCommand);
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
        if (swipe) captureError = controller->HoldSwipe(*swipe);
        if (captureError.empty() && heldDrag) captureError = controller->HoldSpaceDrag(heldDrag->index, heldDrag->x, heldDrag->drop);
        if (captureError.empty() && heldRename) captureError = controller->HoldRename(*heldRename, std::nullopt, true);
        if (heldMenu) controller->HoldSpaceMenu(*heldMenu);
        if (captureError.empty()) captureError = controller->Capture(pixels, barText, tipIndex);
        if (captureError.empty()) captureError = kite::SavePng(pixels, *capture);
        PostMessageW(window.Handle(), WM_CLOSE, 0, 0);
    }

    controller->RunMessageLoop();
    kite::perf::Mark("loop-end");
    // The window's close handed over the last saves, the session's and history's; wait for them
    // now that the window is gone (no frozen window), kQuitFlush at most for both (the atomic
    // writes leave the old file or the new one). Before Chromium shuts down: until then this Kite
    // holds the profile, so a launch in the meantime hands over to it rather than read a file
    // about to be replaced.
    const kite::Deadline quitDeadline = kite::DeadlineAfter(kQuitFlush);
    const std::string saveError = writer.Flush(quitDeadline);
    const std::string historyError = history.Flush(quitDeadline);
    // Still writing after that: end here, before Chromium's shutdown or a dialog, while the
    // stuck write may yet rename (no other Kite can have the profile until this one is gone).
    if (writer.Writing() || history.Writing()) endStuck();
    if (!historyError.empty()) OutputDebugStringW((L"Kite: " + Widen(historyError) + L"\n").c_str());
    if (capture && !captureError.empty()) return Fail(quiet, L"Capture failed: " + captureError, kCaptureFailed);
    if (frameLogOption.value) {
        if (problem = controller->SaveFrameLog(*frameLogOption.value); !problem.empty()) {
            return Fail(quiet, L"Couldn't write the frame log: " + problem, kSaveFailed);
        }
    }
#ifdef KITE_HAS_CEF
    // CI's log shows what the smoke test found of the renderer's and the helpers' sandbox.
    if (smokeTest) WriteUtf8(STD_OUTPUT_HANDLE, controller->SandboxReport());
    if (problem = controller->ShutDownChromium(); !problem.empty()) return Fail(quiet, problem, kWindowFailed);
#endif
    if (saveLogOption.value) {
        if (problem = controller->SaveSaveLog(*saveLogOption.value); !problem.empty()) {
            return Fail(quiet, L"Couldn't write the save log: " + problem, kSaveFailed);
        }
    }
    if (foreground) {
        if (problem = foreground->Problem(); !problem.empty()) {
            if (smokeTest) return Fail(quiet, problem, kWindowFailed);
            WriteUtf8(STD_ERROR_HANDLE, L"Kite: " + problem + L"\n");
        }
    }
    if (!maySave) {
        return Fail(quiet, L"Kite couldn't read your session (" + loadError + L"), so it left the file as it was and didn't save this run's tabs.",
                    kSaveFailed);
    }
    if (!saveError.empty()) {
        return Fail(quiet, L"Couldn't save the session: " + Widen(saveError), kSaveFailed);
    }
    // A test run fails on it; otherwise the next change or launch tries again, as on the Mac.
    if (quiet && !historyError.empty()) return Fail(quiet, L"Couldn't save history: " + Widen(historyError), kSaveFailed);
    return kOk;
}

}  // namespace

#ifdef KITE_HAS_CEF
// Kite.exe is CEF's bootstrap.exe (docs/windows.md, "Chromium's sandbox"), which calls this in
// every process: the browser, and each helper already in the sandbox, whose `sandboxInfo`
// goes to CefExecuteProcess and CefInitialize. A bootstrap from another CEF, or none at all,
// is a broken build, so Kite stops. In a helper (Chromium gives it --type) that's only the exit
// code: it may be under win32k lockdown, where a dialog (user32) can't load. The browser
// process shows it as any other failure, unless it's a test run.
CEF_BOOTSTRAP_EXPORT int RunWinMain(HINSTANCE instance, LPWSTR, int showCommand, void* sandboxInfo, cef_version_info_t* version) {
    std::wstring problem;
    if (!version || version->cef_version_major != CEF_VERSION_MAJOR || version->cef_version_minor != CEF_VERSION_MINOR ||
        version->cef_version_patch != CEF_VERSION_PATCH || version->cef_commit_number != CEF_COMMIT_NUMBER) {
        problem = L"Kite.exe isn't the bootstrap of the CEF Kite.dll was built with: reinstall Kite";
    } else if (!sandboxInfo) {
        problem = L"Kite.exe gave Kite.dll no sandbox (it isn't CEF's bootstrap): reinstall Kite";
    }
    if (!problem.empty()) {
        // A helper is anything Chromium would read a --type from (core/CommandLine.h, as RunKite
        // checks it); the rest is quiet as RunKite decides it, plus --backdrop-test.
        const std::vector<std::wstring> args = Arguments();
        std::vector<std::string> utf8;
        for (const std::wstring& a : args) utf8.push_back(Narrow(a));
        const bool helper = kite::command_line::ChromiumProcessType(utf8).has_value();
        const bool quiet = helper || HasFlag(args, L"--smoke-test") || HasFlag(args, L"--backdrop-test") || Option(args, L"--capture").present ||
                           Option(args, L"--save-log").present || Option(args, L"--perf-log").present || HasFlag(args, L"--perf-control") ||
                           Option(args, L"--chromium-switches").present;
        return Fail(quiet, problem, kWindowFailed);
    }
    return RunKite(instance, showCommand, sandboxInfo);
}
#else
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) { return RunKite(instance, showCommand, nullptr); }
#endif
