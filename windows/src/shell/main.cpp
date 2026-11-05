// Kite for Windows. See docs/windows.md.
//
//   Kite.exe                 normal launch
//   Kite.exe --smoke-test    opens the window, runs the message loop for a second (with
//                            Chromium: until the selected tab's page has loaded, at most
//                            30 s, then one WM_CLOSE must close every browser in time),
//                            saves the session and exits 0 (CI). Errors go to the exit
//                            code, never a dialog. Fails if any window of Kite's (Chromium's
//                            too) became the foreground window: a quiet run stays behind.
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
//   Kite.exe --save-log FILE  a quiet window (behind other windows, no dialogs) on a test profile
//                            that stays open until it's closed, then writes each session save
//                            it made (when, and its cost on the UI thread) and the writer's
//                            statistics to FILE as JSON: the live check of saving as it changes.
//                            KITE_TEST_SLOW_BACKUP_MS=N makes each backup take N ms more
//                            (the live check of a relaunch while Kite quits). It logs the
//                            downloads too (Chromium's reports, what each cost the UI thread,
//                            downloads.json's writes): the live check of the download engine.
//
// Downloads go to the profile's chosen folder, else the user's Downloads. KITE_TEST_DOWNLOADS_PATH
// (with KITE_SUPPORT_PATH, as on the Mac) puts them in a test's own folder; a quiet run without
// it uses <support>\Downloads, never the user's.
//   Kite.exe --backdrop-test draws the theme backdrop on the GPU and checks every pixel against
//                            core's CPU reference of the Mac's shader (shell/BackdropTest.h).
//                            Prints a report; exits 0 when it matches, 5 when it differs, 3
//                            when it couldn't run (no GPU device, no float target).

#include <windows.h>

#include <knownfolders.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <charconv>
#include <chrono>
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

#include "core/DownloadsWriter.h"
#include "core/KeyBindings.h"
#include "core/ProfileSettings.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/SupportDirectory.h"
#include "shell/BackdropTest.h"
#include "shell/BrowserWindowController.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/Capture.h"
#include "shell/MainWindow.h"
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

