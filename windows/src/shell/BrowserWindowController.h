#pragma once
// The browser window and what's in it, as the Mac's BrowserWindowController: the backdrop,
// the sidebar, the caption buttons, the command bar, the pages (Chromium) and Kite's
// shortcuts, wired to the session (core/Models.h). main.cpp parses the command line, loads the
// session, and runs one of these.
//
// Everything here is on Kite's UI thread. The session is the caller's, borrowed for the
// window's life. The window changes it and saves it as it changes, as the Mac's BrowserStore
// does: each change arms a one-shot timer (core/SessionSaveDelay.h's SaveSchedule: a second,
// ten for a page's title or favicon), and when it fires a copy of the session goes to the
// caller's SessionWriter, which writes it on its own thread. Closing the window saves at once
// (main.cpp waits for that write once the window is gone); logoff and shutdown save at once and
// wait here, for kEndSessionFlush at most.
//
// Browsing history goes to the caller's HistoryStores (core/HistoryStore.h) as the Mac's
// BrowserStore records it: a visit when a page reports a main-frame address its tab hasn't
// recorded yet (CEF's OnAddressChange, as the Mac's addressDidChange: the URL a navigation
// commits, after its redirects, and a same-document change to a new URL, such as pushState or
// a fragment, as a visit of its own; a reload records nothing), and the page's title for the
// last address recorded. The stores' one save timer is armed after each change (3 s, at most
// 30), and closing the window saves them too.

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "core/HistoryStore.h"
#include "core/KeyBindings.h"
#include "core/LiveTabPolicy.h"
#include "core/Models.h"
#include "core/SessionSaveDelay.h"
#include "core/SessionWriter.h"
#include "core/SpaceSwipe.h"
#include "core/ThemeBackdrop.h"
#include "shell/CaptionButtonsView.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/CommandBarView.h"
#include "shell/Compositor.h"
#include "shell/Favicons.h"
#include "shell/FrameClock.h"
#include "shell/MainWindow.h"
#include "shell/MemoryPressure.h"
#include "shell/Renderer.h"
#include "shell/SidebarView.h"

namespace kite {

class BrowserWindowController {
public:
    struct Options {
        // A --capture run: the solid material under the backdrop (not what's behind the
        // window), no favicons (no network) and no auto-archive. The caller doesn't start
        // Chromium for one.
        bool capture = false;
        // --smoke-test: every shortcut command must do something, and the first page's load
        // closes the window.
        bool smokeTest = false;
        // --frame-log: each frame the clock delivered (when it was handled, the time it was
        // drawn for, the pages' offset and the theme's crossfade) is kept for SaveFrameLog.
        bool frameLog = false;
        // --save-log: each save handed to the writer (when, and what it cost the UI thread) is
        // kept for SaveSaveLog.
        bool saveLog = false;
        // The profile's SpaceIcons folder: the pictures chosen as space icons (a capture
        // decodes them in place, the rest on a worker).
        std::filesystem::path spaceIcons;
        // The profile's folder, where Import from Arc puts its shortcut changes and routes.
        std::filesystem::path supportDirectory;
    };

    // The window and everything in it, laid out and wired, not yet shown or drawn. Null with
    // `error` when the GPU, the window or a view couldn't be made. No command bar isn't a
    // failure (CommandBar() is null then). `writer` (the caller's, outliving the window) gets
    // the session as it changes, and once more as the window closes, and at logoff or shutdown,
    // after the pages' last reports; null saves nothing. `history` (the caller's too) gets the
    // pages' visits and gives the command bar its history rows; null records nothing.
    static std::unique_ptr<BrowserWindowController> Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                           Options options, SessionWriter* writer, HistoryStores* history,
                                                           std::wstring& error);
    ~BrowserWindowController();
    BrowserWindowController(const BrowserWindowController&) = delete;
    BrowserWindowController& operator=(const BrowserWindowController&) = delete;

