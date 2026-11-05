// core/Occlusion: the rect subtraction, the threshold, which windows cover (from real windows'
// styles), the event filter, and the state machine behind shell/Occlusion with the hooks each
// state keeps. The Mac has no counterpart to port (AppKit decides there).

#include "Check.h"
#include "core/Occlusion.h"

using namespace kite;
using namespace kite::occlusion;

namespace {

const Rect kMonitor{0, 0, 1920, 1080};
const Rect kKite{100, 100, 1380, 920};  // 1280×820

WindowFacts Opaque(Rect rect) {
    WindowFacts w;
    w.visible = true;
    w.style = 0x14cf0000;  // WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPSIBLINGS
    w.exStyle = 0x00000100;  // WS_EX_WINDOWEDGE
    w.className = "Notepad";
    w.rect = rect;
    return w;
}

// A window as this PC's EnumWindows saw it (2026-11-04, Windows 11 26200): its class, styles,
// GetLayeredWindowAttributes (known, flags, alpha), GetWindowRgn, DWMWA_SYSTEMBACKDROP_TYPE and
// DWMWA_CLOAKED, over Kite.
WindowFacts Seen(std::string_view className, uint32_t style, uint32_t exStyle, int backdrop = 0, bool owned = false) {
    WindowFacts w;
    w.visible = true;
    w.className = className;
    w.style = style;
    w.exStyle = exStyle;
    w.backdrop = backdrop;
    w.owned = owned;
    w.rect = {0, 0, 2560, 1392};
    return w;
}

WindowFacts Layered(WindowFacts w, uint32_t flags, uint8_t alpha) {
    w.layeredKnown = true;
    w.layeredFlags = flags;
    w.alpha = alpha;
    return w;
}

Tracker::Pass CoveredBy(std::vector<uintptr_t> windows, std::vector<uint32_t> processes) {
    Tracker::Pass pass;
    pass.covered = true;
    pass.occluders = std::move(windows);
    pass.occluderProcesses = std::move(processes);
    return pass;
}

EventFacts Facts(Event event, bool occluder = false, bool overKite = false) {
    EventFacts facts;
    facts.event = event;
    facts.occluder = occluder;
    facts.overKite = overKite;
    return facts;
}

EventFacts Kite(Event event, bool kiteWindow = true) {
    EventFacts facts;
    facts.event = event;
    facts.kiteProcess = true;
    facts.kiteWindow = kiteWindow;
    return facts;
}

EventFacts Preview(Event event) {
    EventFacts facts;
    facts.event = event;
    facts.previewWindow = true;
    return facts;
}

GlobalHooks Globals(bool foreground, bool moveSize, bool minimize, bool show, bool cloak) {
    GlobalHooks hooks;
    hooks.foreground = foreground;
    hooks.moveSize = moveSize;
    hooks.minimize = minimize;
    hooks.show = show;
    hooks.cloak = cloak;
    return hooks;
}

}  // namespace

TEST(subtractionLeavesWhatNoOccluderCovers) {
    CHECK(VisiblePixels(kKite, {kMonitor}, {}) == kKite.Area());
    // Exactly covered, or by a larger window: nothing shows.
    CHECK(VisiblePixels(kKite, {kMonitor}, {kKite}) == 0);
    CHECK(VisiblePixels(kKite, {kMonitor}, {kMonitor}) == 0);
    // Half covered.
    CHECK(VisiblePixels(kKite, {kMonitor}, {{100, 100, 740, 920}}) == 640 * 820);
    // A hole in the middle of four windows that tile around it.
    const std::vector<Rect> frame{{0, 0, 1920, 500}, {0, 500, 700, 1080}, {710, 500, 1920, 1080}, {700, 510, 710, 1080}};
    CHECK(VisiblePixels(kKite, {kMonitor}, frame) == 10 * 10);
    // Two windows that together cover it, overlapping each other.
    CHECK(VisiblePixels(kKite, {kMonitor}, {{0, 0, 900, 1080}, {800, 0, 1920, 1080}}) == 0);
}

TEST(onlyThePartOnAMonitorCounts) {
    // Half off the left of the only monitor, and the half on it covered.
    const Rect offLeft{-640, 100, 640, 920};
    CHECK(VisiblePixels(offLeft, {kMonitor}, {{0, 0, 640, 1080}}) == 0);
    // A second monitor to the left shows that half.
    const Rect left{-1920, 0, 0, 1080};
    CHECK(VisiblePixels(offLeft, {left, kMonitor}, {{0, 0, 640, 1080}}) == 640 * 820);
    // Mirrored monitors overlap: their shared part isn't counted twice.
    CHECK(VisiblePixels(kKite, {kMonitor, kMonitor}, {}) == kKite.Area());
    // No monitors to go by: the whole window, not none of it.
    CHECK(VisiblePixels(kKite, {}, {}) == kKite.Area());
    CHECK(!Covered(VisiblePixels(kKite, {}, {})));
}

