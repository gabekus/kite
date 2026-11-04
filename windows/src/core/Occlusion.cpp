// See Occlusion.h.

#include "core/Occlusion.h"

#include <algorithm>
#include <array>
#include <cctype>

namespace kite::occlusion {

Rect Rect::Intersection(const Rect& o) const {
    return Rect{std::max(left, o.left), std::max(top, o.top), std::min(right, o.right), std::min(bottom, o.bottom)};
}

namespace {

// `r` less `s`, as up to four rects: the bands above and below `s`, then what's left and
// right of it between them.
void SubtractInto(const Rect& r, const Rect& s, std::vector<Rect>& out) {
    const Rect cut = r.Intersection(s);
    if (cut.Empty()) {
        out.push_back(r);
        return;
    }
    if (r.top < cut.top) out.push_back({r.left, r.top, r.right, cut.top});
    if (cut.bottom < r.bottom) out.push_back({r.left, cut.bottom, r.right, r.bottom});
    if (r.left < cut.left) out.push_back({r.left, cut.top, cut.left, cut.bottom});
    if (cut.right < r.right) out.push_back({cut.right, cut.top, r.right, cut.bottom});
}

bool EqualsIgnoringCase(std::string_view a, std::string_view b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), [](char x, char y) {
               return std::tolower(static_cast<unsigned char>(x)) == std::tolower(static_cast<unsigned char>(y));
           });
}

}  // namespace

void Region::Add(const Rect& rect) {
    if (overflowed_ || rect.Empty()) return;
    std::vector<Rect> pieces{rect}, next;
    for (const Rect& existing : rects_) {
        next.clear();
        for (const Rect& piece : pieces) SubtractInto(piece, existing, next);
        pieces.swap(next);
        if (pieces.empty()) return;
    }
    rects_.insert(rects_.end(), pieces.begin(), pieces.end());
    if (rects_.size() > kMaxRects) overflowed_ = true;
}

void Region::Subtract(const Rect& rect) {
    if (overflowed_ || rect.Empty()) return;
    std::vector<Rect> next;
    next.reserve(rects_.size() + 4);
    for (const Rect& r : rects_) SubtractInto(r, rect, next);
    rects_.swap(next);
    if (rects_.size() > kMaxRects) overflowed_ = true;
}

int64_t Region::Area() const {
    int64_t area = 0;
    for (const Rect& r : rects_) area += r.Area();
    return area;
}

int64_t VisiblePixels(const Rect& window, const std::vector<Rect>& monitors, const std::vector<Rect>& occluders) {
    Region region;
    // No monitors to go by (a query failed): the whole window, rather than none of it.
    if (monitors.empty()) region.Add(window);
    for (const Rect& monitor : monitors) region.Add(window.Intersection(monitor));
    for (const Rect& occluder : occluders) {
        if (region.Rects().empty()) break;
        region.Subtract(occluder);
    }
    return region.Overflowed() ? window.Area() : region.Area();
}

bool CanOcclude(const WindowFacts& w) {
    if (!w.visible || w.minimized || w.cloaked || w.ownProcess) return false;
    if (w.clickThrough || w.acrylic || w.shapedRegion) return false;
    // Floating tool windows can be larger than what they draw; the taskbar is one and covers.
    if (w.toolWindow && !w.taskbar) return false;
    // A layered window covers only when it's set fully opaque with no colour key; one drawn
    // with UpdateLayeredWindow (per-pixel alpha) can't be asked, so it doesn't.
    if (w.layered && (!w.layeredKnown || (w.layeredAlpha && w.alpha < 255) || w.layeredColorKey)) return false;
    // Menus, dropdowns and tooltips are owned popups, often larger than they look.
    if (w.popup && w.owned && !w.taskbar) return false;
    return !OccludingRect(w).Empty();
}

Rect OccludingRect(const WindowFacts& w) {
    if (w.maximized && !w.workArea.Empty()) return w.rect.Intersection(w.workArea);
    return w.rect;
}

bool IsPreviewWindowClass(std::string_view className) {
    // The taskbar's thumbnails, Windows 10's Alt+Tab and Task View, and Windows 11's (a XAML
    // island in Explorer).
    static constexpr std::array<std::string_view, 3> kClasses{"TaskListThumbnailWnd", "MultitaskingViewFrame",
                                                              "XamlExplorerHostIslandWindow"};
    return std::find(kClasses.begin(), kClasses.end(), className) != kClasses.end();
}

bool IsScreenRecorder(std::string_view exeName) {
    // Recorders and streamers, and Zoom's screen-sharing host (it runs only while sharing).
    // Not the meeting apps themselves (Teams, Discord, browsers): they run all day, and would
    // turn covered detection off for good.
    static constexpr std::array<std::string_view, 20> kRecorders{
        "obs64.exe",        "obs32.exe",          "obs.exe",           "Streamlabs OBS.exe", "Streamlabs Desktop.exe",
        "XSplit.Core.exe",  "bdcam.exe",          "CamRecorder.exe",   "CamtasiaRecorder.exe", "Loom.exe",
        "ShareX.exe",       "ScreenToGif.exe",    "SnagitCapture.exe", "Snagit32.exe",       "FlashBackRecorder.exe",
        "Action.exe",       "SnippingTool.exe",   "ScreenClippingHost.exe", "CptHost.exe",   "ScreenRec.exe"};
    return std::any_of(kRecorders.begin(), kRecorders.end(), [&](std::string_view name) { return EqualsIgnoringCase(name, exeName); });
}

