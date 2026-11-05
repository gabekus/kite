#pragma once
// The browser window and what's in it, as the Mac's BrowserWindowController: the backdrop,
// the sidebar, the caption buttons, the command bar, the pages (Chromium) and Kite's
// shortcuts, wired to the session (core/Models.h). main.cpp parses the command line, loads the
// session, and runs one of these. Like the Mac's BrowserWindowController+*.swift, its parts have
// files of their own: +Spaces.cpp (editing spaces: the space menu, renaming, deleting,
// reordering), +Chromium.cpp (the pages) and +Tests.cpp (--smoke-test and --capture).
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
#include "core/SidebarTopRow.h"
#include "core/SpaceEditing.h"
#include "core/SpaceSwipe.h"
#include "core/SpaceSwipeGesture.h"
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
#include "shell/TouchpadInput.h"

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
        // A quiet run (main.cpp's `quiet`, which alone decides it): the window opens behind
        // the others and never activates, the pages never take the focus or show a dialog
        // (Chromium::Start's `quiet`), and every shortcut command must do something.
        bool quiet = false;
        // --perf-control: WM_COPYDATA tagged perf::kControlTag runs a shortcut's command, logs a
        // mark, opens a tab or posts a pointer move (QueuePerfRequest). Test profiles only.
        bool perfControl = false;
        // --chromium-switches: added to Chromium's command line (test profiles only).
        std::vector<std::string> chromiumSwitches;
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
    // Starts Chromium for the window's pages, its profiles under `root`, with the sandbox the
    // bootstrap handed Kite.dll (RunWinMain). AlreadyRunning: another Kite has the profile and
    // was told to come forward.
    Chromium::StartResult StartChromium(const std::filesystem::path& root, void* sandboxInfo, std::wstring& error);
    // After the message loop: Chromium's shutdown, then what a smoke test checks of it. Empty
    // when it all went well (or there was no Chromium).
    std::wstring ShutDownChromium();
    // What a smoke test read of the sandbox (shell/Sandbox.h): the first page's renderer and
    // every helper, a line each; empty before the renderer reported.
    const std::wstring& SandboxReport() const { return sandboxReport_; }