TEST(aFewPixelsAreCoveredButAStripIsNot) {
    CHECK(Covered(0));
    CHECK(Covered(kMinVisiblePixels - 1));
    CHECK(!Covered(kMinVisiblePixels));
    // A 7×7 corner showing: covered.
    CHECK(Covered(VisiblePixels(kKite, {kMonitor}, {{107, 100, 1380, 920}, {100, 107, 107, 920}})));
    // A 1 px line along the whole bottom edge: visible.
    CHECK(!Covered(VisiblePixels(kKite, {kMonitor}, {{0, 0, 1920, 919}})));
}

TEST(theRegionGivesUpAsVisibleWhenItWouldGrowWithoutBound) {
    // A checkerboard of 1 px windows splits the region past its limit: the answer is the whole
    // window, never "covered".
    std::vector<Rect> dots;
    for (int y = 100; y < 920; y += 2) {
        for (int x = 100; x < 1380; x += 2) dots.push_back({x, y, x + 1, y + 1});
    }
    CHECK(VisiblePixels(kKite, {kMonitor}, dots) == kKite.Area());
    Region region;
    region.Add({0, 0, 10, 10});
    region.Add({5, 5, 15, 15});
    CHECK(region.Area() == 100 + 100 - 25);
    region.Subtract({0, 0, 15, 15});
    CHECK(region.Area() == 0);
    region.Add({0, 0, 1, 1});
    region.Clear();
    CHECK(region.Rects().empty() && !region.Overflowed());
}

TEST(onlyOpaqueTopLevelWindowsCover) {
    CHECK(CanOcclude(Opaque(kKite)));
    auto with = [](auto change) {
        WindowFacts w = Opaque(kKite);
        change(w);
        return CanOcclude(w);
    };
    CHECK(!with([](WindowFacts& w) { w.visible = false; }));
    CHECK(!with([](WindowFacts& w) { w.minimized = true; }));
    CHECK(!with([](WindowFacts& w) { w.cloaked = true; }));
    CHECK(!with([](WindowFacts& w) { w.ownProcess = true; }));
    CHECK(!with([](WindowFacts& w) { w.exStyle |= win32::kExTransparent; }));
    CHECK(!with([](WindowFacts& w) { w.backdrop = win32::kBackdropAcrylic; }));
    CHECK(with([](WindowFacts& w) { w.backdrop = 2; }));  // Mica: the wallpaper, not what's under it
    CHECK(!with([](WindowFacts& w) { w.region = win32::kComplexRegion; }));
    CHECK(!with([](WindowFacts& w) { w.region = win32::kNullRegion; }));
    CHECK(with([](WindowFacts& w) { w.region = 2; }));  // SIMPLEREGION
    CHECK(!with([](WindowFacts& w) { w.rect = {}; }));
    // Tool windows don't.
    CHECK(!with([](WindowFacts& w) { w.exStyle |= win32::kExToolWindow; }));
    // Layered: only set fully opaque, without a colour key.
    CHECK(!with([](WindowFacts& w) { w.exStyle |= win32::kExLayered; }));  // UpdateLayeredWindow: can't tell
    CHECK(with([](WindowFacts& w) {
        w = Layered(w, 0, 0);
        w.exStyle |= win32::kExLayered;
    }));
    CHECK(with([](WindowFacts& w) {
        w = Layered(w, win32::kLayeredAlpha, 255);
        w.exStyle |= win32::kExLayered;
    }));
    CHECK(!with([](WindowFacts& w) {
        w = Layered(w, win32::kLayeredAlpha, 254);
        w.exStyle |= win32::kExLayered;
    }));
    CHECK(!with([](WindowFacts& w) {
        w = Layered(w, win32::kLayeredColorKey, 255);
        w.exStyle |= win32::kExLayered;
    }));
    // An owned popup (a menu, a dropdown) doesn't; a borderless app or full-screen video does.
    CHECK(!with([](WindowFacts& w) {
        w.style |= win32::kPopup;
        w.owned = true;
    }));
    CHECK(with([](WindowFacts& w) { w.style |= win32::kPopup; }));
    CHECK(with([](WindowFacts& w) { w.owned = true; }));  // a dialog
    // DirectComposition without a redirection bitmap: only known-opaque classes.
    CHECK(!with([](WindowFacts& w) { w.exStyle |= win32::kExNoRedirectionBitmap; }));
}

