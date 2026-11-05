#pragma once
// The browser window and what's in it, as the Mac's BrowserWindowController: the backdrop,
// the sidebar, the caption buttons, the command bar, the find bar, the pages (Chromium)
// and Kite's shortcuts, wired to the session (core/Models.h). main.cpp parses the command line, loads the
// session, and runs one of these. Like the Mac's BrowserWindowController+*.swift, its parts have
// files of their own: +Spaces.cpp (editing spaces: the space menu, renaming, deleting,
// reordering), +NewSpace.cpp (the + menu, Create a Space and Choose a Theme's swatches), +Tabs.cpp (pinning, renaming tabs and folders, New Folder, Duplicate, Back to Pinned
// URL, Reset), +SidebarMenus.cpp (the rows' and favorites' menus), +Chromium.cpp (the pages)
// and +Tests.cpp (--smoke-test and --capture).
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
//
// Downloads (W20a) go the same way, as the Mac's DownloadsModel: Chromium's reports go through
// core/DownloadsModel.h's rules, and downloads.json is written by the caller's DownloadsWriter
// (read on its worker at launch, then each save), 0.2 s after a download starts or finishes and
// 5 s after a progress tick. Nothing on screen shows them yet (the Library comes with W20b), so a
// report redraws nothing. Closing the window with downloads running asks first ("Downloads in
// progress", shell/QuitDialog.h), as the Mac's applicationShouldTerminate.

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "core/DownloadsModel.h"
#include "core/DownloadsWriter.h"
#include "core/HistoryStore.h"
#include "core/KeyBindings.h"
#include "core/LiveTabPolicy.h"
#include "core/Models.h"
#include "core/OneShotFlags.h"
#include "core/SessionSaveDelay.h"
#include "core/SessionWriter.h"
#include "core/SidebarContextMenu.h"
#include "core/SidebarTopRow.h"
#include "core/SpaceCreation.h"
#include "core/SpaceEditing.h"
#include "core/SpaceSwipe.h"
#include "core/SpaceSwipeGesture.h"
#include "core/ThemeBackdrop.h"
#include "core/TitleBar.h"
#include "shell/CaptionButtonsView.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/CommandBarView.h"
#include "shell/Compositor.h"
#include "shell/ContextMenu.h"
#include "shell/Favicons.h"
#include "shell/FindBarView.h"
#include "shell/FrameClock.h"
#include "shell/MainWindow.h"
#include "shell/MemoryPressure.h"
#include "shell/Occlusion.h"
#include "shell/Renderer.h"
#include "shell/SidebarView.h"
#include "shell/SpaceIconPickerView.h"
#include "shell/ThemeSwatchesView.h"
#include "shell/TouchpadInput.h"

namespace kite {

class BrowserWindowController {
public:
    struct Options {
        // A --capture run: the solid material under the backdrop (not what's behind the
        // window), no favicons (no network) unless `captureFavicons`, and no auto-archive. The
        // caller doesn't start Chromium for one.
        bool capture = false;
        // --capture --favicons: the favicons fetched as the window fetches them (WaitForFavicons).
        bool captureFavicons = false;
        // --smoke-test: every shortcut command must do something, and the first page's load
        // closes the window.
        bool smokeTest = false;
        // --frame-log: each frame the clock delivered (when it was handled, the time it was
        // drawn for, the pages' offset and the theme's crossfade) is kept for SaveFrameLog.
        bool frameLog = false;
        // A quiet run (main.cpp's `quiet`, which alone decides it): the window opens behind
        // the others and never activates, the pages never take the focus or show a dialog
        // (Chromium::Start's `quiet`), and every shortcut command must do something.
        bool quiet = false;
        // Where downloads go for a profile that chose no folder (core/ProfileSettings.h's
        // DefaultDownloadFolder: a test run's own folder, never the user's Downloads).
        std::filesystem::path downloadFolder;
        // --save-log on a test profile only (KITE_TEST_CLOSE_TAB_MS): this long after the window
        // shows, the shown page gets a click's user activation, and its tab closes 0.5 s later, as
        // its close button would.
        std::optional<unsigned> testCloseTabMs;
        // --save-log on a test profile only (KITE_TEST_AUTOMATIC_DOWNLOADS=ORIGIN, a local test
        // server): its pages may start many downloads with no click, for the live check of a burst.
        std::optional<std::string> testAutomaticDownloads;
        // --save-log: each save handed to the writer (when, and what it cost the UI thread) is
        // kept for SaveSaveLog.
        bool saveLog = false;
        // --perf-control: WM_COPYDATA tagged perf::kControlTag runs a shortcut's command, logs a
        // mark, opens a tab or posts a pointer move (QueuePerfRequest). Test profiles only.
        bool perfControl = false;
        // --chromium-switches: added to Chromium's command line (test profiles only).
        std::vector<std::string> chromiumSwitches;
        // --occlusion-log: shell/Occlusion's verdicts, a JSON line each (empty: none).
        std::filesystem::path occlusionLog;
        // The profile's SpaceIcons folder: the pictures chosen as space icons (a capture
        // decodes them in place, the rest on a worker).
        std::filesystem::path spaceIcons;
        // The profile's folder: where its one-shot flags are (OneShotFlags.h), and where Import
        // from Arc puts its shortcut changes and routes.
        std::filesystem::path supportDirectory;
    };