    MainWindow& Window() { return window_; }
    CommandBarView* CommandBar() { return commandBar_.get(); }
    // Why there's no command bar, when there isn't one.
    const std::wstring& CommandBarError() const { return barError_; }
    UINT MaxTextureSize() const { return renderer_ ? renderer_->MaxTextureSize() : 0; }

#ifdef KITE_HAS_CEF
    // Starts Chromium for the window's pages, its profiles under `root`. AlreadyRunning: another
    // Kite has the profile and was told to come forward.
    Chromium::StartResult StartChromium(const std::filesystem::path& root, std::wstring& error);
    // After the message loop: Chromium's shutdown, then what a smoke test checks of it. Empty
    // when it all went well (or there was no Chromium).
    std::wstring ShutDownChromium();
#endif
    // Shows the window (behind other windows for a quiet run) and, with Chromium, the first page,
    // and starts the auto-archive's timer.
    void Show(int showCommand, bool behindOtherWindows);

    // Draws the backdrop, the sidebar and the caption buttons and commits them; with
    // `readBack`, the backdrop's frame as presented. Rebuilds a lost GPU first.
    std::wstring Draw(Pixels* readBack = nullptr);
    // The animation frames of the run (Options::frameLog), one JSON object a line: `t` (when it
    // was handled, s from the first), `target` (the composition frame it was drawn for, s from
    // the first), `offset` (the pages', pt) and `theme` (the crossfade, 0...1). Empty on success.
    std::wstring SaveFrameLog(const std::filesystem::path& file) const;
    // The run's saves (Options::saveLog) as one JSON object: `saves` (`t`, s from the window's
    // creation; `uiMicros`, the copy handed to the writer; `closing`), `frames` (frames the
    // clock delivered) and `writer` (the writer's statistics after its last write). Empty on
    // success.
    std::wstring SaveSaveLog(const std::filesystem::path& file) const;
    // The smoke test's checks of the window: the command bar opens and draws, the sidebar and
    // the caption buttons draw something, and the lost-GPU path rebuilds and draws. Empty on
    // success. Then the window closes once the first page has loaded (30 s at most), or after
    // a second without Chromium.
    std::wstring SmokeTest();
    // The window's frame as the screen shows it: the backdrop with the sidebar, the caption
    // buttons and (with `barText`) the command bar opened with that text, composed over it.
    std::wstring Capture(Pixels& pixels, const std::optional<std::string>& barText, std::optional<size_t> tip = std::nullopt);

    // Runs messages until WM_QUIT, rebuilding the GPU when its device is removed.
    void RunMessageLoop();

    // The session changed outside the window's own handlers (main.cpp's auto-archive at
    // launch): it's saved after `delay`, as the window's own changes are.
    void SessionChanged(SessionSaveDelay delay = SessionSaveDelay::Soon);

    // How long the window waits for the session's last write when Windows ends the session
    // (WM_ENDSESSION: the process may end as soon as it returns). Giving up is safe: the
    // atomic write leaves the old file or the new one.
    static constexpr std::chrono::milliseconds kEndSessionFlush{3000};

private:
    // The content card, in points: right of the sidebar, inset on the other three sides
    // (BrowserWindowController's Layout.defaultSidebarWidth and ArcMetrics.Content.inset).
    static constexpr int kSidebarWidth = 240;
    static constexpr int kContentInset = 10;

    BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                            SessionWriter* writer, HistoryStores* history, std::unique_ptr<Renderer> renderer);
    std::wstring Init();
    // What follows from the selected space's theme at once: the title bar's dark mode, the
    // material under the backdrop, the caption buttons' glyphs (the Mac's NSAppearance).
    void ApplyAppearance(const Theme& theme);
    // The backdrop crossfades to `theme` with Arc's spring (the Mac's ThemeView.setTheme, in
    // core's ThemeCrossfade): interrupted before halfway, it carries on from the side that was
    // showing more.
    void SetTheme(const Theme& theme);
    // The Mac's sync(): the selected space's theme and appearance, and the pages' slide when
    // the space changed (SpaceSwipeController.spaceChanged).
    void SyncSpace();
    void SpaceChanged(size_t old, size_t now);
    void FinishSettling();
    // Whether a shortcut's command would do anything now (the Mac's validateMenuItem): Space n
    // for a space there isn't passes its key on.
    bool CommandEnabled(const std::string& command) const;
    // One frame of the clock's: the theme's crossfade drawn for the composition frame at
    // `time` (the pages' slide runs on the compositor).
    void Frame(double time);
    std::wstring DrawAt(double time, Pixels* readBack);
    // The smoke test's space switch, there and back, run to rest.
    std::wstring SmokeTestSpaces();
    // What the pages reported and Kite hasn't run yet (the window's close, at logoff, comes
    // with no WM_CLOSE first).
    void RunPending();

    // The session changed under the window: the sidebar and an open bar show it, and it's
    // saved after `save` (none: nothing that's saved changed, a page repeating its title).
    void StateChanged(std::optional<SessionSaveDelay> save = SessionSaveDelay::Soon);
    // The save timer fired, or the window is closing: a copy of the session to the writer.
    // `then` runs on the writer's thread after that write (SessionWriter::SaveThen).
    void SaveNow(std::function<void(const std::string& error)> then = {});
    // History changed (a visit, a title): its save timer, armed for the store due first.
    void ArmHistorySave();
    // The history a tab's visits go to: its own profile's (the Mac's history(forTab:)).
    HistoryStore* HistoryForTab(const std::string& tabID);
    // A page reported an address or a title: the Mac's pageURLChanged and pageTitleChanged.
    void RecordAddress(const std::string& tabID, const std::string& url);
    void RecordTitle(const std::string& tabID, const std::string& title);
    // The tab's page is gone (closed, discarded): its next address is a visit again.
    void ForgetRecorded(const std::string& tabID) { recordedURLs_.erase(tabID); }
    // The selected tab's page shows, and the sidebar with it, after the selection moved.
    void SelectionMoved();
    void ShowPage();
    void LoadInTab(const std::string& tabID, const std::string& url);
    // A tab left the session (closed, unloaded or archived): its page goes.
    void PageGone(const std::string& tabID);
    void BlockPages(bool blocked);
    // The Mac's newTab and openLocation.
    void OpenCommandBar(CommandBarMode mode);
    CommandBarView::Look BarLook() const;
    void Commit(const CommandSuggestion& row, CommandBarMode mode);
    // A tab's close button and Ctrl+W (the Mac's close(tab:)). The id by value: Ctrl+W's is the
    // tab's own, which closing erases.
    void CloseTab(std::string id);
    void ArchiveTab();
    void ReopenClosedTab();
    void MakeCommands();
    // Import from Arc (BrowserWindowControllerArcImport.cpp, the Mac's ArcImportController):
    // Arc's files are read on a worker, which posts kArcReadMessage when they're in.
    static constexpr UINT kArcReadMessage = WM_APP + 7;
    // The window's system menu item for it (Alt+Space): a WM_SYSCOMMAND id, under 0xF000.
    static constexpr UINT kImportFromArcMenuID = 0x0A10;
    // The writer's thread has written an import's session and its other files.
    static constexpr UINT kArcSavedMessage = WM_APP + 8;
    struct ArcJob;
    struct ArcSave;
    void ImportFromArc();
    void ReadArc(std::optional<std::filesystem::path> picked);
    void ArcRead();
    void ArcSaved();
    // As the window goes: asks a running read to stop and waits for it (a few seconds at most).
    void StopArcRead();
    void RunCommand(const std::string& command);
    bool PageCommand(const std::string& command);
    void DropCompositor();
    std::wstring Rebuild();
    void OnSize();
    bool Filter(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);
#ifdef KITE_HAS_CEF
    RECT ContentBounds() const;
    void ShowSelectedTab();
    void ShowFirstPage();
    Tab* TabNamed(const std::string& id);