// The user's Downloads folder (FOLDERID_Downloads, which they may have moved), else
// %USERPROFILE%\Downloads.
std::filesystem::path UserDownloads() {
    PWSTR path = nullptr;
    std::filesystem::path folder;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT, nullptr, &path)) && path) folder = path;
    CoTaskMemFree(path);
    if (folder.empty()) {
        if (auto profile = kite::EnvironmentPath("USERPROFILE"); profile && !profile->empty()) folder = *profile / L"Downloads";
    }
    return folder;
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
        if (a == L"--capture" || a == L"--window-size" || a == L"--capture-scale" || a == L"--command-bar" || a == L"--frame-log" ||
            a == L"--space-tip" || a == L"--save-log") {
            ++i;
            continue;
        }
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
    const OptionValue saveLogOption = Option(args, L"--save-log");
    // A quiet run: the one place that decides it (everything else reads Options::quiet). It
    // never comes to the front, takes the focus or shows a dialog (shell/QuietRun.h, the Mac's
    // KITE_DIAGNOSTICS test-safe mode): watched from here on, and --smoke-test fails if it did.
    // A capture and a --save-log run are watched too, and say so on stderr.
    const bool quiet = smokeTest || captureOption.present || saveLogOption.present;
    std::optional<kite::ForegroundWatch> foreground;
    if (quiet) foreground.emplace();
    if (saveLogOption.present && !saveLogOption.value) return Fail(quiet, L"--save-log takes a file", kUsage);
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

    const auto supportOverride = kite::EnvironmentPath("KITE_SUPPORT_PATH");
    // Test flags only run on a test profile, like the Mac's KITE_WINDOW_SIZE: a smoke test or
    // capture loads and re-saves the session, which must never be the user's own.
    if ((smokeTest || captureOption.present || sizeOption.present || scaleOption.present || frameLogOption.present ||
         saveLogOption.present) &&
        !supportOverride) {
        return Fail(quiet,
                    L"--smoke-test, --capture, --window-size, --capture-scale, --frame-log and --save-log need KITE_SUPPORT_PATH set to "
                    L"a test profile",
                    kUsage);
    }
    auto resolved = kite::ResolveSupportDirectory(supportOverride, kite::EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<kite::SupportDirectoryError>(&resolved)) {
        return Fail(quiet, Widen(error->message), kBadSupportDirectory);
    }
    const std::filesystem::path supportDirectory = std::get<std::filesystem::path>(resolved);
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
    // A write still stuck as Kite ends (a disk that hangs past kQuitFlush): the process ends
    // there, without the C++ library's teardown running under the writer's thread. The file is
    // the old one or the new one (the write is atomic); the run is a failed save.
    const auto endStuck = [quiet] {
        const std::wstring message = L"Kite: the session's last write didn't finish; Kite ended without waiting for it\n";
        OutputDebugStringW(message.c_str());
        if (quiet) WriteUtf8(STD_ERROR_HANDLE, message);
        TerminateProcess(GetCurrentProcess(), kSaveFailed);
    };
    writer.OnStuck(endStuck);
    // downloads.json, read on its worker once the window shows (not by a launch that hands over)
    // and written as the list changes (core/DownloadsWriter.h); none for a capture, which has no
    // pages.
    std::optional<kite::DownloadsWriter> downloadsWriter;
    if (!capture) {
        downloadsWriter.emplace(supportDirectory / L"downloads.json");
        downloadsWriter->OnStuck(endStuck);
    }
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
    options.saveLog = saveLogOption.present;
    options.spaceIcons = supportDirectory / L"SpaceIcons";
    options.quiet = quiet;
    // KITE_TEST_DOWNLOADS_PATH is a test's own folder: a relative one would land wherever Kite
    // was started from, so it's refused rather than guessed.
    const auto testDownloads = kite::EnvironmentPath("KITE_TEST_DOWNLOADS_PATH");
    if (testDownloads && !testDownloads->empty() && !testDownloads->is_absolute()) {
        return Fail(quiet, L"KITE_TEST_DOWNLOADS_PATH must be an absolute path", kUsage);
    }
    options.downloadFolder = kite::DefaultDownloadFolder(
        testDownloads, kite::IsTestProfile(supportDirectory, kite::EnvironmentPath("LOCALAPPDATA")), quiet, supportDirectory, UserDownloads());
    auto controller = kite::BrowserWindowController::Create(instance, state, shortcuts, options, &writer,
                                                            downloadsWriter ? &*downloadsWriter : nullptr, problem);
    if (!controller) return Fail(quiet, problem, kWindowFailed);
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
    if (found) writer.BackUpLaunch(std::move(*found));

    controller->Show(showCommand);
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
    // The window's close handed over the last save; wait for it now that the window is gone (no
    // frozen window), for kQuitFlush at most (the atomic write leaves the old file or the new
    // one). Before Chromium shuts down: until then this Kite holds the profile, so a launch in
    // the meantime hands over to it rather than read a session.json about to be replaced.
    // One deadline for every write still to come: the session's, then downloads.json's (a read
    // the window never got is joined first, then its last save).
    const auto quitDeadline = std::chrono::steady_clock::now() + kQuitFlush;
    const std::string saveError = writer.Flush(kite::BrowserWindowController::Left(quitDeadline));
    std::string downloadsError;
    if (downloadsWriter) {
        controller->FinishDownloads(quitDeadline);
        downloadsError = downloadsWriter->Flush(kite::BrowserWindowController::Left(quitDeadline));
    }
    // Still writing after that: end here, before Chromium's shutdown or a dialog, while the
    // stuck write may yet rename (no other Kite can have the profile until this one is gone).
    if (writer.Writing() || (downloadsWriter && downloadsWriter->Writing())) endStuck();
    if (!downloadsError.empty()) {
        OutputDebugStringW((L"Kite: " + Widen(downloadsError) + L"\n").c_str());
        if (quiet) WriteUtf8(STD_ERROR_HANDLE, L"Kite: couldn't save the downloads: " + Widen(downloadsError) + L"\n");
    }
    if (capture && !captureError.empty()) return Fail(quiet, L"Capture failed: " + captureError, kCaptureFailed);
    if (frameLogOption.value) {
        if (problem = controller->SaveFrameLog(*frameLogOption.value); !problem.empty()) {
            return Fail(quiet, L"Couldn't write the frame log: " + problem, kSaveFailed);
        }
    }
#ifdef KITE_HAS_CEF
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
    return kOk;
}
