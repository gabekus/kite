#pragma once
// Whether Kite's window can be seen, so a hidden or covered window stops rendering its page:
// the decisions behind shell/Occlusion, kept here so they're portable and unit-tested. The
// Mac gets this from AppKit (NSWindow.occlusionState stops a covered window's page from
// drawing, and ThemeView.swift skips its crossfade then); Windows has no such signal, so the
// shell reads the screen's windows and this decides, after Chromium's
// NativeWindowOcclusionTrackerWin (which windows can cover another, the rect subtraction, the
// taskbar thumbnails and Alt+Tab).
//
// It errs towards visible: a window wrongly called covered freezes a page someone is looking
// at, while one wrongly called visible only costs what Kite costs today. So a window that is
// or may be see-through (layered with alpha or a colour key, click-through, acrylic, drawn by
// DirectComposition without a class known to be opaque, a terminal that can be translucent),
// a tool window, a window with a shaped or empty region, a popup that something owns, a screen
// recorder running, a window being dragged near Kite, Alt+Tab or a thumbnail up, Kite being
// the foreground app, or a handful of pixels still showing all count as "seen".
//
// Also here: which window events the shell hooks in each state (Tracker::Globals and Hooks),
// which of the events it gets matter (FilterEvent, Tracker::OnEvent), and the heartbeat that
// re-reads the windows over a covered Kite (Heartbeat, OccluderState), so the watcher thread
// wakes as little as it can (docs/windows-architecture.md, Performance).

#include <cstdint>
#include <map>
#include <optional>
#include <string_view>
#include <vector>

#include "core/SpaceSwipe.h"