    // The window and everything in it, laid out and wired, not yet shown or drawn. Null with
    // `error` when the GPU, the window or a view couldn't be made. No command bar isn't a
    // failure (CommandBar() is null then). `writer` (the caller's, outliving the window) gets
    // the session as it changes, and once more as the window closes, and at logoff or shutdown,
    // after the pages' last reports; null saves nothing. `history` (the caller's too) gets the
    // pages' visits and gives the command bar its history rows; null records nothing. `downloads`
    // (the caller's too) reads downloads.json at once, on its worker, and writes the list as it
    // changes; null keeps none.
    static std::unique_ptr<BrowserWindowController> Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                           Options options, SessionWriter* writer, HistoryStores* history,
                                                           DownloadsWriter* downloads,
                                                           std::wstring& error);
    ~BrowserWindowController();
    BrowserWindowController(const BrowserWindowController&) = delete;
    BrowserWindowController& operator=(const BrowserWindowController&) = delete;

    MainWindow& Window() { return window_; }
    CommandBarView* CommandBar() { return commandBar_.get(); }
    FindBarView* FindBar() { return findBar_.get(); }
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
    // and starts the auto-archive's timer and the read of downloads.json (only once this launch
    // is Kite's: a second one that hands over touches no file).
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
    // clock delivered), `writer` (the writer's statistics after its last write) and
    // `downloads` (Chromium's reports, those that reached Kite's thread and what each cost it,
    // the list's saves and its writer's statistics). Empty on success.
    std::wstring SaveSaveLog(const std::filesystem::path& file) const;
    // The smoke test's checks of the window: the command bar opens and draws, the sidebar and
    // the caption buttons draw something, and the lost-GPU path rebuilds and draws. Empty on
    // success. Then the window closes once the first page has loaded (30 s at most), or after
    // a second without Chromium. The frame clock's own thread is checked first; the rest steps
    // the clock's frames itself (FrameClock::SetManual), so its checks don't hang on the display.
    std::wstring SmokeTest();
    // The window's frame as the screen shows it: the backdrop with the sidebar, the caption
    // buttons and (with `barText`) the command bar opened with that text, composed over it.
    // With `find`, the find bar open over the card with that query typed, and `findResult` as the
    // page's report on it (a capture runs without Chromium; none leaves the counter empty).
    struct CaptureFind {
        std::string query;
        std::optional<FindResult> result;
    };
    std::wstring Capture(Pixels& pixels, const std::optional<std::string>& barText, std::optional<size_t> tip = std::nullopt,
                         const std::optional<CaptureFind>& find = std::nullopt);
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
    // For a capture: Change Space Icon…'s picker open for space `index` (from 0, selected first)
    // on `tab`, chosen with a click on its segment, and on the Emoji tab `category` chosen in the
    // bar; with `cell`, that cell clicked (its icon set) and the picker closed with Escape.
    std::wstring HoldIconPicker(size_t index, IconPickerTab tab, std::optional<size_t> cell = std::nullopt,
                                std::optional<size_t> category = std::nullopt);
    // For a capture: what Capture composes over the frame next, space `index`'s menu opened
    // over its cell in the bar (Windows' own menu, read back as it shows).
    void HoldSpaceMenu(size_t index) { heldMenu_ = index; }
    // For a capture: the bar's + menu opened over its button, as a click on it opens it (Windows'
    // own menu, read back as it shows); its line goes to stderr.
    void HoldNewItemMenu() { heldNewItemMenu_ = true; }
    // For a capture: + › New Space's Create a Space page, with `name` and `about` typed in its
    // fields, and with `preset`, Choose a Theme's swatches opened and that one clicked (they stay
    // open, as the Mac's popover does), the theme's crossfade run to its end.
    std::wstring HoldCreateSpace(const std::string& name, const std::string& about, std::optional<size_t> preset);
    // For a capture: row `index`'s menu (from 0, as kitecore's `sidebar` lists the selected space's
    // rows; a tab's or a folder's: the header's is the space's, which HoldSpaceMenu holds), or
    // favorite pane `index`'s (in the grid's order), opened as a right-click on its middle opens it.
    // Its line goes to stderr, as the Mac's KITE_TEST_CONTEXT_MENU logs one.
    std::wstring HoldRowMenu(size_t index);
    std::wstring HoldFavoriteMenu(size_t index);
    // Capture's part: the held row menu read back and composed over `pixels`.
    std::wstring RenderHeldRowMenu(Pixels& pixels);
    // For a capture (which has no pages): the selected tab's page reporting `page`, as Chromium
    // would (back and forward, loading).
    void HoldPageStatus(const PageStatus& page);
    // For a capture: Toggle Sidebar run `times` times, each slide run to its end.
    std::wstring HoldSidebarToggles(int times);
    // For the smoke test: the pointer resting on a top-row button (a mouse move there, as the
    // pointer sends it).
    std::wstring HoldTopRowHover(TopRowButton button);
    // For a capture: the pointer resting on favorite pane `index` (from 0, in the grid's order),
    // or a click on it (pressed and let go there, as the pointer sends them).
    std::wstring HoldFavoriteHover(size_t index);
    std::wstring ClickFavorite(size_t index);
    // For a capture: the pointer resting on the favorites' empty state, its close button showing.
    std::wstring HoldEmptyFavoritesHover();
    // For a capture: row `index` (from 0, as kitecore's `sidebar` lists the selected space's rows)
    // renamed in place, a tab's or a folder's, with `text` typed over its name when given and drawn
    // with the keyboard when `focused`; the pointer resting on row `index`; and a command run by its
    // id as its shortcut runs it (Pin Tab on the selected tab, say).
    std::wstring HoldRowRename(size_t index, const std::optional<std::string>& text, bool focused = false);
    std::wstring HoldRowHover(size_t index);
    std::wstring RunCommandForCapture(const std::string& command);
    // For a --favicons capture: the sidebar's favicons (and the 16px icons the favorites' colours
    // come from) fetched and decoded, drawing as they come, for at most `seconds`. `failed` gets
    // the favorites' favicons that didn't load (they show the globe, as the Mac's do).
    std::wstring WaitForFavicons(double seconds, std::vector<std::string>& failed);