#endif
    // Shows the window (behind other windows for a quiet run) and, with Chromium, the first page,
    // and starts the auto-archive's timer.
    void Show(int showCommand);

    // Draws the backdrop, the sidebar and the caption buttons and commits them; with
    // `readBack`, the backdrop's frame as presented. Rebuilds a lost GPU first.
    std::wstring Draw(Pixels* readBack = nullptr);
    // The animation frames of the run (Options::frameLog), one JSON object a line: `t` (when it
    // was handled, s from the first), `target` (the composition frame it was drawn for, s from
    // the first), `offset` (the pages', pt) and `theme` (the crossfade, 0...1); then
    // DirectManipulation's reports (`dm`: status or content, `t` on the clock's seconds). Empty
    // on success.
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
    // For a capture: two fingers over the sidebar have dragged its content `dx` points sideways
    // and are held there (the pages, the bar's light and the theme as they follow).
    std::wstring HoldSwipe(double dx);
    // For a capture: space `index`'s cell (from 0) pressed and dragged along the bar to `x` (bar
    // points), held there; with `drop`, let go there and settled (the space moved).
    std::wstring HoldSpaceDrag(size_t index, float x, bool drop);
    // For a capture: space `index`'s name being renamed in its header (Rename Space…), with
    // `text` typed over it when given; `focused` draws it as the window with the keyboard does
    // (a quiet capture's window never has it).
    std::wstring HoldRename(size_t index, const std::optional<std::string>& text, bool focused = false);
    // For a capture: what Capture composes over the frame next, space `index`'s menu opened
    // over its cell in the bar (Windows' own menu, read back as it shows).
    void HoldSpaceMenu(size_t index) { heldMenu_ = index; }
    // For a capture (which has no pages): the selected tab's page reporting `page`, as Chromium
    // would (back and forward, loading).
    void HoldPageStatus(const PageStatus& page);
    // For a capture: Toggle Sidebar run `times` times, each slide run to its end.
    std::wstring HoldSidebarToggles(int times);
    // For the smoke test: the pointer resting on a top-row button (a mouse move there, as the
    // pointer sends it).
    std::wstring HoldTopRowHover(TopRowButton button);

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
    // (BrowserWindowController's Layout.defaultSidebarWidth, and ArcMetrics.Content.inset in core's
    // sidebar_toggle::kContentInset).
    static constexpr int kSidebarWidth = 240;
    // The window's timers and posted messages. The timers' ids on this window, shared out across
    // the checkpoints so two never collide (the ones not in this branch yet are reserved):
    //   1 smoke, 2 archive, 3 settle, 4 session save (W11), 5 history (W25a), 6 Arc merge (W33a),
    //   7 sidebar toggle (W12), 8 downloads save (W20a).
    // 0x4B42 and up are the views' (the command bar's caret, Chromium's close deadline, the
    // sidebar's tip and drop, the rename field's caret). The WM_APP messages, each its own: +1
    // MainWindow::kWakeMessage, +2 the command bar's redraw, +3 the sidebar's redraw, +4 favicons,
    // +5 the frame clock, +6 space icons, +7 memory pressure (W11), +8 history, +9 Import from
    // Arc's read (kArcReadMessage), +10 arcSaved, +11 downloads, +20 perf. Filter checks that
    // neither the timers nor the messages it sees overlap.
    static constexpr UINT_PTR kSmokeTimer = 1;
    // The auto-archive's pass, every 15 minutes as on the Mac (AppDelegate's archiveTimer).
    static constexpr UINT_PTR kArchiveTimer = 2;
    static constexpr UINT kArchiveIntervalMs = 15 * 60 * 1000;
    // When the pages' slide on the compositor has ended (its duration and a frame, rounded up).
    static constexpr UINT_PTR kSettleTimer = 3;
    // The session's save, armed by a change (SaveSchedule) and gone once it fires: never idle.
    static constexpr UINT_PTR kSaveTimer = 4;
    // History's save (HistoryStores::NextSaveIn), armed by a change and gone once it fires.
    static constexpr UINT_PTR kHistoryTimer = 5;
    // (6 is Import from Arc's merge, kArcMergeTimer; 8 the downloads' save.)
    // When the sidebar's hide or show has ended on the compositor (the same allowance).
    static constexpr UINT_PTR kToggleTimer = 7;
    // View › Hide Sidebar in the window's system menu (Alt+Space, a right-click on the band above the
    // card) until Windows has a menu of Kite's own: a WM_SYSCOMMAND id, under 0xF000.
    static constexpr UINT kToggleSidebarMenuID = 0x0A20;
    // Posted by the favicon worker when icons arrive (Favicons.h).
    static constexpr UINT kFaviconsMessage = WM_APP + 4;
    // Posted by the frame clock once a composition frame while something animates.
    static constexpr UINT kFrameMessage = WM_APP + 5;
    static constexpr UINT kSpaceIconsMessage = WM_APP + 6;
    // Posted by the memory watch (MemoryPressure.h), wParam the MemoryPressure level.
    static constexpr UINT kMemoryPressureMessage = WM_APP + 7;
    // Posted by history's worker when a profile's file has been read (HistoryStores::SetWake).
    static constexpr UINT kHistoryMessage = WM_APP + 8;
    // --perf-control's queued requests (QueuePerfRequest).
    static constexpr UINT kPerfRequestMessage = WM_APP + 20;

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
    // Two fingers over the sidebar (the Mac's SpaceSwipeController): each touchpad event goes
    // through core's SpaceSwipeGesture, with the pointer `at` (client px) as it is then; a
    // swipe's pages, bar and theme follow it, and its release settles on a space, selected once
    // the pages are at rest (CommitLanding, which says how many pages the selection moved). A
    // vertical gesture scrolls the list under the pointer; one off the sidebar before it's the
    // swipe's goes back to the system, for whatever is under the pointer.
    SpaceSwipeGesture::Step SwipeInputArrived(const SwipeInput& input, POINT at);
    // Whether a point (client px) is over the sidebar with nothing over it: where a touchpad's
    // gesture is the sidebar's (the Mac's isOverSidebar).
    bool OverSidebar(POINT at) const;
    SwipeStart BeginSwipe();
    void ShowSwipe();
    void FinishSwipe(int landing);
    // The spaces changed under a swipe: it's dropped and the pages settle back (the Mac's cancel).
    void CancelSwipe();
    // The space index the swipe's neighbours point at towards `direction`, while they still hold
    // (SpaceSwipe::Neighbours::Target); none once the spaces changed under it.
    std::optional<size_t> SwipeSpace(int direction) const;
    std::vector<std::string> SpaceIDs() const;
    int CommitLanding();
    // Whether a shortcut's command would do anything now (the Mac's validateMenuItem): Space n
    // for a space there isn't passes its key on.
    bool CommandEnabled(const std::string& command) const;
    // One frame of the clock's: the touchpad's movement, then the theme's crossfade or a
    // swipe's step drawn for the composition frame at `time` (the pages' slide runs on the
    // compositor). `rateHz` is the display's, for --perf-log (0 when it isn't on).
    void Frame(double time, double rateHz);
    std::wstring DrawAt(double time, Pixels* readBack);
    // The smoke test's space switch, there and back, run to rest.
    std::wstring SmokeTestSpaces();
    // The smoke test's swipes, fed to SwipeInputArrived as a touchpad's events would be.
    std::wstring SmokeTestSwipe();
    // Its cases that need three spaces (one is added for them, then removed): a keyboard switch
    // overtaking a landing, a space selected under the swipe, and the boost of a fade ending
    // while the touchpad's frames go on. And with one space (the others set aside meanwhile).
    std::wstring SmokeTestSwipeThreeSpaces();
    std::wstring SmokeTestSwipeOneSpace();
    // The smoke test's space edits: drags in the bar that move a space and bring it back and one
    // let go off the strip, the menu's items, a rename committed, one cancelled and one left,
    // New Folder and Delete Space, all undone after.
    std::wstring SmokeTestSpaceEditing();
    // Runs the timer a drop's landing waits on until the space has moved (2 s at most).
    std::wstring WaitForDrop();
    // The clock's frames and the slide's timer, until the theme and the pages are at rest.
    std::wstring RunToRest(const wchar_t* what);
    // The clock's frames and the window's timers until `done` (or `seconds` go by): whether it was.
    bool RunUntil(const std::function<bool()>& done, double seconds);
    // A slide's first frame now: the pages' drawing and the strip's animation committed, so the
    // compositor's timeline starts where PageOffset reads it from.
    void CommitSlide();
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
    // MARK: Editing spaces (BrowserWindowController+Spaces.cpp)
    // A right-click on a space's cell or header: its menu at `screen` (px), then what it chose.
    void ShowSpaceMenu(const std::string& spaceID, POINT screen);
    // What the menu shows for a space, as it opens (a rename open ends first).
    std::vector<SpaceMenuItem> OpenSpaceMenu(const std::string& spaceID);
    void RunSpaceMenuItem(const std::string& spaceID, SpaceMenuItem::Command command);
    // The Mac's beginRenaming(space:): that space selected, its header's name field open with
    // the name all selected. Return or Done renames it, Escape leaves it.
    void BeginRenaming(const std::string& spaceID);
    void RenameSpace(const std::string& spaceID, const std::string& name);
    // Delete Space (the Mac's deleteSpace(_:)): a beep for the last space, at once for one with
    // no tabs, else after asking; its pages close with it.
    void DeleteSpace(std::string spaceID);
    // A space dropped in the bar at `index` among the others (the Mac's moveSpace).
    void MoveSpace(const std::string& spaceID, size_t index);
    void ArchiveTab();
    void ReopenClosedTab();
    // View › Hide Sidebar and Show Sidebar (the Mac's toggleSidebar and updateSidebar): the sidebar
    // slides off the window's left edge (or back) on the compositor and the card's leading edge goes
    // from the sidebar's edge to the inset (or back). The page is a child window, which no compositor
    // property moves until W10's off-screen pages, so it moves once: as a show begins, and as a hide
    // ends (ContentBounds keeps the sidebar's edge until then). Chromium moves it on CEF's thread, so
    // it lands a little after that. A rename in the header ends first, keeping what was typed. The
    // slide boosts the compositor clock while it runs, and the system menu's item is retitled.
    void ToggleSidebar();
    void SetSidebarShown(bool shown);
    void FinishToggle();
    // The width the sidebar takes from the window: none while it's hidden.
    float SidebarShownWidth() const { return sidebarShown_ ? static_cast<float>(kSidebarWidth) : 0.0f; }
    void MovePage();
    // The system menu's item: Hide Sidebar or Show Sidebar, a tab, and its shortcut as bound.
    std::wstring ToggleSidebarMenuText() const;
    // The selected tab's page's status, to the top row (none for a tab with no page).
    void ShowPageStatus();
    // The smoke test's top row: its buttons, the page's states, a hover that draws nothing, a press
    // on a disabled button, and hiding and showing the sidebar from the toggle and Ctrl+S's command.
    std::wstring SmokeTestTopRow();
    void MakeCommands();
    // Import from Arc (BrowserWindowControllerArcImport.cpp, the Mac's ArcImportController):
    // Arc's files are read on a worker, which posts kArcReadMessage when they're in.
    // The window's WM_APP ids are listed above, with kSmokeTimer.
    static constexpr UINT kArcReadMessage = WM_APP + 9;
    // The window's system menu item for it (Alt+Space): a WM_SYSCOMMAND id, under 0xF000.
    static constexpr UINT kImportFromArcMenuID = 0x0A10;
    // The writer's thread has written an import's session and its other files.
    static constexpr UINT kArcSavedMessage = WM_APP + 10;
    // The next profile's history merge: a one-shot timer, since WM_TIMER comes only once input,
    // paint and posted messages are done, so the window answers between profiles.
    static constexpr UINT_PTR kArcMergeTimer = 6;
    struct ArcJob;
    struct ArcSave;
    void ImportFromArc();
    void ReadArc(std::optional<std::filesystem::path> picked);
    void ArcRead();
    void ArcSaved();
    // As the window closes: an import the writer has reported back on gets the rest of its
    // history merged at once. One it hasn't reported on yet (its session still being written)
    // keeps its spaces and side files, and its history isn't merged.
    void FinishArcImport();
    // As the window goes: asks a running read to stop and waits for it (a few seconds at most).
    void StopArcRead();
    void RunCommand(const std::string& command);
    bool PageCommand(const std::string& command);
    void DropCompositor();
    std::wstring Rebuild();
    void OnSize();
    bool Filter(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);
    // One --perf-control request, a UTF-8 JSON object: {"command":ID[,"qpc":Q]} runs a shortcut's
    // command (the input→present clock starting at Q, the harness's send), {"mark":NAME} logs a
    // mark, {"open":URL} opens an http or https URL in a tab and shows it (the command bar's
    // Open), {"input":"move","x":X,"y":Y,"qpc":Q} posts a pointer move to the window at client
    // px (X, Y), and {"input":"leave"} the pointer's leaving. Checked here and queued, then run
    // from the message loop (RunPerfRequests), so the sender isn't held while it runs and its
    // dispatch is timed like any other. False when it isn't one, or the command does nothing now.
    struct PerfRequest {
        enum class Kind { Command, Mark, Open, Move, Leave } kind;
        std::string text;
        int64_t x = 0, y = 0, qpc = 0;
    };
    bool QueuePerfRequest(const COPYDATASTRUCT* data);
    void RunPerfRequests();
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
    // The swipe's: the space a release landed on, selected when the pages come to rest, and
    // that selection under way.
    SpaceSwipeGesture swipe_;
    struct Landing {
        std::string spaceID;
        int pages;
    };
    std::optional<Landing> pendingLanding_;
    // The spaces the swipe began between, by id.
    std::optional<SpaceSwipe::Neighbours> swipeNeighbours_;
    bool selectingBySwipe_ = false;
    bool swipeMoved_ = false;  // since the clock's last frame drew
    std::unique_ptr<Compositor> compositor_;
    std::unique_ptr<Favicons> favicons_;
    std::unique_ptr<SidebarView> sidebar_;
    // View › Hide Sidebar's state (the Mac's BrowserStore.isSidebarVisible, not saved: a launch
    // shows it), and its slide under way.
    bool sidebarShown_ = true;
    bool toggling_ = false;
    // What each tab's page last reported (the Mac's BrowserStore.pages), gone with its page.
    std::map<std::string, PageStatus> pageStatus_;
    std::unique_ptr<CaptionButtonsView> caption_;
    std::unique_ptr<CommandBarView> commandBar_;
    std::wstring barError_;
    // Frames while something animates (before the window in destruction: it posts to it).
    std::unique_ptr<FrameClock> clock_;
    // A precision touchpad's gestures over the sidebar (null where there's no DirectManipulation,
    // and once the window closes: it lets the window go while it's still a window).
    std::unique_ptr<TouchpadInput> touchpad_;
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
    std::vector<std::string> touchpadLog_;  // TouchpadInput::log's records, after the frames
    size_t touchpadLogDropped_ = 0;          // and how many didn't fit (kMaxTouchpadLog)
    std::wstring touchpadError_;            // why there's no touchpad_, when there isn't one
    // --perf-control's pointer is over the window: the system's WM_MOUSELEAVE (the real pointer
    // is elsewhere) doesn't take its hover away.
    bool perfPointer_ = false;
    size_t perfMovesPosted_ = 0, perfLeavesPosted_ = 0;  // posted and not yet received
    std::vector<PerfRequest> perfRequests_;
    size_t frameCount_ = 0;  // frames delivered, logged or not (the smoke test checks them)

    // A capture's space menu, composed over the frame (HoldSpaceMenu).
    std::optional<size_t> heldMenu_;
    // Delete Space's question for a space with tabs: the task dialog; never a dialog in a test
    // run (it answers Cancel, unless the smoke test answers).
    std::function<bool(const SpaceDeletion&)> askToDelete_;

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
    // A smoke test's check of the first page's renderer (shell/Sandbox.h): whether one reported
    // in, what was wrong with its sandbox and the helpers' (empty when nothing was), and what
    // they were.
    bool rendererChecked_ = false;
    std::wstring rendererProblem_, helperProblem_, sandboxReport_;
    void CloseWhenSmokeTestIsDone();
    ULONGLONG closeAskedAt_ = 0;  // when the smoke test asked the window to close
    // The smoke test's read of Chromium's Energy Saver preference (Chromium::ReadEnergySaver).
    bool energySaverRead_ = false;
    std::optional<int> energySaverState_;
#endif
};

}  // namespace kite