namespace kite::occlusion {

// Screen pixels, right and bottom exclusive (a Win32 RECT).
struct Rect {
    int32_t left = 0, top = 0, right = 0, bottom = 0;
    bool Empty() const { return right <= left || bottom <= top; }
    int64_t Area() const { return Empty() ? 0 : int64_t{right - left} * int64_t{bottom - top}; }
    bool Intersects(const Rect& o) const { return !Intersection(o).Empty(); }
    Rect Intersection(const Rect& o) const;
    Rect Inflated(int32_t by) const { return Rect{left - by, top - by, right + by, bottom + by}; }
    bool operator==(const Rect&) const = default;
};

// Fewer pixels than this left showing is covered: 8×8 px, so rounding scraps along an edge
// (a scaled window a pixel off) don't keep a page drawing, while any strip or corner someone
// could actually watch does. A 1 px line along a whole edge is hundreds of pixels: visible.
inline constexpr int64_t kMinVisiblePixels = 64;

// A region as disjoint rects, for the subtraction. Past kMaxRects pieces (a pathological
// stack of windows) it gives up as visible: Overflowed().
class Region {
public:
    static constexpr size_t kMaxRects = 4096;
    void Add(const Rect& rect);  // the part of `rect` not already in the region
    void Subtract(const Rect& rect);
    int64_t Area() const;
    bool Overflowed() const { return overflowed_; }
    const std::vector<Rect>& Rects() const { return rects_; }
    void Clear() {
        rects_.clear();
        overflowed_ = false;
    }

private:
    std::vector<Rect> rects_, scratch_;
    bool overflowed_ = false;
};

// How many of `window`'s pixels show: the part on a monitor (`monitors`, which may overlap,
// as mirrored displays do) less every occluder (the opaque windows above it). Past the
// region's limit it answers the whole window (visible).
int64_t VisiblePixels(const Rect& window, const std::vector<Rect>& monitors, const std::vector<Rect>& occluders);
inline bool Covered(int64_t visiblePixels) { return visiblePixels < kMinVisiblePixels; }

// The Win32 bits the classification reads, by value (core has no <windows.h>).
namespace win32 {
inline constexpr uint32_t kPopup = 0x80000000;                 // WS_POPUP
inline constexpr uint32_t kExTransparent = 0x00000020;         // WS_EX_TRANSPARENT
inline constexpr uint32_t kExToolWindow = 0x00000080;          // WS_EX_TOOLWINDOW
inline constexpr uint32_t kExLayered = 0x00080000;             // WS_EX_LAYERED
inline constexpr uint32_t kExNoRedirectionBitmap = 0x00200000;  // WS_EX_NOREDIRECTIONBITMAP
inline constexpr uint32_t kLayeredColorKey = 0x1;               // LWA_COLORKEY
inline constexpr uint32_t kLayeredAlpha = 0x2;                  // LWA_ALPHA
inline constexpr int kNullRegion = 1, kComplexRegion = 3;       // GetWindowRgn's answers
inline constexpr int kBackdropAcrylic = 3;                      // DWMSBT_TRANSIENTWINDOW
}  // namespace win32

// What the shell reads of a window above Kite's, as Windows gives it.
struct WindowFacts {
    bool visible = false;      // IsWindowVisible
    bool minimized = false;    // IsIconic
    bool maximized = false;    // IsZoomed
    bool cloaked = false;      // DWMWA_CLOAKED: another virtual desktop, a suspended app
    bool ownProcess = false;   // one of Kite's own windows
    bool owned = false;        // GW_OWNER: a menu, a dropdown, a tooltip, a dialog's part
    uint32_t style = 0;        // GWL_STYLE
    uint32_t exStyle = 0;      // GWL_EXSTYLE
    std::string_view className;
    // GetLayeredWindowAttributes, for a layered window: false when it failed (the window
    // draws with UpdateLayeredWindow, per-pixel alpha).
    bool layeredKnown = false;
    uint32_t layeredFlags = 0;  // LWA_ALPHA, LWA_COLORKEY
    uint8_t alpha = 255;
    int region = 0;    // GetWindowRgn's answer (0: no region of its own)
    int backdrop = 0;  // DWMWA_SYSTEMBACKDROP_TYPE (0 when it can't be read)
    Rect rect;         // DWMWA_EXTENDED_FRAME_BOUNDS (no invisible resize borders)
    Rect workArea;     // its monitor's, for a maximized window
};

// Whether the window hides what's under it. Chromium's rules, and more careful:
// - Kite's own windows never cover it (it's the foreground app then anyway).
// - Acrylic windows show what's under them, and so may terminals (WezTerm's and Windows
//   Terminal's opacity settings), whatever their styles say.
// - A window with no redirection bitmap draws with DirectComposition, alpha and all (the
//   Windows.UI.Core.CoreWindow the emoji panel and touch keyboard use is one, a full-monitor
//   popup): it covers only for a class known to draw opaque, and as a popup only for
//   ApplicationFrameWindow (a UWP app's frame).
// - An unowned non-tool popup with a redirection bitmap does cover (a borderless app, a
//   full-screen video), where Chromium skips every popup.
bool CanOcclude(const WindowFacts& window);
// The part of the screen it hides: a maximized window's frame hangs off its monitor, so it's
// clipped to the work area, as Chromium does.
Rect OccludingRect(const WindowFacts& window);

// The shell UI that shows a live picture of Kite's window wherever it is: the taskbar's
// thumbnails, Alt+Tab and Task View (Chromium's "showing thumbnails").
bool IsPreviewWindowClass(std::string_view className);
// A program whose point is recording or sharing the screen: while one runs, a covered Kite
// still draws (it may be capturing the window itself, which works covered).
bool IsScreenRecorder(std::string_view exeName);

enum class Hidden { No, Locked, DisplayOff, Cloaked, Covered };
std::string_view Name(Hidden hidden);

// The window events the shell hooks (SetWinEventHook).
//
// Not EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_REORDER or EVENT_OBJECT_STATECHANGE. Measured:
// - a caret moves on every key and a moving window sends tens a second, and the app being typed
//   in is the foreground app, usually the one over Kite: far past the watcher's budget;
// - z-order changes come for whole processes (OBJID_CLIENT), each a pass;
// - a maximize, restore, restore-down or program move raises only LOCATIONCHANGE, never a
//   STATECHANGE on any object (Chromium's comment says otherwise), and a layered window's alpha
//   changing raises nothing.
// - EVENT_OBJECT_SHOW and EVENT_OBJECT_HIDE come for a caret on every key (a focused edit
//   control: 21 shows and 22 hides for 20 keys) and for every tooltip and menu, at 5 to 8
//   context switches each: so SHOW only from the shell's preview threads (its thumbnails and
//   Alt+Tab, while covered) and HIDE only from those while one of them is up. Threads, not
//   Explorer's process: File Explorer's windows and Win+R's box are Explorer's too, each on a
//   thread of its own, and renaming a file raises a caret's SHOW per key.
// So what uncovers a covered Kite without an event (a restore-down, Win+Arrow, a FancyZones
// snap, leaving full screen, a monitor change, an occluder turning translucent or hidden) is
// found by the Heartbeat instead, and the pointer reaching Kite (PointerRecovery).
enum class Event { Foreground, MoveSizeStart, MoveSizeEnd, MinimizeStart, MinimizeEnd, Show, Hide, Destroy, Cloaked, Uncloaked };

// The WinEvent codes, by value.
namespace win_event {
inline constexpr uint32_t kForeground = 0x0003, kMoveSizeStart = 0x000A, kMoveSizeEnd = 0x000B, kMinimizeStart = 0x0016,
                          kMinimizeEnd = 0x0017, kDestroy = 0x8001, kShow = 0x8002, kHide = 0x8003, kReorder = 0x8004,
                          kStateChange = 0x800A, kLocationChange = 0x800B, kCloaked = 0x8017, kUncloaked = 0x8018;
inline constexpr int32_t kObjectWindow = 0;  // OBJID_WINDOW
inline constexpr int32_t kChildSelf = 0;     // CHILDID_SELF
}  // namespace win_event

// The first check on every event delivered, before anything is asked of Windows: the event it
// is, or none for what never matters (carets, cursors, scroll bars, a window's parts, events
// with no window, events not hooked). `topLevel` is asked only when the answer depends on it
// (it costs a GetAncestor), so it's a function; `occluder` says the window covered Kite in the
// last pass (a destroyed one can't be asked whether it's top-level).
template <typename TopLevel>
std::optional<Event> FilterEvent(uint32_t code, bool hasWindow, int32_t object, int32_t child, bool occluder, TopLevel topLevel);

// The facts the shell gives OnEvent, for an event FilterEvent kept.
struct EventFacts {
    Event event = Event::Foreground;
    uintptr_t window = 0;        // the event's window
    bool kiteProcess = false;    // the window is one of Kite's (for Foreground: Kite is now in front)
    bool kiteWindow = false;     // Kite's own browser window
    bool occluder = false;       // it covered part of Kite in the last pass
    bool overKite = false;       // its rect meets Kite's, or comes near it (asked only when NeedsOverKite)
    bool previewWindow = false;  // IsPreviewWindowClass
};

// The system-wide hooks the shell keeps, only in the states where they can change the verdict.
// Each is an event a person causes (an app coming forward, a drag, a minimize, a desktop
// switch) at a person's rate, which no process can be named for in advance: the drag may start
// in any app, Kite's own included. Not EVENT_OBJECT_SHOW: a window newly over a visible Kite
// is missed until the next pass (it costs rendering, never a blank), and one coming forward
// raises EVENT_SYSTEM_FOREGROUND anyway.
struct GlobalHooks {
    bool foreground = false;  // EVENT_SYSTEM_FOREGROUND: an app came forward, Kite or another
    bool moveSize = false;    // EVENT_SYSTEM_MOVESIZESTART...END: a drag
    bool minimize = false;    // EVENT_SYSTEM_MINIMIZESTART...END
    bool cloak = false;       // EVENT_OBJECT_CLOAKED...UNCLOAKED: a desktop switched
    bool operator==(const GlobalHooks&) const = default;
};

// The per-process hooks, sorted process ids. Never Kite's own but for `kiteCloak` (its window
// cloaked on another desktop while nothing system-wide is hooked). The shell's are only on the
// threads that show its previews (the taskbars' and the hosts of Alt+Tab and Task View), which
// the shell finds, never on Explorer's whole process.
struct ProcessHooks {
    std::vector<uint32_t> destroy;  // EVENT_OBJECT_DESTROY: the windows over a covered Kite closing
    bool shellShow = false;         // EVENT_OBJECT_SHOW on the shell's preview threads: a thumbnail or Alt+Tab coming up
    bool shellHide = false;         // EVENT_OBJECT_HIDE on them: one going, while one is up
    bool kiteCloak = false;         // EVENT_OBJECT_CLOAKED...UNCLOAKED for Kite's process
    bool operator==(const ProcessHooks&) const = default;
};

// The state machine: the signals, what each event does to them, the verdict, and the hooks
// each state needs.
class Tracker {
public:
    struct Reaction {
        bool recompute = false;   // run a (debounced) pass over the screen's windows
        bool reevaluate = false;  // a signal changed: the verdict (and the hooks) may have, now
        bool followUp = false;    // and another pass a moment later, once a snap or a monitor change has settled
        // DWM's cached answers (DwmCache) may be stale: drop them, so the pass asks again.
        bool refreshWindows = false;
    };