TEST(realWindowsCoverOnlyWhenTheyCantBeSeenThrough) {
    // Discord and Claude (Electron), maximized; Claude is layered at alpha 255.
    CHECK(CanOcclude(Seen("Chrome_WidgetWin_1", 0x15c70000, 0x00200100, 2)));
    CHECK(CanOcclude(Layered(Seen("Chrome_WidgetWin_1", 0x15c70000, 0x00280100, 2), win32::kLayeredAlpha, 255)));
    // SteelSeries GG (Chromium with a redirection bitmap).
    CHECK(CanOcclude(Seen("Chrome_WidgetWin_1", 0x14c70000, 0x00000100)));
    // Chromium's tool-window panel (a status window), layered: no.
    CHECK(!CanOcclude(Layered(Seen("Chrome_WidgetWin_1", 0x14000000, 0x082800a8), win32::kLayeredAlpha, 255)));
    // Zen (Firefox), acrylic: shows what's under it.
    CHECK(!CanOcclude(Seen("MozillaWindowClass", 0x17cf0000, 0x00000100, win32::kBackdropAcrylic)));
    // Windows Terminal and WezTerm: their opacity settings can make them see-through.
    CHECK(!CanOcclude(Seen("CASCADIA_HOSTING_WINDOW_CLASS", 0x14cf0000, 0x00200100, 1)));
    CHECK(!CanOcclude(Seen("org.wezfurlong.wezterm", 0x14cf0000, 0x00000110)));
    // TextInputHost's CoreWindow (emoji panel, clipboard history, voice, touch keyboard): an
    // unowned full-monitor popup drawn by DirectComposition, transparent but for the panel.
    WindowFacts textInput = Seen("Windows.UI.Core.CoreWindow", 0x94000000, 0x00200000);
    textInput.rect = {0, 0, 2560, 1440};
    CHECK(!CanOcclude(textInput));
    textInput.cloaked = true;  // as it sits until opened
    CHECK(!CanOcclude(textInput));
    // A Chromium window as a popup without a redirection bitmap (a transparent overlay): no.
    CHECK(!CanOcclude(Seen("Chrome_WidgetWin_1", 0x94000000, 0x00200000)));
    // A UWP app's frame (Settings) covers; Explorer's near-full-screen one sits cloaked.
    CHECK(CanOcclude(Seen("ApplicationFrameWindow", 0x94cf0000, 0x00200100, 1)));
    WindowFacts explorerFrame = Seen("ApplicationFrameWindow", 0x94cf0000, 0x00200100, 1);
    explorerFrame.cloaked = true;
    CHECK(!CanOcclude(explorerFrame));
    // File Explorer and Notepad (Mica Alt) cover.
    CHECK(CanOcclude(Seen("CabinetWClass", 0x14cf0000, 0x00000100, 4)));
    CHECK(CanOcclude(Seen("Notepad", 0x14cf0000, 0x00000110, 4)));
    // The taskbar, a topmost tool window with a simple region, covers.
    WindowFacts taskbar = Seen("Shell_TrayWnd", 0x96000000, 0x00000088);
    taskbar.region = 2;
    CHECK(CanOcclude(taskbar));
    // Steam (SDL): unowned popups with redirection bitmaps, so they cover.
    CHECK(CanOcclude(Seen("SDL_app", 0x94cf0000, 0x02040100)));
    CHECK(CanOcclude(Seen("SDL_app", 0x96cf0000, 0x00040100)));
    // Phone Link (WinUI 3 with a redirection bitmap) and a WinForms tool.
    CHECK(CanOcclude(Seen("WinUIDesktopWin32WindowClass", 0x14cf0000, 0x00000100)));
    CHECK(CanOcclude(Seen("WindowsForms10.Window.8.app.0.bb8560_r6_ad1", 0x16030000, 0x00050000)));
    // GameYomi's overlay: a topmost tool popup with an empty region.
    WindowFacts overlay = Seen("MigakuOverlay.Overlay", 0x94000000, 0x00200088);
    overlay.region = win32::kNullRegion;
    CHECK(!CanOcclude(overlay));
    // Raycast's window: owned, layered at alpha 0.
    CHECK(!CanOcclude(Layered(Seen("HwndWrapper[Raycast;Main]", 0x16000000, 0x080800a0, 0, true), win32::kLayeredAlpha, 0)));
    // A console's pseudo window: an owned tool popup.
    CHECK(!CanOcclude(Seen("PseudoConsoleWindow", 0x94000000, 0x08000080, 0, true)));
    // The desktop (it's under Kite anyway): a tool window.
    CHECK(!CanOcclude(Seen("Progman", 0x96000000, 0x00200080)));
}