#endif

    HINSTANCE instance_;
    BrowserState& state_;
    const ShortcutMap shortcuts_;
    const Options options_;
    SessionWriter* const writer_;
    HistoryStores* const history_;
    // The address each tab's page last recorded in history (the Mac's recordedURLs).
    std::map<std::string, std::string> recordedURLs_;
    SaveSchedule saveSchedule_;
    // What saving cost Kite's UI thread (the copy handed to the writer), for the save log.
    struct SaveCost {
        uint64_t saves = 0;
        double maxMicros = 0;
        double totalMicros = 0;
    };
    SaveCost saveCost_;
    // What recording a visit cost the UI thread, for the save log.
    struct HistoryCost {
        uint64_t visits = 0;
        double maxMicros = 0;
        double totalMicros = 0;
        void Add(double micros) {
            ++visits;
            maxMicros = std::max(maxMicros, micros);
            totalMicros += micros;
        }
    };
    HistoryCost historyCost_;
    struct LoggedSave {
        double at, micros;
        bool closing;
    };
    std::vector<LoggedSave> saves_;
    uint64_t saveArms_ = 0;  // times a change (re)armed the save timer (the smoke test checks it)
    double createdAt_ = 0;  // FrameClock::Now() when the window was made, for the save log
    bool closing_ = false;  // the window has begun to close (its session saved at once)
    // Destroyed in reverse: the views and the compositor before the window, the window before
    // Chromium (closing it destroys the browsers' windows, which Chromium's shutdown waits
    // for), and the GPU last.
    std::unique_ptr<Renderer> renderer_;
#ifdef KITE_HAS_CEF
    std::unique_ptr<Chromium> chromium_;
#endif
    MainWindow window_;
    // The backdrop's crossfade, from one theme to another (the same theme at rest), and the
    // colour under it: none over the system's acrylic, the solid material where there's none
    // (and in a capture).
    ThemeCrossfade theme_;
    // The composition frame the clock last drew for: a draw between its frames (a resize)
    // uses it, so the crossfade never steps back.
    std::optional<double> lastFrameTime_;
    float lastThemeProgress_ = 1;
    bool systemBackdrop_ = false;
    std::optional<bool> dark_;  // none until the first ApplyAppearance
    Rgba base_{};
    // The space the window shows (the Mac's shownSpaceID), and the pages' slide: the space it
    // left while they settle, whether the compositor is sliding them, and a slide that needs
    // its first commit.
    std::string shownSpaceID_;
    std::optional<std::string> pagesAnchor_;
    bool sidebarSliding_ = false;
    bool slideStarted_ = false;
    std::unique_ptr<Compositor> compositor_;
    std::unique_ptr<Favicons> favicons_;
    std::unique_ptr<SidebarView> sidebar_;
    std::unique_ptr<CaptionButtonsView> caption_;
    std::unique_ptr<CommandBarView> commandBar_;
    std::wstring barError_;
    // Frames while something animates (before the window in destruction: it posts to it).
    std::unique_ptr<FrameClock> clock_;
    // Low memory closes the background pages (before the window in destruction: it posts to it).
    std::unique_ptr<MemoryPressureWatch> memoryWatch_;
    bool watchingMemory_ = false;
    // The memory watch's reports, for the save log: when, and the level.
    struct PressureReport {
        double at;
        MemoryPressure level;
        bool discarded;  // the background pages were asked to close
    };
    std::vector<PressureReport> pressureReports_;
    struct LoggedFrame {
        double handled, target, offset, theme;
    };
    std::vector<LoggedFrame> frames_;
    size_t frameCount_ = 0;  // frames delivered, logged or not (the smoke test checks them)

    // What each shortcut's command does, by id (MainMenu.swift's items).
    std::map<std::string, std::function<void()>, std::less<>> commands_;
    // A shortcut ran from a key: the character Windows makes of that key isn't typed.
    bool dropCharacter_ = false;
    // Import from Arc's read: the worker (joined before the window goes) and what it hands back.
    std::thread arcThread_;
    std::shared_ptr<ArcJob> arcJob_;
    // An import whose session the writer hasn't written yet (kArcSavedMessage brings it back).
    std::shared_ptr<ArcSave> arcSave_;
    bool arcReading_ = false;  // from the command until the confirmation's answer
#ifdef KITE_HAS_CEF
    // Each open popup's tab and the tab that opened it (the Mac's PagePool.popupOpeners).
    std::map<std::string, std::string> popupOpeners_;
    bool firstPageMade_ = false;
    bool pageLoading_ = false, pageLoaded_ = false;
    ULONGLONG closeAskedAt_ = 0;  // when the smoke test asked the window to close
#endif
};

}  // namespace kite
