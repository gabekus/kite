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

template <typename T>
void SortUnique(std::vector<T>& values) {
    std::sort(values.begin(), values.end());
    values.erase(std::unique(values.begin(), values.end()), values.end());
}

template <size_t N>
bool OneOf(std::string_view value, const std::array<std::string_view, N>& names) {
    return std::find(names.begin(), names.end(), value) != names.end();
}

}  // namespace

void Region::Add(const Rect& rect) {
    if (overflowed_ || rect.Empty()) return;
    std::vector<Rect> pieces{rect};
    for (const Rect& existing : rects_) {
        scratch_.clear();
        for (const Rect& piece : pieces) SubtractInto(piece, existing, scratch_);
        pieces.swap(scratch_);
        if (pieces.empty()) return;
    }
    rects_.insert(rects_.end(), pieces.begin(), pieces.end());
    if (rects_.size() > kMaxRects) overflowed_ = true;
}

void Region::Subtract(const Rect& rect) {
    if (overflowed_ || rect.Empty()) return;
    scratch_.clear();
    for (const Rect& r : rects_) SubtractInto(r, rect, scratch_);
    rects_.swap(scratch_);
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
    using namespace win32;
    if (!w.visible || w.minimized || w.cloaked || w.ownProcess) return false;
    const bool popup = (w.style & kPopup) != 0;
    const bool tool = (w.exStyle & kExToolWindow) != 0;
    const bool taskbar = w.className == "Shell_TrayWnd" || w.className == "Shell_SecondaryTrayWnd";
    if ((w.exStyle & kExTransparent) != 0) return false;  // clicks fall through: an overlay
    // Floating tool windows can be larger than what they draw; the taskbar is one and covers.
    if (tool && !taskbar) return false;
    // Menus, dropdowns and tooltips are owned popups, often larger than they look.
    if (popup && w.owned && !taskbar) return false;
    // A shaped window draws only part of its rect; one with an empty region draws nothing.
    if (w.region == kComplexRegion || w.region == kNullRegion) return false;
    if (w.backdrop == kBackdropAcrylic) return false;  // shows what's under it, blurred
    // Terminals whose opacity setting can make them see-through without a style that says so.
    static constexpr std::array<std::string_view, 2> kMaybeTranslucent{"org.wezfurlong.wezterm", "CASCADIA_HOSTING_WINDOW_CLASS"};
    if (OneOf(w.className, kMaybeTranslucent)) return false;
    // A layered window covers only when it's set fully opaque with no colour key; one drawn
    // with UpdateLayeredWindow (per-pixel alpha) can't be asked, so it doesn't.
    if ((w.exStyle & kExLayered) != 0 &&
        (!w.layeredKnown || ((w.layeredFlags & kLayeredAlpha) != 0 && w.alpha < 255) || (w.layeredFlags & kLayeredColorKey) != 0)) {
        return false;
    }
    // DirectComposition content may be transparent anywhere: only classes known to draw
    // opaque (Chromium's and Electron's windows, UWP frames), and as a popup only the latter.
    if ((w.exStyle & kExNoRedirectionBitmap) != 0) {
        static constexpr std::array<std::string_view, 2> kOpaque{"Chrome_WidgetWin_1", "ApplicationFrameWindow"};
        if (!OneOf(w.className, kOpaque)) return false;
        if (popup && w.className != "ApplicationFrameWindow") return false;
    }
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
    return OneOf(className, kClasses);
}

bool IsScreenRecorder(std::string_view exeName) {
    // Recorders and streamers that run for a recording, and Zoom's screen-sharing host (it runs
    // only while sharing). Not what stays resident whether or not it's recording: Windows 11's
    // Snipping Tool (it was running on Gabe's PC), ShareX, Snagit and Loom, nor the meeting apps
    // (Teams, Discord, browsers). They'd turn covered detection off for good. Chromium makes no
    // such exception at all.
    static constexpr std::array<std::string_view, 13> kRecorders{
        "obs64.exe",        "obs32.exe",       "obs.exe",           "Streamlabs OBS.exe", "Streamlabs Desktop.exe",
        "XSplit.Core.exe",  "bdcam.exe",       "CamRecorder.exe",   "CamtasiaRecorder.exe", "ScreenToGif.exe",
        "FlashBackRecorder.exe", "CptHost.exe", "ScreenRec.exe"};
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
    // Unlocked: the windows (and DWM's answers about them) may have changed meanwhile.
    return {!Suspended(), true, false, !Suspended()};
}