std::string_view Name(Hidden hidden) {
    switch (hidden) {
    case Hidden::No: return "visible";
    case Hidden::Locked: return "locked";
    case Hidden::DisplayOff: return "displayOff";
    case Hidden::Cloaked: return "cloaked";
    case Hidden::Covered: return "covered";
    }
    return "visible";
}

Tracker::Reaction Tracker::SetLocked(bool locked) {
    if (locked == locked_) return {};
    locked_ = locked;
    // Unlocked: the windows may have changed meanwhile.
    return {!locked, true};
}

Tracker::Reaction Tracker::SetDisplayOff(bool off) {
    if (off == displayOff_) return {};
    displayOff_ = off;
    return {!off, true};
}

Tracker::Reaction Tracker::SetCloaked(bool cloaked) {
    if (cloaked == cloaked_) return {};
    cloaked_ = cloaked;
    return {!cloaked, true};
}

Tracker::Reaction Tracker::KiteChanged() { return {!Suspended(), false}; }

bool Tracker::NeedsOverKite(Event event) const {
    return !pass_.covered && (event == Event::Show || event == Event::Uncloaked || event == Event::LocationChange);
}

Tracker::Reaction Tracker::OnEvent(const EventFacts& e) {
    if (Suspended()) return {};
    const bool covered = pass_.covered;
    switch (e.event) {
    case Event::Foreground:
        if (e.kiteProcess) {
            // In front, Kite can't be covered (topmost windows over it aside: it's in use).
            const bool changed = !pass_.kiteForeground || pass_.covered;
            pass_ = Pass{};
            pass_.kiteForeground = true;
            return {false, changed};
        }
        // Another app came forward: over Kite, maybe. The verdict stays until the pass says.
        pass_.kiteForeground = false;
        return {true, false};
    case Event::MoveSizeStart:
        // A window over Kite is being dragged: Kite shows from the first pixel it uncovers,
        // without waiting for a pass per step of the drag.
        if (covered && e.occluder && !occluderMoving_) {
            occluderMoving_ = true;
            return {false, true};
        }
        return {};
    case Event::MoveSizeEnd: {
        const bool wasMoving = occluderMoving_;
        occluderMoving_ = false;
        return {true, wasMoving};
    }
    case Event::MinimizeStart: return {covered && e.occluder, false};
    case Event::MinimizeEnd: return {!covered, false};
    case Event::Show:
    case Event::Uncloaked:
        if (e.kiteWindow && e.event == Event::Uncloaked) return SetCloaked(false);
        if (e.previewWindow) {
            // A thumbnail or Alt+Tab shows Kite's window as it is: draw it, now.
            const bool changed = !pass_.previewing;
            pass_.previewing = true;
            return {true, changed};
        }
        return {!covered && e.overKite && !e.kiteProcess, false};
    case Event::Hide:
    case Event::Cloaked:
        if (e.kiteWindow && e.event == Event::Cloaked) return SetCloaked(true);
        // Windows 11's Alt+Tab is cloaked rather than hidden when it goes: the pass looks again.
        if (e.previewWindow) return {true, false};
        return {covered && e.occluder, false};
    case Event::LocationChange:
        if (e.kiteProcess) return {e.kiteWindow, false};
        return {covered ? e.occluder : e.overKite, false};
    case Event::Reorder: return {covered, false};
    }
    return {};
}

void Tracker::SetPass(Pass pass) {
    pass_ = std::move(pass);
    if (pass_.kiteForeground) {
        pass_.covered = false;
        pass_.occluders.clear();
        pass_.occluderProcesses.clear();
    }
}

Hidden Tracker::Verdict() const {
    if (locked_) return Hidden::Locked;
    if (displayOff_) return Hidden::DisplayOff;
    // A thumbnail, Alt+Tab or Task View can show Kite from another desktop, or covered.
    if (pass_.previewing) return Hidden::No;
    if (cloaked_) return Hidden::Cloaked;
    if (pass_.covered && !pass_.kiteForeground && !occluderMoving_ && !pass_.recording) return Hidden::Covered;
    return Hidden::No;
}

ProcessHooks Tracker::Hooks(uint32_t kiteProcess, uint32_t foregroundProcess, uint32_t shellProcess) const {
    ProcessHooks hooks;
    if (Suspended()) return hooks;
    if (pass_.covered) {
        for (uint32_t process : pass_.occluderProcesses) {
            if (process == 0 || process == kiteProcess) continue;
            hooks.location.insert(process);
            hooks.hideReorder.insert(process);
        }
        if (shellProcess && shellProcess != kiteProcess) hooks.hideReorder.insert(shellProcess);
    } else if (!pass_.kiteForeground && foregroundProcess && foregroundProcess != kiteProcess) {
        hooks.location.insert(foregroundProcess);
    }
    return hooks;
}

}  // namespace kite::occlusion
