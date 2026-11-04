// core/Occlusion: the rect subtraction, the threshold, which windows cover, and the state
// machine behind shell/Occlusion. The Mac has no counterpart to port (AppKit decides there).

#include "Check.h"
#include "core/Occlusion.h"

using namespace kite::occlusion;

namespace {

const Rect kMonitor{0, 0, 1920, 1080};
const Rect kKite{100, 100, 1380, 920};  // 1280×820

WindowFacts Opaque(Rect rect) {
    WindowFacts w;
    w.visible = true;
    w.rect = rect;
    return w;
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
    CHECK(!with([](WindowFacts& w) { w.clickThrough = true; }));
    CHECK(!with([](WindowFacts& w) { w.acrylic = true; }));
    CHECK(!with([](WindowFacts& w) { w.shapedRegion = true; }));
    CHECK(!with([](WindowFacts& w) { w.ownProcess = true; }));
    CHECK(!with([](WindowFacts& w) { w.rect = {}; }));
    // Tool windows don't, but the taskbar (one) does.
    CHECK(!with([](WindowFacts& w) { w.toolWindow = true; }));
    CHECK(with([](WindowFacts& w) { w.toolWindow = w.taskbar = true; }));
    // Layered: only set fully opaque, without a colour key.
    CHECK(!with([](WindowFacts& w) { w.layered = true; }));  // UpdateLayeredWindow: can't tell
    CHECK(with([](WindowFacts& w) { w.layered = w.layeredKnown = true; }));
    CHECK(with([](WindowFacts& w) { w.layered = w.layeredKnown = w.layeredAlpha = true; }));
    CHECK(!with([](WindowFacts& w) {
        w.layered = w.layeredKnown = w.layeredAlpha = true;
        w.alpha = 254;
    }));
    CHECK(!with([](WindowFacts& w) { w.layered = w.layeredKnown = w.layeredColorKey = true; }));
    // An owned popup (a menu, a dropdown) doesn't; a borderless app or full-screen video does.
    CHECK(!with([](WindowFacts& w) { w.popup = w.owned = true; }));
    CHECK(with([](WindowFacts& w) { w.popup = true; }));
    CHECK(with([](WindowFacts& w) { w.owned = true; }));  // a dialog
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
    tracker.SetLocked(false);
    tracker.SetDisplayOff(false);
    // Kite's window cloaked on another virtual desktop, by the event or a pass.
    CHECK(tracker.OnEvent({Event::Cloaked, true, true}).reevaluate);
    CHECK(tracker.Verdict() == Hidden::Cloaked);
    CHECK(tracker.OnEvent({Event::Uncloaked, true, true}).reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
}

TEST(coveredHoldsOnlyWhileNothingSaysKiteShows) {
    Tracker tracker;
    Tracker::Pass pass;
    pass.covered = true;
    pass.occluders = {0x10};
    pass.occluderProcesses = {7};
    tracker.SetPass(pass);
    CHECK(tracker.Verdict() == Hidden::Covered);
    CHECK(tracker.IsOccluder(0x10));
    // A recorder running: drawn anyway.
    Tracker::Pass recording = pass;
    recording.recording = true;
    tracker.SetPass(recording);
    CHECK(tracker.Verdict() == Hidden::No);
    tracker.SetPass(pass);
    // Dragging the window over Kite shows it at once; the drag's end asks for a pass.
    CHECK(tracker.OnEvent({Event::MoveSizeStart, false, false, true}).reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
    const Tracker::Reaction ended = tracker.OnEvent({Event::MoveSizeEnd});
    CHECK(ended.recompute && ended.reevaluate);
    CHECK(tracker.Verdict() == Hidden::Covered);
    // Dragging some other window doesn't.
    CHECK(!tracker.OnEvent({Event::MoveSizeStart, false, false, false}).reevaluate);
    CHECK(tracker.Verdict() == Hidden::Covered);
    // A thumbnail or Alt+Tab shows Kite as it is.
    EventFacts preview{Event::Show};
    preview.previewWindow = true;
    CHECK(tracker.OnEvent(preview).reevaluate);
    CHECK(tracker.Verdict() == Hidden::No);
    // It going (hidden, or cloaked as Windows 11's Alt+Tab is) asks a pass to look again.
    for (Event gone : {Event::Hide, Event::Cloaked}) {
        EventFacts going{gone};
        going.previewWindow = true;
        CHECK(tracker.OnEvent(going).recompute);
    }
    tracker.SetPass(pass);  // the pass found it gone
    // Kite coming to the front: shown now, no pass needed.
    const Tracker::Reaction front = tracker.OnEvent({Event::Foreground, true});
    CHECK(front.reevaluate && !front.recompute);
    CHECK(tracker.Verdict() == Hidden::No);
    CHECK(!tracker.covered());
    // A pass while Kite is in front never calls it covered.
    Tracker::Pass inFront = pass;
    inFront.kiteForeground = true;
    tracker.SetPass(inFront);
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

TEST(onlyEventsThatCanChangeTheVerdictAskForAPass) {
    Tracker tracker;
    // Visible: what could newly cover Kite.
    CHECK(tracker.OnEvent({Event::Foreground, false}).recompute);  // another app in front
    CHECK(tracker.OnEvent({Event::MoveSizeEnd}).recompute);
    CHECK(tracker.OnEvent({Event::MinimizeEnd}).recompute);  // a window restored
    CHECK(tracker.NeedsOverKite(Event::Show));
    CHECK(tracker.NeedsOverKite(Event::LocationChange));
    CHECK(!tracker.NeedsOverKite(Event::Hide));
    EventFacts moved{Event::LocationChange};
    CHECK(!tracker.OnEvent(moved).recompute);  // somewhere else
    moved.overKite = true;
    CHECK(tracker.OnEvent(moved).recompute);   // over Kite
    EventFacts shown{Event::Show};
    shown.overKite = true;
    CHECK(tracker.OnEvent(shown).recompute);
    shown.kiteProcess = true;  // Kite's own windows never cover it
    CHECK(!tracker.OnEvent(shown).recompute);
    // Uncovering can't happen while nothing covers.
    CHECK(!tracker.OnEvent({Event::Hide, false, false, true}).recompute);
    CHECK(!tracker.OnEvent({Event::MinimizeStart, false, false, true}).recompute);
    CHECK(!tracker.OnEvent({Event::Reorder}).recompute);
    CHECK(tracker.KiteChanged().recompute);

    // Covered: only what could uncover it, from the windows that cover it.
    Tracker::Pass pass;
    pass.covered = true;
    pass.occluders = {0x10};
    pass.occluderProcesses = {7};
    tracker.SetPass(pass);
    CHECK(!tracker.NeedsOverKite(Event::Show));
    const EventFacts occluder{Event::Hide, false, false, true};
    const EventFacts other{Event::Hide, false, false, false};
    CHECK(tracker.OnEvent(occluder).recompute);
    CHECK(!tracker.OnEvent(other).recompute);
    for (Event event : {Event::MinimizeStart, Event::Cloaked, Event::LocationChange}) {
        CHECK(tracker.OnEvent({event, false, false, true}).recompute);
        CHECK(!tracker.OnEvent({event, false, false, false}).recompute);
    }
    // More windows coming over a covered Kite change nothing.
    CHECK(!tracker.OnEvent({Event::Show, false, false, false, true}).recompute);
    CHECK(!tracker.OnEvent({Event::MinimizeEnd}).recompute);
    CHECK(tracker.OnEvent({Event::Reorder}).recompute);  // z-order: Kite may have come up
    CHECK(tracker.Verdict() == Hidden::Covered);
}

TEST(theHooksFollowWhatCanChangeTheVerdict) {
    Tracker tracker;
    constexpr uint32_t kite = 1, foreground = 2, shell = 3;
    // Visible: the foreground app's moves only.
    CHECK(tracker.Hooks(kite, foreground, shell) == (ProcessHooks{{foreground}, {}}));
    CHECK(tracker.Hooks(kite, kite, shell) == ProcessHooks{});  // Kite in front: none
    CHECK(tracker.Hooks(kite, 0, shell) == ProcessHooks{});
    // Covered: the occluders' moves, hides and z-order, and the shell's hides.
    Tracker::Pass pass;
    pass.covered = true;
    pass.occluderProcesses = {5, 6, kite};
    tracker.SetPass(pass);
    CHECK(tracker.Hooks(kite, foreground, shell) == (ProcessHooks{{5, 6}, {5, 6, shell}}));
    tracker.OnEvent({Event::Foreground, true});
    CHECK(tracker.Hooks(kite, kite, shell) == ProcessHooks{});
}