Tracker::Reaction Tracker::SetDisplayOff(bool off) {
    if (off == displayOff_) return {};
    displayOff_ = off;
    return {!Suspended(), true, false, !Suspended()};
}

Tracker::Reaction Tracker::SetCloaked(bool cloaked) {
    if (cloaked == cloaked_) return {};
    cloaked_ = cloaked;
    return {!cloaked && !Suspended(), true, false, !cloaked};
}

Tracker::Reaction Tracker::KiteChanged() { return {!Suspended(), false, false}; }

Tracker::Reaction Tracker::DisplayChanged() {
    // Windows refits maximized windows after the change arrives: look again once they have.
    return {!Suspended(), false, !Suspended()};
}

Tracker::Reaction Tracker::KiteActivated() {
    const bool changed = !pass_.kiteForeground || pass_.covered;
    pass_.kiteForeground = true;
    pass_.covered = false;
    pass_.occluders.clear();
    // The pass in front skips the windows; it reads Kite's cloak, afresh.
    return {!Suspended(), changed, false, true};
}

Tracker::Reaction Tracker::PointerSeen() { return {!Suspended(), false, false, true}; }

bool Tracker::NeedsOverKite(Event event) const {
    if (Suspended()) return false;
    if (event == Event::MoveSizeStart) return !pass_.covered;
    return !pass_.covered && (event == Event::Show || event == Event::Uncloaked);
}

Tracker::Reaction Tracker::OnEvent(const EventFacts& e) {
    if (Suspended()) return {};
    const bool covered = pass_.covered;
    // Mid-drag the window's every step would ask for a pass: they wait for the drag's end.
    const bool midDrag = dragging_ && !dragEnded_;
    Reaction reaction;
    switch (e.event) {
    case Event::Foreground:
        // In front, Kite can't be covered (topmost windows over it aside: it's in use).
        if (e.kiteProcess) return KiteActivated();
        // Another app came forward: over Kite, maybe. The verdict stays until the pass says.
        pass_.kiteForeground = false;
        reaction.recompute = true;
        break;
    case Event::MoveSizeStart:
        // Covered, only dragging a window over Kite can uncover it; visible, a drag over or
        // near it may cover it.
        if (!e.kiteProcess && (covered ? e.occluder : (e.occluder || e.overKite))) {
            reaction.reevaluate = !dragging_;
            dragging_ = true;
            dragEnded_ = false;
            draggingWindow_ = e.window;
        }
        return reaction;
    case Event::MoveSizeEnd:
        // A drop ends a drag that held Covered off, may cover a visible Kite, or moves a
        // window that covered it; a snap can settle a moment later.
        if (dragging_ || !covered || e.occluder) {
            reaction.recompute = true;
            reaction.followUp = true;
        }
        if (dragging_) dragEnded_ = true;
        return reaction;
    case Event::MinimizeStart: reaction.recompute = covered && e.occluder; break;
    case Event::MinimizeEnd: reaction.recompute = !covered; break;
    case Event::Show:
    case Event::Uncloaked:
        if (e.kiteWindow && e.event == Event::Uncloaked) return SetCloaked(false);
        reaction.refreshWindows = e.event == Event::Uncloaked;
        if (e.previewWindow) {
            // A thumbnail or Alt+Tab shows Kite's window as it is: draw it, now.
            reaction.reevaluate = !pass_.previewing;
            pass_.previewing = true;
            reaction.recompute = true;
            break;
        }
        reaction.recompute = !covered && e.overKite && !e.kiteProcess;
        break;
    case Event::Hide:
    case Event::Cloaked:
        if (e.kiteWindow && e.event == Event::Cloaked) return SetCloaked(true);
        // A cloak changes DWM's answer for that window.
        reaction.refreshWindows = e.event == Event::Cloaked;
        // Windows 11's Alt+Tab is cloaked rather than hidden when it goes: the pass looks again.
        reaction.recompute = e.previewWindow || (covered && e.occluder);
        break;
    }
    if (midDrag && dragging_) reaction.recompute = false;
    return reaction;
}

void Tracker::DragLost() {
    dragging_ = dragEnded_ = false;
    draggingWindow_ = 0;
}