    // Runs messages until WM_QUIT, rebuilding the GPU when its device is removed.
    void RunMessageLoop();

    // The session changed outside the window's own handlers (main.cpp's auto-archive at
    // launch): it's saved after `delay`, as the window's own changes are.
    void SessionChanged(SessionSaveDelay delay = SessionSaveDelay::Soon);

    // After the message loop: a downloads.json read that hadn't reached the window yet is
    // waited for (until `deadline`, quitting's one deadline) and joined, and the list's last
    // save handed over (the window's close hands it over itself when the read was in). The
    // caller then flushes.
    void FinishDownloads(std::chrono::steady_clock::time_point deadline);

    // What's left of `deadline`, for a wait that takes milliseconds.
    static std::chrono::milliseconds Left(std::chrono::steady_clock::time_point deadline);

    // How long the window waits for the session's, history's and downloads.json's last writes,
    // together, when Windows ends the session (WM_ENDSESSION: the process may end as soon as it
    // returns). Giving up is safe: the atomic write leaves the old file or the new one.
    static constexpr std::chrono::milliseconds kEndSessionFlush{3000};

private:
    // The content card, in points: right of the sidebar, inset on the other three sides
    // (BrowserWindowController's Layout.defaultSidebarWidth, and ArcMetrics.Content.inset in core's
    // sidebar_toggle::kContentInset).
    static constexpr int kSidebarWidth = title_bar::kSidebarWidth;
    // The window's timers and posted messages. The timers' ids on this window, shared out across
    // the checkpoints so two never collide (the ones not in this branch yet are reserved):
    //   1 smoke, 2 archive, 3 settle, 4 session save (W11), 5 history (W25a), 6 Arc merge (W33a),
    //   7 sidebar toggle (W12), 8 downloads save (W20a), 9 test tab close, 10 find (W21),
    //   11 Chromium::kStallTimer (the parked pages' stall check), 12 Change Space Icon…'s 0.15 s (W9e).
    // 0x4B42 and up are the views' (the command bar's caret, Chromium's close deadline, the
    // sidebar's tip and drop, the rename field's caret, the find field's caret at 0x4B47, the icon picker's at 0x4B49 (W9e), Create a Space's name and about fields' carets at 0x4B4A and 0x4B4B (W9f)). The WM_APP messages, each its own: +1
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
    // downloads.json's save, armed by a change (DownloadsSaveSchedule) and gone once it fires.
    static constexpr UINT_PTR kDownloadsSaveTimer = 8;
    // --save-log on a test profile with KITE_TEST_CLOSE_TAB_MS: the shown page gets a click's user
    // activation, and half a second later its tab closes, as its close button would (the live check
    // of a page kept for its downloads, and of its Leave Page). Test runs only. (10 is W21's find,
    // 11 Chromium::kStallTimer, the parked pages' stall check.)
    static constexpr UINT_PTR kTestCloseTabTimer = 9;
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
    // Change Space Icon… from the space's menu: the picker opens 0.15 s after it closes, on the
    // space it selected (the Mac's openPicker(after: 0.15)). The next id after the others' (the
    // list above; Filter checks none overlap).
    static constexpr UINT_PTR kIconPickerTimer = 12;
    // Posted by history's worker when a profile's file has been read (HistoryStores::SetWake).
    static constexpr UINT kHistoryMessage = WM_APP + 8;
    // Posted by shell/Occlusion when its verdict changes (the shared WM_APP allocation gives P2 +12).
    static constexpr UINT kOcclusionMessage = WM_APP + 12;
    // Posted by the downloads writer's worker once it has read downloads.json.
    static constexpr UINT kDownloadsReadMessage = WM_APP + 11;
    // --perf-control's queued requests (QueuePerfRequest).
    static constexpr UINT kPerfRequestMessage = WM_APP + 20;

    BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                            SessionWriter* writer, HistoryStores* history, DownloadsWriter* downloads,
                            std::unique_ptr<Renderer> renderer);
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
    // The pages start or stop sliding on the compositor, the compositor clock boosted meanwhile.
    void SetSliding(bool sliding);
    // Two fingers over the sidebar (the Mac's SpaceSwipeController): each touchpad event goes
    // through core's SpaceSwipeGesture, with the pointer `at` (client px) as it is then; a
    // swipe's pages, bar and theme follow it, and its release settles on a space, selected once
    // the pages are at rest (CommitLanding, which says how many pages the selection moved). A
    // vertical gesture decided over the list scrolls it to its end, wherever the pointer goes; one
    // off the sidebar before it's decided goes back to the system, for whatever is under the
    // pointer.
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
    // Whether anyone can see the window: shown, not minimized, and not hidden by shell/
    // Occlusion (covered, locked, display off, another desktop). What animates on screen
    // (the crossfade, the pages' slide) runs only while it is.
    bool Seen() const;
    // shell/Occlusion's verdict changed: while the window can't be seen, its page is hidden
    // (Chromium stops drawing it) and a crossfade lands at once, as the Mac's ThemeView skips
    // it for an occluded window.
    void OcclusionChanged();
    void SetOccluded(bool hidden);
    // Watching whether the window can be seen, or not: on from the start but for test runs;
    // under --perf-control only while kiteperf asks ({"occlusion":"on"}, its covered phase).
    void StartOcclusion();
    void StopOcclusion();
    // A window of Kite's process is the foreground window.
    bool KiteInFront() const;
    // The frame clock stops for an unseen window, unless something that isn't drawing still
    // needs its frames.
    void StopFrameClockUnseen();
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
    // Kite's count of compositor boosts held matches this window's holders that are on.
    bool BoostsBalance() const;
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
    // Downloads (the Mac's DownloadsModel and DownloadLocation).
    // Chromium's report, through the model's rules; what it cost the UI thread is kept for the
    // save log.
    void DownloadUpdated(const DownloadUpdate& update);
    // Arms the downloads.json timer, for `seconds` (none: leaves it as it is).
    void DownloadsChanged(std::optional<double> seconds);
    // The timer fired, or the window is closing: a copy of the list to the writer.
    void SaveDownloadsNow();
    // Asks the writer's worker for downloads.json; it posts here once it has it.
    void ReadDownloads();
    // The worker's read of downloads.json has arrived: it joins the list.
    void DownloadsRead();
    // Each profile's download settings, by folder, for Chromium (DownloadLocation's provider).
    std::map<std::string, ProfileSettings> DownloadLocations() const;
    // Whether the window may close: with downloads running, "Downloads in progress" asks
    // first; Close Kite cancels them (the Mac's applicationShouldTerminate).
    bool MayQuit();

    // The selected tab's page shows, and the sidebar with it, after the selection moved.
    void SelectionMoved();
    void ShowPage();
    void LoadInTab(const std::string& tabID, const std::string& url);
    // A tab left the session (closed, unloaded or archived): its page goes.
    void PageGone(const std::string& tabID);
    void BlockPages(bool blocked);
    // The Mac's newTab and openLocation.
    void OpenCommandBar(CommandBarMode mode);
    // Find in page (BrowserWindowController+PageCommands.swift): Ctrl+F opens the bar over the
    // shown page and focuses its field, or beeps with no page; Ctrl+G and Ctrl+Shift+G step through
    // the matches, or open the bar when it's closed or empty.
    void ShowFind();
    void StepFind(bool forward);
    // The page's search (an empty text: stop).
    void FindInPage(const FindQuery::Search& search);
    // Closes the bar and ends the search; with `focusPage` (Esc, close) the page takes the keyboard.
    void HideFindBar(bool focusPage);
    // The shown tab changed (another tab, or none): the bar closes with it, as the Mac's
    // findBarLeavesTab does without a conversation.
    void FindBarFollowsSelection();
    // The page's hole under the bar, and whether the page may take the keyboard on a navigation.
    // Whatever moves the content card calls findBar_->SetCard and then this: OnSize and the
    // sidebar's toggle (MovePage) do, and split view must too.
    void UpdateFindHole();
    // The app's appearance (the session's pageAppearance, else the system's apps' mode).
    bool FindBarDark() const;
    // The icon picker's and Choose a Theme's popovers: Kite's appearance, as NSPopover's.
    bool PopoverDark() const;
    // Which of Kite's fields has the keyboard (Windows has one system caret a thread, and the
    // Mac one first responder a window): the command bar's while it's open, else a rename's, else
    // the find bar's, else the icon picker's Search, else Create a Space's fields', else none (the
    // page's). GiveKeyboard takes it from the others before `to` takes it, so their carets go
    // first: opening the command bar takes it from all of them, a rename from the find field and
    // the page's fields, and Ctrl+F or a press in the find field ends a rename. The icon picker's
    // Search has it from Change Space Icon…'s request (the menu's 0.15 s included) until the picker
    // closes; anything else taking it closes the picker. Choose a Theme's swatches have it while
    // they're open (the Mac's popover is the key window), handing it back to the page's field that
    // had it when Escape closes them; anything else taking it closes them. Create a Space's name
    // field takes it as its page appears (and a press in either field), closing the command bar and
    // the popovers, as Ctrl+F does.
    enum class KeyboardField { None, CommandBar, Rename, Find, IconPicker, ThemeSwatches, Creation };
    KeyboardField KeyboardOwner() const;
    // With `focusField` false (a press in it), the find field or Create a Space's takes it itself,
    // the caret where the press is (and the caller updates the page's keyboard after); else the
    // find field's text is all selected, or Create a Space's name field focused (onAppear).
    void GiveKeyboard(KeyboardField to, bool focusField = true);
    // The content card in client px (the page's bounds).
    RECT ContentBounds() const;
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
    // no tabs, else after asking; its pages close with it. Create a Space's own space cancels it.
    void DeleteSpace(std::string spaceID);
    // MARK: New Space (BrowserWindowController+NewSpace.cpp)
    // The bar's + button: its menu (the Mac's NewItemMenu) over it, its bottom's middle at
    // `screen` (px), then what it chose.
    void ShowNewItemMenu(POINT screen);
    void RunNewItem(NewItemMenuItem::Command command);
    // Its items as Windows' menu shows them (shell/ContextMenu), one entry an item.
    static std::vector<ContextMenuEntry> NewItemEntries(const std::vector<NewItemMenuItem>& items);
    // + › New Space and the newSpace command (the Mac's BrowserStore.beginNewSpace): the sidebar
    // shown, a nameless space right after this one, selected, and Arc's Create a Space page in
    // its sidebar with the name field's keyboard; with one open already, its space again.
    void BeginNewSpace();
    // Create Space or Return (finishNewSpace) with a name; Cancel or Escape (cancelNewSpace).
    void FinishNewSpace(const std::string& name, const std::string& about);
    void CancelNewSpace();
    // Choose a Theme: the theme editor's swatches off `row` (window points); a swatch picked; and
    // the popover closing (Escape, a press elsewhere, the window losing the keyboard or moving).
    void ShowThemeSwatches(const BarRect& row);
    void PickSpaceTheme(size_t preset);
    // `handBack`: Escape's close, which gives the keyboard back to the page's field that had it
    // (else to the page, from the window in front); a press, a deactivation or a move hands nothing.
    void CloseThemeSwatches(bool handBack = false);
    // The swatches no longer hold the keyboard (their closed callback, every way they close).
    void ReleaseSwatchesKeyboard(bool handBack);
    // Create a Space's `field` takes the keyboard, as a rename does (TakeKeyboardForRename): from the
    // others first, then the field, then the window's focus when it's in front.
    void TakeKeyboardForCreation(SpaceCreationView::Field field, bool selectAll = false);
    // The page's profile pill: the profiles, at `screen` (px), the one picked set for its space.
    void ShowCreationProfileMenu(POINT screen);
    // After any change, once the sidebar shows it (StateChanged): the page appearing gives the name
    // field the keyboard (onAppear), and it going gives the keyboard back to the page and closes
    // the swatches.
    void FollowCreation();
    // The smoke test's: the + menu read and New Space from it, the page's typing drawing only its
    // field, a theme picked, Create (Return and the button) and Cancel (Escape and the button), the
    // ways the keyboard moves, and New Space from its command.
    std::wstring SmokeTestNewSpace();
    // A space dropped in the bar at `index` among the others (the Mac's moveSpace).
    void MoveSpace(const std::string& spaceID, size_t index);
    // Change Space Icon… (the Mac's requestIconPicker): the space selected, then its header's
    // picker, at once from the header's icon or 0.15 s on from the menu.
    void RequestIconPicker(const std::string& spaceID, bool fromMenu);
    // The picker for the selected space `spaceID`, hanging from its header's icon.
    void ShowIconPicker(const std::string& spaceID);
    // A cell or the bin (the picker's pick): the icon set, the picture it replaced deleted.
    void PickIcon(const std::string& spaceID, const std::string& icon);
    // `focusPage` false: a close caused by a press, a deactivation, a move or a minimize, after
    // which the keyboard isn't handed to the page (onFocus does that when the window comes back).
    void CloseIconPicker(bool focusPage = true);
    // The picker no longer holds the keyboard. With `focusPage`, when nothing of Kite's has it and
    // Kite's window is the one in front (unless another field is taking it now), the page gets it.
    void ReleaseIconPickerKeyboard(bool focusPage = true);
    // The smoke test's icon picker: opened from the menu and the header's icon, an emoji, a
    // search, a category, a symbol and the bin picked, and the ways it closes.
    std::wstring SmokeTestIconPicker();
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
    // The smoke test's tab edits: Pin Tab and back, a tab renamed from its row's double-click (a
    // keystroke drawing only the field) and from Rename Current Tab…, a folder renamed, New Folder,
    // Duplicate, Back to Pinned URL from its button and Reset all tabs, all undone after.
    std::wstring SmokeTestTabEditing();
    // The smoke test's middle clicks: one on a Today tab's row closes it and its page, one moved off
    // the row closes nothing, a pinned tab's unloads (its row stays, its page goes), and one on a
    // favorite does nothing.
    std::wstring SmokeTestMiddleClick();
    // Back to Pinned URL on the shown (live) page: the selected tab pinned, its page sent elsewhere,
    // then reset, waiting for the page to report it's home; unpinned again after.
    std::wstring SmokeTestLiveReset();
    std::wstring SmokeTestFavorites();
    std::wstring SmokeTestEmptyFavorites();
    std::wstring SmokeTestFavoritesScroll();
    // The smoke test's checks, the clock's frames stepped by RunUntil.
    std::wstring SmokeTestWindow();
    // MARK: Tabs (BrowserWindowController+Tabs.cpp)
    // Every tab edit a command or a click makes: the change, then the window shows it (with
    // `selectionMoved`, the newly selected tab's page too). RecordEdit is the change alone, where
    // W16's undo records the step, as the Mac's BrowserStore.mutate registers one for every change
    // (a rename that ends inside StateChanged's update goes through it alone).
    void EditState(const std::function<void()>& change, bool selectionMoved = false);
    void RecordEdit(const std::function<void()>& change);
    // The keyboard for a rename field opening (a space's, a tab's or a folder's): the one place
    // W21's GiveKeyboard(KeyboardField::Rename) goes. `open` opens the field before the window
    // takes the focus, so the window's onFocus sees the rename as the keyboard's owner and doesn't
    // hand the keyboard on to the page (which would end the rename as it took it, a moment later
    // on CEF's thread).
    void TakeKeyboardForRename(const std::function<void()>& open);
    // Kite's window takes the focus when it's the one in front (a quiet run never is). For the
    // smoke test's check of that order, `testFocus_` delivers the WM_SETFOCUS SetFocus would,
    // without the activation (a quiet run never comes to the front), and onFocus only counts it.
    void TakeFocusIfInFront();
    bool testFocus_ = false;
    // How often onFocus has handed the keyboard on to the page.
    size_t pageFocusHandoffs_ = 0;
    // The Tabs menu's and the command bar's tab commands, by the Mac's ids.
    void MakeTabCommands();
    // Their validateMenuItem: whether `command` would do anything now; none when it isn't one of them.
    std::optional<bool> TabCommandEnabled(const std::string& command) const;
    // The Mac's renameTab(_:): in its row, where the tab has one shown (not a favorite or a split's
    // pane) and the sidebar is; else a beep, until W19's ArcDialog brings Rename Tab… (but a
    // double-click on a split pane's row does nothing, as the Mac's SplitRowCell has no doubleTapped).
    void BeginRenamingTab(const std::string& tabID, bool fromDoubleClick);
    // The Mac's renameFolder(_:) (the folder menu's Rename…, W17): the sidebar shown, its row's field.
    void BeginRenamingFolder(const std::string& folderID);
    void RenameTab(const std::string& tabID, const std::string& name);
    void RenameFolder(const std::string& folderID, const std::string& name);
    // A pinned tab's Back to Pinned URL, and Tabs › Reset all tabs in this Space.
    void BackToPinnedURL(const std::string& tabID);
    void ResetAllTabsInSpace();
    // MARK: The sidebar's row menus (BrowserWindowController+SidebarMenus.cpp, W17)
    // A right-click (or Ctrl+click) on a tab's or folder's row or a favorite's pane: its menu at
    // `screen` (px), then what it chose. The menu is built as it opens (a rename open ends first,
    // as for the space's menu); nothing is kept while it's closed.
    void ShowRowMenu(SidebarMenuKind kind, const std::string& id, POINT screen);
    std::vector<SidebarMenuItem> OpenRowMenu(SidebarMenuKind kind, const std::string& id);
    void RunRowMenuItem(SidebarMenuKind kind, const std::string& id, const SidebarMenuItem& item);
    // The items' actions that need the window (the Mac's SidebarActions): Separate From Pinned Tab,
    // Archive Other Tabs / Below / Above, a folder's Delete (asking first), New Nested Folder…
    // (then its rename), Turn into Space, and the Copy items.
    void SeparateFromPinnedTab(const std::string& tabID);
    void ArchiveTabs(BrowserState::ArchiveTabsRelative which, const std::string& tabID);
    void DeleteFolder(const std::string& folderID);
    void NewNestedFolder(const std::string& folderID);
    void TurnFolderIntoSpace(const std::string& folderID);
    void CopyToClipboard(const std::optional<std::string>& text);
    // The smoke test's row menus: each kind's menu read as a right-click and a Ctrl+click open it,
    // Pin Tab from a tab's, a folder's Rename… opening its rename, New Nested Folder… and Delete.
    std::wstring SmokeTestRowMenus();
    // Whether an open rename still has its header (its space shown) or row (listed by the
    // selected space's page); and what one ending renames, in the session only.
    bool RenameStillShown(const SidebarView::RenameTarget& target) const;
    void ApplyRename(const SidebarView::RenameTarget& target, const std::string& text);
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
        enum class Kind { Command, Mark, Open, Move, Leave, Occlusion } kind;
        std::string text;
        int64_t x = 0, y = 0, qpc = 0;
    };
    bool QueuePerfRequest(const COPYDATASTRUCT* data);
    void RunPerfRequests();