TEST(aMaximizedWindowCoversOnlyItsWorkArea) {
    WindowFacts w = Opaque({-8, -8, 1928, 1040});
    w.maximized = true;
    w.workArea = {0, 0, 1920, 1032};
    CHECK(OccludingRect(w) == (Rect{0, 0, 1920, 1032}));
    // So it doesn't cover what's past its monitor.
    CHECK(VisiblePixels({1900, 100, 2500, 400}, {kMonitor, {1920, 0, 3840, 1080}}, {OccludingRect(w)}) == 580 * 300);
    w.maximized = false;
    CHECK(OccludingRect(w) == w.rect);
}

TEST(previewWindowsAndRecordersAreKnownByName) {
    CHECK(IsPreviewWindowClass("TaskListThumbnailWnd"));
    CHECK(IsPreviewWindowClass("MultitaskingViewFrame"));
    CHECK(IsPreviewWindowClass("XamlExplorerHostIslandWindow"));
    CHECK(!IsPreviewWindowClass("Notepad"));
    CHECK(!IsPreviewWindowClass("tasklistthumbnailwnd"));  // class names are matched exactly
    CHECK(IsScreenRecorder("obs64.exe"));
    CHECK(IsScreenRecorder("OBS64.EXE"));  // file names aren't
    CHECK(IsScreenRecorder("CptHost.exe"));
    CHECK(!IsScreenRecorder("Zoom.exe"));
    CHECK(!IsScreenRecorder("ms-teams.exe"));
    CHECK(!IsScreenRecorder("obs64.exe.bak"));
    CHECK(Name(Hidden::Covered) == "covered");
    CHECK(Name(Hidden::No) == "visible");
}

TEST(theEventFilterKeepsOnlyWholeWindows) {
    using namespace win_event;
    int asked = 0;
    const auto topLevel = [&] {
        ++asked;
        return true;
    };
    const auto child = [&] {
        ++asked;
        return false;
    };
    CHECK(FilterEvent(kForeground, true, kObjectWindow, kChildSelf, false, topLevel) == Event::Foreground);
    CHECK(FilterEvent(kMinimizeStart, true, kObjectWindow, kChildSelf, false, topLevel) == Event::MinimizeStart);
    CHECK(FilterEvent(kMoveSizeEnd, true, kObjectWindow, kChildSelf, false, topLevel) == Event::MoveSizeEnd);
    CHECK(FilterEvent(kDestroy, true, kObjectWindow, kChildSelf, false, topLevel) == Event::Destroy);
    CHECK(FilterEvent(kCloaked, true, kObjectWindow, kChildSelf, false, topLevel) == Event::Cloaked);
    CHECK(asked == 5);
    asked = 0;
    // Carets (OBJID_CARET) and the cursor (OBJID_CURSOR) move on every key and every mouse
    // move: dropped before anything is asked.
    CHECK(!FilterEvent(kShow, true, -8, kChildSelf, false, topLevel));
    CHECK(!FilterEvent(kHide, true, -9, kChildSelf, false, topLevel));
    // Nor what isn't hooked, should it come anyway: moves, z-order, state changes (measured:
    // a caret's every key, a moving window's tens a second, z-order for the container, and no
    // STATECHANGE for a maximize).
    CHECK(!FilterEvent(kLocationChange, true, kObjectWindow, kChildSelf, false, topLevel));
    CHECK(!FilterEvent(kReorder, true, kObjectWindow, kChildSelf, false, topLevel));
    CHECK(!FilterEvent(kReorder, true, -4, kChildSelf, false, topLevel));
    CHECK(!FilterEvent(kStateChange, true, kObjectWindow, kChildSelf, false, topLevel));
    // A window's part (a child id), no window, or an event not hooked.
    CHECK(!FilterEvent(kShow, true, kObjectWindow, 3, false, topLevel));
    CHECK(!FilterEvent(kShow, false, kObjectWindow, kChildSelf, false, topLevel));
    CHECK(!FilterEvent(0x8005, true, kObjectWindow, kChildSelf, false, topLevel));  // EVENT_OBJECT_FOCUS
    CHECK(asked == 0);
    // A child window's changes never cover; an occluder needn't be asked (it may be gone).
    CHECK(!FilterEvent(kShow, true, kObjectWindow, kChildSelf, false, child));
    CHECK(asked == 1);
    CHECK(FilterEvent(kHide, true, kObjectWindow, kChildSelf, true, child) == Event::Hide);
    CHECK(asked == 1);
}