void Tracker::SetPass(Pass& pass) {
    std::swap(pass_, pass);
    pass.occluders.clear();
    pass.covered = pass.previewing = pass.recording = pass.kiteForeground = false;
    pass.kiteShown = true;
    SortUnique(pass_.occluders);
    if (pass_.kiteForeground || !pass_.kiteShown) {
        pass_.covered = false;
        pass_.occluders.clear();
    }
    // The pass after a drag's end: the drag's hold on Covered goes.
    if (dragEnded_) DragLost();
}

Hidden Tracker::Verdict() const {
    if (locked_) return Hidden::Locked;
    if (displayOff_) return Hidden::DisplayOff;
    // A thumbnail, Alt+Tab or Task View can show Kite from another desktop, or covered.
    if (pass_.previewing) return Hidden::No;
    if (cloaked_) return Hidden::Cloaked;
    if (pass_.covered && !pass_.kiteForeground && !dragging_ && !pass_.recording) return Hidden::Covered;
    return Hidden::No;
}

bool Tracker::IsOccluder(uintptr_t window) const { return std::binary_search(pass_.occluders.begin(), pass_.occluders.end(), window); }

GlobalHooks Tracker::Globals() const {
    GlobalHooks hooks;
    // Nothing on screen can change the verdict while locked, with the display off, with Kite
    // minimized or hidden (its own messages say when that ends), or on another desktop (its
    // own cloak's per-process hook does).
    if (Suspended() || !pass_.kiteShown || cloaked_) return hooks;
    // Another app coming forward, and a drag: one that starts while Kite is in front comes
    // microseconds after the foreground change, before a hook made for it would exist.
    hooks.foreground = hooks.moveSize = true;
    if (pass_.kiteForeground) return hooks;
    hooks.minimize = hooks.cloak = true;
    return hooks;
}

ProcessHooks Tracker::Hooks(uint32_t kiteProcess, uint32_t shellProcess) const {
    ProcessHooks hooks;
    if (Suspended() || !pass_.kiteShown) return hooks;
    // Kite's own desktop switch, when nothing system-wide watches cloaks.
    if (cloaked_ || pass_.kiteForeground) {
        hooks.kiteCloak = true;
        return hooks;
    }
    const auto other = [&](uint32_t process) { return process != 0 && process != kiteProcess; };
    // A thumbnail, Alt+Tab or Task View up: its going (Windows 10 hides it; Windows 11 cloaks
    // it, which the system-wide hook sees), so it doesn't hold Kite drawing.
    if (pass_.previewing && other(shellProcess)) hooks.shellHide = true;
    // Covered: the shell's previews coming up. The occluders closing, hiding or turning
    // translucent are the heartbeat's (their destroys and hides come for every menu and caret).
    if (pass_.covered && other(shellProcess)) hooks.shellShow = true;
    return hooks;
}

void DwmCache::Prune(uint64_t pass) {
    std::erase_if(entries_, [&](const auto& entry) { return entry.second.seen != pass; });
}

bool OccludersChanged(const std::vector<OccluderState>& atPass, const std::vector<OccluderState>& now) { return atPass != now; }

void Heartbeat::SetVerdict(Hidden verdict, double now) {
    if (verdict != Hidden::Covered) {
        next_.reset();
        beats_ = 0;
        return;
    }
    if (!next_) {
        next_ = now + kInterval;
        beats_ = 0;
    }
}

Heartbeat::Beat Heartbeat::Fire(double now) {
    next_ = now + kInterval;
    return ++beats_ % kFullPassEvery == 0 ? Beat::FullPass : Beat::Check;
}

void PointerRecovery::SetVerdict(Hidden verdict) {
    if (verdict == verdict_) return;
    verdict_ = verdict;
    armed_ = verdict == Hidden::Covered;
}

bool PointerRecovery::OnPointer() {
    if (!armed_) return false;
    armed_ = false;
    return true;
}

bool CrossfadeTo(ThemeCrossfade& crossfade, const Theme& theme, double now, bool seen, bool& snapped) {
    snapped = false;
    if (!seen) {
        if (theme != crossfade.to || crossfade.Fading()) {
            crossfade.Snap(theme);
            snapped = true;
        }
        return false;
    }
    return crossfade.Set(theme, now);
}

}  // namespace kite::occlusion