    // Session lock (WTS), display power (GUID_SESSION_DISPLAY_STATUS: off, not dimmed), Kite's
    // window cloaked: each true or false as Windows reports it.
    Reaction SetLocked(bool locked);
    Reaction SetDisplayOff(bool off);
    Reaction SetCloaked(bool cloaked);
    // Kite's window moved, resized, was minimized or restored.
    Reaction KiteChanged();
    // The monitors, the work area or the scale changed.
    Reaction DisplayChanged();
    // Kite's own app was activated (WM_ACTIVATEAPP): in front, it's seen at once; a pass reads
    // its cloak afresh (coming back from another desktop needn't rely on the uncloak event).
    Reaction KiteActivated();
    // The pointer reached Kite's window while it was covered (PointerRecovery): a pass that
    // asks DWM afresh (a cached answer is the likeliest reason for a wrong Covered).
    Reaction PointerSeen();
    Reaction OnEvent(const EventFacts& facts);  // ignored while Suspended
    // Whether OnEvent needs `overKite` for this event: only for what could newly cover a
    // visible Kite, or a drag that may come over it, so the shell asks for a rect only then.
    bool NeedsOverKite(Event event) const;

    // A pass's result. `kiteShown`: Kite's window is shown and not minimized; `previewing`: a
    // preview window is up; `recording`: a recorder runs (asked only when the pass found Kite
    // covered); `kiteForeground`: a Kite window is in front (the pass skips the windows then).
    struct Pass {
        bool kiteShown = true;
        bool kiteForeground = false;
        bool covered = false;
        bool previewing = false;
        bool recording = false;
        std::vector<uintptr_t> occluders;          // windows that cover part of Kite, sorted
        std::vector<uint32_t> occluderProcesses;   // their processes, sorted and unique
    };
    // Takes the pass, and hands back the previous one's buffers, emptied, for the next.
    void SetPass(Pass& pass);
    void SetPass(Pass&& pass) { SetPass(pass); }