TEST(lockDisplayAndCloakHideAndComeBack) {
    Tracker tracker;
    CHECK(tracker.Verdict() == Hidden::No);
    CHECK(tracker.SetLocked(true).reevaluate);
    CHECK(tracker.Verdict() == Hidden::Locked);
    CHECK(!tracker.SetLocked(true).reevaluate);  // no change, nothing to do
    const Tracker::Reaction unlocked = tracker.SetLocked(false);
    CHECK(unlocked.reevaluate && unlocked.recompute);  // the screen may have changed meanwhile
    CHECK(tracker.Verdict() == Hidden::No);
    tracker.SetDisplayOff(true);
    CHECK(tracker.Verdict() == Hidden::DisplayOff);
    tracker.SetLocked(true);
    CHECK(tracker.Verdict() == Hidden::Locked);  // either is enough
    CHECK(!tracker.SetDisplayOff(false).recompute);  // still locked: no pass yet
    CHECK(tracker.SetLocked(false).recompute);
    // Kite's window cloaked on another virtual desktop, by the event or a pass.
    CHECK(tracker.OnEvent(Kite(Event::Cloaked)).reevaluate);
    CHECK(tracker.Verdict() == Hidden::Cloaked);
    CHECK(tracker.Cloaked());
    CHECK(tracker.OnEvent(Kite(Event::Uncloaked)).reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
    // Coming back by activating Kite needn't rely on the uncloak event: a pass reads the cloak.
    tracker.SetCloaked(true);
    CHECK(tracker.KiteActivated().recompute);
}

TEST(coveredHoldsOnlyWhileNothingSaysKiteShows) {
    Tracker tracker;
    const Tracker::Pass pass = CoveredBy({0x10}, {7});
    tracker.SetPass(Tracker::Pass(pass));
    CHECK(tracker.Verdict() == Hidden::Covered);
    CHECK(tracker.IsOccluder(0x10) && !tracker.IsOccluder(0x11));
    // A recorder running: drawn anyway.
    Tracker::Pass recording = pass;
    recording.recording = true;
    tracker.SetPass(recording);
    CHECK(tracker.Verdict() == Hidden::No);
    tracker.SetPass(Tracker::Pass(pass));
    // A thumbnail or Alt+Tab shows Kite as it is.
    CHECK(tracker.OnEvent(Preview(Event::Show)).reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
    // It going (hidden, or cloaked as Windows 11's Alt+Tab is) asks a pass to look again.
    CHECK(tracker.OnEvent(Preview(Event::Hide)).recompute);
    CHECK(tracker.OnEvent(Preview(Event::Cloaked)).recompute);
    tracker.SetPass(Tracker::Pass(pass));  // the pass found it gone
    CHECK(tracker.Verdict() == Hidden::Covered);
    // Kite coming to the front, by the event or its own activation: shown now; the pass after
    // it reads Kite's cloak (and skips the windows).
    const Tracker::Reaction front = tracker.OnEvent(Kite(Event::Foreground, false));
    CHECK(front.reevaluate && front.recompute);
    CHECK(tracker.Verdict() == Hidden::No);
    CHECK(tracker.Occluders().empty());
    tracker.SetPass(Tracker::Pass(pass));
    CHECK(tracker.KiteActivated().reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
    CHECK(!tracker.KiteActivated().reevaluate);  // already in front
    // A pass while Kite is in front, or minimized, never calls it covered.
    Tracker::Pass inFront = pass;
    inFront.kiteForeground = true;
    tracker.SetPass(inFront);
    CHECK(tracker.Verdict() == Hidden::No);
    Tracker::Pass minimized = pass;
    minimized.kiteShown = false;
    tracker.SetPass(minimized);
    CHECK(tracker.Verdict() == Hidden::No);
    // Previewing beats a cloak, never a lock.
    Tracker::Pass previewing;
    previewing.previewing = true;
    tracker.SetPass(previewing);
    tracker.SetCloaked(true);
    CHECK(tracker.Verdict() == Hidden::No);
    tracker.SetLocked(true);
    CHECK(tracker.Verdict() == Hidden::Locked);
}

TEST(aPassHandsBackItsBuffersEmptied) {
    Tracker tracker;
    Tracker::Pass pass = CoveredBy({0x12, 0x10, 0x10}, {9, 7, 9});
    tracker.SetPass(pass);
    CHECK(tracker.Occluders() == (std::vector<uintptr_t>{0x10, 0x12}));  // sorted, unique
    CHECK(pass.occluders.empty() && pass.occluderProcesses.empty() && !pass.covered && pass.kiteShown);
}

TEST(aDragNearKiteHoldsOffCoveredUntilThePassAfterIt) {
    Tracker tracker;
    tracker.SetPass(CoveredBy({0x10}, {7}));
    // Dragging the window over Kite shows Kite at once.
    EventFacts start = Facts(Event::MoveSizeStart, true);
    start.window = 0x10;
    CHECK(tracker.OnEvent(start).reevaluate);
    CHECK(tracker.Dragging() && tracker.DraggingWindow() == 0x10);
    CHECK(tracker.Verdict() == Hidden::No);
    // Mid-drag, what the window does asks for no pass (it would come every step).
    CHECK(!tracker.OnEvent(Facts(Event::Hide, true)).recompute);
    // The drag's end asks for a pass and one more once a snap has settled; Covered waits for
    // that pass, not the end itself.
    const Tracker::Reaction end = tracker.OnEvent(Facts(Event::MoveSizeEnd, true));
    CHECK(end.recompute && end.followUp);
    CHECK(tracker.Dragging());
    CHECK(tracker.Verdict() == Hidden::No);
    tracker.SetPass(CoveredBy({0x10}, {7}));  // dropped back over Kite
    CHECK(!tracker.Dragging());
    CHECK(tracker.Verdict() == Hidden::Covered);

    // Covered: dragging any other window near Kite changes nothing (it can only cover more),
    // and its drop asks for no pass.
    CHECK(!tracker.NeedsOverKite(Event::MoveSizeStart));
    CHECK(!tracker.OnEvent(Facts(Event::MoveSizeStart, false, true)).reevaluate);
    CHECK(!tracker.Dragging());
    CHECK(tracker.Verdict() == Hidden::Covered);
    CHECK(!tracker.OnEvent(Facts(Event::MoveSizeEnd)).recompute);

    // A visible Kite and a window dragged near it: a pass mid-drag can't hide it (no hiding
    // and showing under the drag); the one after the drop can.
    Tracker visible;
    CHECK(visible.NeedsOverKite(Event::MoveSizeStart));
    CHECK(visible.OnEvent(Facts(Event::MoveSizeStart, false, true)).reevaluate);
    visible.SetPass(CoveredBy({0x20}, {8}));
    CHECK(visible.Verdict() == Hidden::No);
    visible.OnEvent(Facts(Event::MoveSizeEnd));
    visible.SetPass(CoveredBy({0x20}, {8}));
    CHECK(visible.Verdict() == Hidden::Covered);

    // A drag far from Kite, or of Kite itself, holds nothing.
    Tracker far;
    CHECK(!far.OnEvent(Facts(Event::MoveSizeStart, false, false)).reevaluate);
    CHECK(!far.OnEvent(Kite(Event::MoveSizeStart)).reevaluate);
    CHECK(!far.Dragging());

    // The hold goes without the drag's end when the window does, or the hook (DragLost).
    Tracker lost;
    EventFacts drag = Facts(Event::MoveSizeStart, false, true);
    drag.window = 0x30;
    lost.OnEvent(drag);
    EventFacts gone = Facts(Event::Destroy);
    gone.window = 0x30;
    lost.OnEvent(gone);
    CHECK(!lost.Dragging());
    lost.OnEvent(drag);
    lost.DragLost();
    CHECK(!lost.Dragging());
}

TEST(onlyEventsThatCanChangeTheVerdictAskForAPass) {
    Tracker tracker;
    // Visible: what could newly cover Kite.
    CHECK(tracker.OnEvent(Facts(Event::Foreground)).recompute);  // another app in front
    CHECK(tracker.OnEvent(Facts(Event::MoveSizeEnd)).recompute);
    CHECK(tracker.OnEvent(Facts(Event::MinimizeEnd)).recompute);  // a window restored
    CHECK(tracker.NeedsOverKite(Event::Show));
    CHECK(!tracker.NeedsOverKite(Event::Hide));
    CHECK(tracker.OnEvent(Facts(Event::Show, false, true)).recompute);
    CHECK(!tracker.OnEvent(Facts(Event::Show)).recompute);  // somewhere else
    EventFacts own = Kite(Event::Show, false);
    own.overKite = true;
    CHECK(!tracker.OnEvent(own).recompute);  // Kite's own windows never cover it
    // Uncovering can't happen while nothing covers.
    CHECK(!tracker.OnEvent(Facts(Event::Hide, true)).recompute);
    CHECK(!tracker.OnEvent(Facts(Event::Destroy, true)).recompute);
    CHECK(!tracker.OnEvent(Facts(Event::MinimizeStart, true)).recompute);
    CHECK(tracker.KiteChanged().recompute);
    // A monitor, work-area or scale change: a pass now and one once maximized windows refit.
    const Tracker::Reaction display = tracker.DisplayChanged();
    CHECK(display.recompute && display.followUp);

    // Covered: only what could uncover it, from the windows that cover it.
    tracker.SetPass(CoveredBy({0x10}, {7}));
    CHECK(!tracker.NeedsOverKite(Event::Show));
    for (Event event : {Event::Hide, Event::Destroy, Event::MinimizeStart, Event::Cloaked}) {
        CHECK(tracker.OnEvent(Facts(event, true)).recompute);
        CHECK(!tracker.OnEvent(Facts(event, false)).recompute);
    }
    // An occluder dropped after a move (a keyboard snap shows as one): a pass, and a settling one.
    const Tracker::Reaction dropped = tracker.OnEvent(Facts(Event::MoveSizeEnd, true));
    CHECK(dropped.recompute && dropped.followUp);
    // More windows coming over a covered Kite change nothing.
    CHECK(!tracker.OnEvent(Facts(Event::Show, false, true)).recompute);
    CHECK(!tracker.OnEvent(Facts(Event::MinimizeEnd)).recompute);
    // The pointer reaching a covered Kite asks for a pass.
    CHECK(tracker.PointerSeen().recompute);
    CHECK(tracker.Verdict() == Hidden::Covered);  // until the pass says otherwise
}

TEST(theHooksFollowWhatCanChangeTheVerdict) {
    constexpr uint32_t kite = 1, foreground = 2, shell = 3;
    const GlobalHooks none;
    Tracker tracker;
    // In the background and visible: all five system-wide, nothing per process.
    CHECK(tracker.Globals() == Globals(true, true, true, true, true));
    CHECK(tracker.Hooks(kite, shell) == ProcessHooks{});
    // Kite in front: another app coming forward, drags (one that starts now would beat a hook
    // made after the foreground change), and Kite's own desktop switch.
    tracker.KiteActivated();
    CHECK(tracker.Globals() == Globals(true, true, false, false, false));
    ProcessHooks ownCloak;
    ownCloak.kiteCloak = true;
    CHECK(tracker.Hooks(kite, shell) == ownCloak);
    // Covered: no system-wide show; the occluders' hides and destroys (never Kite's own), and
    // the shell's thumbnails.
    tracker.SetPass(CoveredBy({0x10, 0x11, 0x12}, {5, foreground, kite}));
    CHECK(tracker.Globals() == Globals(true, true, true, false, true));
    ProcessHooks covered;
    covered.hide = {foreground, shell, 5};
    covered.show = {shell};
    CHECK(tracker.Hooks(kite, shell) == covered);
    // Minimized: nothing (its own messages say when it's back).
    Tracker::Pass minimized;
    minimized.kiteShown = false;
    tracker.SetPass(minimized);
    CHECK(tracker.Globals() == none);
    CHECK(tracker.Hooks(kite, shell) == ProcessHooks{});
    // On another desktop: only Kite's own cloak.
    tracker.SetPass(Tracker::Pass{});
    tracker.SetCloaked(true);
    CHECK(tracker.Globals() == none);
    CHECK(tracker.Hooks(kite, shell) == ownCloak);
}

TEST(lockedOrDisplayOffHooksNothingAndIgnoresEvents) {
    Tracker tracker;
    tracker.SetPass(CoveredBy({0x10}, {7}));
    tracker.SetDisplayOff(true);
    CHECK(tracker.Suspended());
    CHECK(tracker.Globals() == GlobalHooks{});
    CHECK(tracker.Hooks(1, 3) == ProcessHooks{});
    CHECK(!tracker.OnEvent(Facts(Event::Hide, true)).recompute);
    CHECK(!tracker.OnEvent(Facts(Event::Foreground)).recompute);
    CHECK(!tracker.NeedsOverKite(Event::MoveSizeStart));
    CHECK(!tracker.KiteChanged().recompute);
    CHECK(!tracker.DisplayChanged().recompute);
    CHECK(!tracker.PointerSeen().recompute);
    const Tracker::Reaction on = tracker.SetDisplayOff(false);
    CHECK(on.recompute && on.reevaluate);
    CHECK(!tracker.Suspended());
    CHECK(tracker.Globals() == Globals(true, true, true, false, true));
}

TEST(theHeartbeatSeesWhatNoEventSays) {
    // A maximized window over Kite, as the pass found it.
    OccluderState maximized;
    maximized.window = 0x10;
    maximized.exists = maximized.visible = maximized.maximized = true;
    maximized.rect = {0, 0, 2560, 1392};
    const std::vector<OccluderState> atPass{maximized};
    CHECK(!OccludersChanged(atPass, {maximized}));
    // Restored down (the button, a double-click, Win+Down, leaving full screen): no event, but
    // the beat sees it.
    OccluderState restored = maximized;
    restored.maximized = false;
    restored.rect = {200, 100, 1400, 900};
    CHECK(OccludersChanged(atPass, {restored}));
    // Moved or resized (Win+Arrow, a FancyZones snap, a program): its frame changed.
    OccluderState moved = maximized;
    moved.rect = {0, 0, 1280, 1392};
    CHECK(OccludersChanged(atPass, {moved}));
    // Turned translucent or click-through: no event at all.
    OccluderState translucent = maximized;
    translucent.exStyle = win32::kExLayered;
    translucent.layeredKnown = true;
    translucent.layeredFlags = win32::kLayeredAlpha;
    translucent.alpha = 200;
    CHECK(OccludersChanged(atPass, {translucent}));
    OccluderState clickThrough = maximized;
    clickThrough.exStyle = win32::kExTransparent;
    CHECK(OccludersChanged(atPass, {clickThrough}));
    // Gone, hidden, minimized (a cloak comes as an event).
    for (auto change : {+[](OccluderState& s) { s.exists = false; }, +[](OccluderState& s) { s.visible = false; },
                        +[](OccluderState& s) { s.minimized = true; }}) {
        OccluderState now = maximized;
        change(now);
        CHECK(OccludersChanged(atPass, {now}));
    }
}

TEST(theHeartbeatBeatsOnlyWhileCovered) {
    Heartbeat beat;
    CHECK(!beat.Next());
    beat.SetVerdict(Hidden::No, 0);
    CHECK(!beat.Next());
    // Covered: every half second, a whole pass every 8th beat (4 s).
    beat.SetVerdict(Hidden::Covered, 10);
    CHECK(beat.Next() == 10 + Heartbeat::kInterval);
    beat.SetVerdict(Hidden::Covered, 10.2);  // still covered: the beat keeps its time
    CHECK(beat.Next() == 10 + Heartbeat::kInterval);
    int full = 0;
    for (int i = 1; i <= 16; ++i) {
        if (beat.Fire(10 + i * Heartbeat::kInterval) == Heartbeat::Beat::FullPass) {
            ++full;
            CHECK(i % Heartbeat::kFullPassEvery == 0);
        }
    }
    CHECK(full == 2);
    CHECK(beat.Next() == 10 + 17 * Heartbeat::kInterval);
    // Not covered for any reason but Covered (locked, display off, cloaked, visible): it stops.
    for (Hidden other : {Hidden::No, Hidden::Locked, Hidden::DisplayOff, Hidden::Cloaked}) {
        beat.SetVerdict(Hidden::Covered, 20);
        beat.SetVerdict(other, 20.1);
        CHECK(!beat.Next());
    }
}

TEST(thePointerReachingACoveredKiteAsksOnceForAPass) {
    PointerRecovery recovery;
    CHECK(!recovery.OnPointer());  // visible: nothing to recover
    recovery.SetVerdict(Hidden::Covered);
    CHECK(recovery.OnPointer());
    CHECK(!recovery.OnPointer());  // once per Covered verdict
    recovery.SetVerdict(Hidden::Covered);
    CHECK(!recovery.OnPointer());  // the same verdict again isn't a new one
    recovery.SetVerdict(Hidden::No);
    CHECK(!recovery.OnPointer());
    recovery.SetVerdict(Hidden::Covered);  // covered again: armed again
    CHECK(recovery.OnPointer());
    recovery.SetVerdict(Hidden::Locked);  // only for covered
    CHECK(!recovery.OnPointer());
}

TEST(anUnseenWindowsThemeSnapsInsteadOfFading) {
    const auto& presets = Theme::Presets();
    const Theme& a = presets[0];
    const Theme& b = presets[1];
    ThemeCrossfade crossfade(a);
    bool snapped = true;
    // Covered (or minimized, locked...): at the new theme at once, and no frames.
    CHECK(!CrossfadeTo(crossfade, b, 10.0, false, snapped));
    CHECK(snapped);
    CHECK(!crossfade.Fading() && crossfade.from == b && crossfade.to == b);
    // The theme it's already at: nothing happens.
    CHECK(!CrossfadeTo(crossfade, b, 11.0, false, snapped));
    CHECK(!snapped);
    // Seen: a fade on the frame clock.
    CHECK(CrossfadeTo(crossfade, a, 12.0, true, snapped));
    CHECK(!snapped && crossfade.Fading());
    // Hidden mid-fade: it lands where it was going.
    CHECK(!CrossfadeTo(crossfade, a, 12.05, false, snapped));
    CHECK(snapped && !crossfade.Fading() && crossfade.from == a);
}