#ifdef KITE_HAS_CEF
    void ShowSelectedTab();
    void ShowFirstPage();
    Tab* TabNamed(const std::string& id);
#endif

    HINSTANCE instance_;
    BrowserState& state_;
    const ShortcutMap shortcuts_;
    const Options options_;
    SessionWriter* const writer_;
    DownloadsWriter* const downloadsWriter_;
    DownloadsModel downloads_;
    // The worker's read of downloads.json, handed to the window: the result, and where to post
    // that it's in (cleared as the window goes).
    struct DownloadsReadSlot {
        std::mutex mutex;
        std::optional<std::optional<downloads_file::Loaded>> result;
        std::atomic<HWND> target{nullptr};
    };
    std::shared_ptr<DownloadsReadSlot> downloadsRead_ = std::make_shared<DownloadsReadSlot>();
    bool downloadsReadAsked_ = false;
    // What the downloads cost Kite's UI thread, for the save log: each report Chromium's thread
    // handed over (the model's rules and the timer), and each save (the list's copy).
    struct DownloadCost {
        uint64_t reports = 0;
        double maxMicros = 0, totalMicros = 0;
        uint64_t saves = 0;
        double saveMaxMicros = 0;
    };
    DownloadCost downloadCost_;
    bool askingToQuit_ = false;   // "Downloads in progress" is open
    bool testGestureGiven_ = false;  // the test tab close's click, before the close
    bool quitConfirmed_ = false;  // asked (or nothing to ask): the window closes
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
    bool sidebarSliding_ = false;  // set by SetSliding, with its boost
    bool slideStarted_ = false;
    FrameClock::BoostWithoutFrames slideBoost_;
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
    // A touchpad gesture decided vertical over the list: the rest of it scrolls the list.
    bool listScrolling_ = false;
    // Whether the window can be seen (after the window, which it posts to, in destruction).
    std::unique_ptr<Occlusion> occlusion_;
    bool occluded_ = false;   // the verdict as last handled: hidden for any reason
    bool touchpadFrames_ = false;  // the touchpad still needed frames at the clock's last one
    occlusion::PointerRecovery pointerRecovery_;
    std::unique_ptr<Compositor> compositor_;
    std::unique_ptr<Favicons> favicons_;
    OneShotFlags oneShotFlags_;  // the profile's (the favorites' empty state)
    std::unique_ptr<SidebarView> sidebar_;
    // View › Hide Sidebar's state (the Mac's BrowserStore.isSidebarVisible, not saved: a launch
    // shows it), and its slide under way.
    bool sidebarShown_ = true;
    bool toggling_ = false;
    FrameClock::BoostWithoutFrames toggleBoost_;
    // What each tab's page last reported (the Mac's BrowserStore.pages), gone with its page.
    std::map<std::string, PageStatus> pageStatus_;
    std::unique_ptr<CaptionButtonsView> caption_;
    std::unique_ptr<CommandBarView> commandBar_;
    // Change Space Icon…'s popover (after the sidebar, whose painter it borrows, so it goes first),
    // and the space the menu asked it for, waiting on kIconPickerTimer.
    std::unique_ptr<SpaceIconPickerView> iconPicker_;
    std::optional<std::string> pendingIconPicker_;
    // The picker holds the keyboard (KeyboardField::IconPicker): set as it's asked for, before the
    // window takes the focus, so onFocus never hands it to the page meanwhile.
    bool iconPickerKeyboard_ = false;
    // GiveKeyboard is moving the keyboard to another field: the picker it closes doesn't hand
    // the keyboard to the page.
    bool givingKeyboard_ = false;
    // The picker is being opened or replaced (Open closes the one before it): its keyboard is
    // kept throughout, with no release in between.
    bool openingIconPicker_ = false;
    // Whether the next release may hand the keyboard to the page: not for a close caused by a
    // press (what was pressed decides), a deactivation, a move or a minimize.
    bool releaseFocusesPage_ = true;
    // The smoke test's counts: the picker's keyboard released, and handed on to the page.
    size_t pickerKeyboardReleases_ = 0;
    std::wstring barError_;
    std::unique_ptr<FindBarView> findBar_;
    std::string findTabID_;  // the tab the find bar is open on
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

    // A capture's space menu, composed over the frame (HoldSpaceMenu), and its + menu
    // (HoldNewItemMenu).
    std::optional<size_t> heldMenu_;
    bool heldNewItemMenu_ = false;
    // A capture's swatches popover, open off this row (HoldCreateSpace with a preset).
    std::optional<BarRect> heldSwatches_;
    // Create a Space (the Mac's BrowserStore.spaceCreation): open while it's set. The sidebar reads
    // it (SidebarView::SetCreation) and says when its page appears or goes.
    std::optional<SpaceCreation> creation_;
    // Choose a Theme's popover (declared after the sidebar, so it goes first: it borrows the
    // sidebar's text factory). Its window is made the first time it opens. It holds the keyboard
    // while it's open (KeyboardField::ThemeSwatches), remembering the page's field that had it; a
    // reopen keeps it (openingSwatches_), and a close by Escape hands it back (swatchesHandBack_).
    std::unique_ptr<ThemeSwatchesView> swatches_;
    bool swatchesKeyboard_ = false;
    std::optional<SpaceCreationView::Field> swatchesReturn_;
    bool openingSwatches_ = false;
    bool swatchesHandBack_ = false;
    // How the + menu and the profile pill's menu are shown and answered: Windows' (a menu loop), or
    // the smoke test's, which reads them and picks, as KITE_TEST_CONTEXT_MENU does.
    std::function<std::optional<NewItemMenuItem::Command>(const std::vector<NewItemMenuItem>&, POINT)> showNewItemMenu_;
    std::function<std::optional<size_t>(const std::vector<ContextMenuEntry>&, POINT)> showProfileMenu_;
    // A capture's row or favorite menu (HoldRowMenu, HoldFavoriteMenu): what it's for, where the
    // right-click was (client px).
    struct HeldRowMenu {
        SidebarMenuKind kind;
        std::string id;
        POINT at;
    };
    std::optional<HeldRowMenu> heldRowMenu_;
    // How a row's menu is shown and answered: Windows' (ShowSidebarMenu), or the smoke test's,
    // which reads it and picks an item as the Mac's KITE_TEST_CONTEXT_MENU does (a real menu is
    // modal). And a folder's Delete question (AskToDeleteFolder; a quiet run answers Cancel).
    std::function<std::optional<SidebarMenuItem>(const std::vector<SidebarMenuItem>&, POINT)> showRowMenu_;
    std::function<bool(const FolderDeletion&)> askToDeleteFolder_;
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
    // The smoke test's tab edits select tabs of their own: the page shown stays, so no page is made
    // (and loaded) for them, and the first page's load still ends the test. Only under --smoke-test.
    bool holdPages_ = false;
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
    // The smoke test's find, once the first page loaded: who has the keyboard, then its query,
    // then one with no match (BrowserWindowController+Tests.cpp).
    enum class SmokeFind { Idle, Matching, Missing, Done };
    SmokeFind smokeFind_ = SmokeFind::Idle;
    std::wstring smokeFindProblem_;
    RECT smokeFindFrame_{};  // the bar's, for the hole's checks
    void StartSmokeFind();
    std::wstring SmokeTestKeyboard();
    void SmokeTestFind(int count, int activeMatch, bool final);
    void FailSmokeFind(std::wstring problem);
#endif
};

}  // namespace kite