    Hidden Verdict() const;
    // Locked or the display off: nothing on screen can change the verdict, so events are
    // ignored, nothing is hooked and no pass looks at the windows until it ends (which asks
    // for a pass).
    bool Suspended() const { return locked_ || displayOff_; }
    // On another virtual desktop: passes skip the windows, and only Kite's own cloak is hooked.
    bool Cloaked() const { return cloaked_; }
    // A drag over or near a visible Kite, or of a window over a covered one, that hasn't had
    // its pass after the drag's end: Covered isn't published meanwhile, so a covered Kite shows
    // from the first pixel the drag uncovers and a visible one never hides and shows under it.
    bool Dragging() const { return dragging_; }
    uintptr_t DraggingWindow() const { return draggingWindow_; }
    // The drag's hold ends without its end event: the hook went, or the window did.
    void DragLost();
    GlobalHooks Globals() const;
    // `shellProcess`: Explorer's (the thumbnails and Alt+Tab).
    ProcessHooks Hooks(uint32_t kiteProcess, uint32_t shellProcess) const;
    bool IsOccluder(uintptr_t window) const;
    const std::vector<uintptr_t>& Occluders() const { return pass_.occluders; }

private:
    bool locked_ = false, displayOff_ = false, cloaked_ = false;
    bool dragging_ = false, dragEnded_ = false;
    uintptr_t draggingWindow_ = 0;
    Pass pass_;
};

// What the heartbeat re-reads of each window that covered Kite in the last pass: only what
// user32 answers without a round trip (DWM's attributes cost the watcher context switches each,
// measured at ~24 a second for 18 windows; a cloak comes as an event while covered anyway). Any
// change (gone, hidden, minimized, restored down, moved or resized, turned translucent or
// click-through) asks for a pass.
struct OccluderState {
    uintptr_t window = 0;
    bool exists = false;     // IsWindow
    bool visible = false;    // IsWindowVisible
    bool minimized = false;  // IsIconic
    bool maximized = false;  // IsZoomed
    bool owned = false;      // GW_OWNER
    uint32_t style = 0;      // GWL_STYLE (a popup)
    uint32_t exStyle = 0;    // GWL_EXSTYLE (layered, click-through, a tool window)
    bool layeredKnown = false;
    uint32_t layeredFlags = 0;
    uint8_t alpha = 255;
    Rect rect;  // GetWindowRect
    bool operator==(const OccluderState&) const = default;
};
// Whether anything about the windows over Kite changed since the pass that found them.
bool OccludersChanged(const std::vector<OccluderState>& atPass, const std::vector<OccluderState>& now);

// DWM's answers for a window (each a round trip to dwm.exe, and context switches on the watcher),
// kept by the window's rect: asked again when the rect changes (its frame with it), and for
// every window when Clear is called: on a Tracker reaction's refreshWindows (the end of a lock or
// display-off, the pointer on a covered Kite, Kite's activation, any cloak event) and on the
// heartbeat's whole passes. Windows no pass saw are pruned.
struct DwmAnswers {
    Rect frame;         // DWMWA_EXTENDED_FRAME_BOUNDS
    int backdrop = 0;   // DWMWA_SYSTEMBACKDROP_TYPE
    bool cloaked = false;
};
class DwmCache {
public:
    // The window's answers, asked of `fetch` (a DwmAnswers()) when it's new, its rect changed,
    // or the cache was cleared; marked seen by `pass`.
    template <typename Fetch>
    const DwmAnswers& Get(uintptr_t window, const Rect& outer, uint64_t pass, Fetch fetch);
    void Clear() { entries_.clear(); }
    // Drops the windows `pass` didn't see.
    void Prune(uint64_t pass);
    size_t Size() const { return entries_.size(); }

private:
    struct Entry {
        Rect outer;
        DwmAnswers answers;
        uint64_t seen = 0;
    };
    std::map<uintptr_t, Entry> entries_;
};

template <typename Fetch>
const DwmAnswers& DwmCache::Get(uintptr_t window, const Rect& outer, uint64_t pass, Fetch fetch) {
    auto [it, added] = entries_.try_emplace(window);
    Entry& entry = it->second;
    if (added || !(entry.outer == outer)) {
        entry.outer = outer;
        entry.answers = fetch();
    }
    entry.seen = pass;
    return entry.answers;
}

// The verification heartbeat: only while the published verdict is Covered (Kite stopped
// drawing because it's covered, and the events that would uncover it don't exist), every
// 0.5 s it re-reads only the windows that covered it (OccluderState), and every 8th beat (4 s)
// runs a whole pass for z-order changes and new windows. It stops the moment the verdict
// leaves Covered. A one-shot wait in the watcher's MsgWait, never a timer.
class Heartbeat {
public:
    static constexpr double kInterval = 0.5;
    static constexpr int kFullPassEvery = 8;
    enum class Beat { Check, FullPass };

    // The verdict as published, at `now` (seconds).
    void SetVerdict(Hidden verdict, double now);
    // When the next beat is due; none while the verdict isn't Covered.
    std::optional<double> Next() const { return next_; }
    // A beat at `now`: what to do, and the next one scheduled.
    Beat Fire(double now);

private:
    std::optional<double> next_;
    int beats_ = 0;
};

// The pointer reaching Kite's window (WM_SETCURSOR, WM_MOUSEMOVE) while the verdict says
// covered means it isn't: the first one per Covered verdict asks for a pass (it doesn't clear
// Covered: a pass decides). On Kite's UI thread.
class PointerRecovery {
public:
    void SetVerdict(Hidden verdict);
    // True when this pointer message should ask for a pass.
    bool OnPointer();

private:
    Hidden verdict_ = Hidden::No;
    bool armed_ = false;
};

// The theme going to `theme` as the browser window does it: a crossfade on the frame clock
// while the window is `seen`; at once when it isn't (minimized, hidden, covered, locked), as
// the Mac's ThemeView skips the fade for an occluded window. True when the frame clock should
// run; `snapped` says the theme changed without a fade (the caller draws it once, if it can).
bool CrossfadeTo(ThemeCrossfade& crossfade, const Theme& theme, double now, bool seen, bool& snapped);

// MARK: FilterEvent

template <typename TopLevel>
std::optional<Event> FilterEvent(uint32_t code, bool hasWindow, int32_t object, int32_t child, bool occluder, TopLevel topLevel) {
    using namespace win_event;
    if (!hasWindow || child != kChildSelf || object != kObjectWindow) return std::nullopt;
    std::optional<Event> event;
    switch (code) {
    case kForeground: event = Event::Foreground; break;
    case kMoveSizeStart: event = Event::MoveSizeStart; break;
    case kMoveSizeEnd: event = Event::MoveSizeEnd; break;
    case kMinimizeStart: event = Event::MinimizeStart; break;
    case kMinimizeEnd: event = Event::MinimizeEnd; break;
    case kDestroy: event = Event::Destroy; break;
    case kShow: event = Event::Show; break;
    case kHide: event = Event::Hide; break;
    case kCloaked: event = Event::Cloaked; break;
    case kUncloaked: event = Event::Uncloaked; break;
    default: return std::nullopt;
    }
    // Whole top-level windows: a child window's (a control's, a page's) changes never cover.
    if (!occluder && !topLevel()) return std::nullopt;
    return event;
}

}  // namespace kite::occlusion
