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
// Also here: which window events the shell hooks in each state (Tracker::GlobalHooks and
// Hooks), and which of the events it gets matter (FilterEvent, Tracker::OnEvent), so the
// watcher thread wakes as little as it can (docs/windows-architecture.md, Performance).

#include <cstdint>
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
// Not EVENT_OBJECT_LOCATIONCHANGE or EVENT_OBJECT_REORDER (measured): a caret moves on every
// key and a moving window sends tens a second, and z-order changes come for whole processes,
// each a pass, both far past the watcher's budget. What they'd add is a covered Kite shown
// the moment a window over it is snapped away by keyboard or moved by a program, rather than at
// the next event (Kite clicked or Alt+Tabbed to, the window minimized, closed or dragged).
enum class Event { Foreground, MoveSizeStart, MoveSizeEnd, MinimizeStart, MinimizeEnd, Show, Hide, Destroy, Cloaked, Uncloaked,
                   StateChange };

// The WinEvent codes, by value.
namespace win_event {
inline constexpr uint32_t kForeground = 0x0003, kMoveSizeStart = 0x000A, kMoveSizeEnd = 0x000B, kMinimizeStart = 0x0016,
                          kMinimizeEnd = 0x0017, kDestroy = 0x8001, kShow = 0x8002, kHide = 0x8003, kReorder = 0x8004,
                          kStateChange = 0x800A, kLocationChange = 0x800B, kCloaked = 0x8017, kUncloaked = 0x8018;
inline constexpr int32_t kObjectWindow = 0;  // OBJID_WINDOW
inline constexpr int32_t kChildSelf = 0;                         // CHILDID_SELF
}  // namespace win_event

// The first check on every event delivered, before anything is asked of Windows: the event it
// is, or none for what never matters (carets, cursors, scroll bars, a window's parts, events
// with no window, events not hooked). `topLevel` is asked only when the answer depends on it (it costs a GetAncestor), so it's a
// function; `occluder` says the window covered Kite in the last pass (a destroyed one can't
// be asked whether it's top-level).
template <typename TopLevel>
std::optional<Event> FilterEvent(uint32_t code, bool hasWindow, int32_t object, int32_t child, bool occluder, TopLevel topLevel);

// The facts the shell gives OnEvent, for an event FilterEvent kept.
struct EventFacts {
    Event event = Event::Foreground;
    bool kiteProcess = false;    // the window is one of Kite's (for Foreground: Kite is now in front)
    bool kiteWindow = false;     // Kite's own browser window
    bool occluder = false;       // it covered part of Kite in the last pass
    bool overKite = false;       // its rect meets Kite's, or comes near it (asked only when NeedsOverKite)
    bool previewWindow = false;  // IsPreviewWindowClass
};

// The system-wide hooks the shell keeps (events no process can be named for in advance), only
// in the states where they can change the verdict.
struct GlobalHooks {
    bool foreground = false;  // EVENT_SYSTEM_FOREGROUND: an app came forward, Kite or another
    bool moveSize = false;    // EVENT_SYSTEM_MOVESIZESTART...END: a drag
    bool minimize = false;    // EVENT_SYSTEM_MINIMIZESTART...END
    bool show = false;        // EVENT_OBJECT_SHOW: a window appearing over Kite
    bool cloak = false;       // EVENT_OBJECT_CLOAKED...UNCLOAKED: a desktop switched
    bool operator==(const GlobalHooks&) const = default;
};

// The per-process hooks, sorted process ids. Never Kite's own but for `kiteCloak` (its window
// cloaked on another desktop while nothing system-wide is hooked).
struct ProcessHooks {
    std::vector<uint32_t> stateChange;  // EVENT_OBJECT_STATECHANGE (a maximize or a restore, Chromium's signal)
    std::vector<uint32_t> hide;         // EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE
    std::vector<uint32_t> show;         // EVENT_OBJECT_SHOW (the shell's thumbnails and Alt+Tab)
    bool kiteCloak = false;             // EVENT_OBJECT_CLOAKED...UNCLOAKED for Kite's process
    bool operator==(const ProcessHooks&) const = default;
};

// The state machine: the signals, what each event does to them, the verdict, and the hooks
// each state needs.
class Tracker {
public:
    struct Reaction {
        bool recompute = false;   // run a (debounced) pass over the screen's windows
        bool reevaluate = false;  // a signal changed: the verdict (and the hooks) may have, now
    };

    // Session lock (WTS), display power (GUID_SESSION_DISPLAY_STATUS: off, not dimmed), Kite's
    // window cloaked: each true or false as Windows reports it.
    Reaction SetLocked(bool locked);
    Reaction SetDisplayOff(bool off);
    Reaction SetCloaked(bool cloaked);
    // Kite's window moved, resized, was minimized, restored, or its monitors or work area
    // changed.
    Reaction KiteChanged();
    // Kite's own app was activated (WM_ACTIVATEAPP): in front, it's seen, without a pass.
    Reaction KiteActivated();
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
    void SetPass(Pass pass);

    Hidden Verdict() const;
    // Locked or the display off: nothing on screen can change the verdict, so events are
    // ignored, nothing is hooked and no pass looks at the windows until it ends (which asks
    // for a pass).
    bool Suspended() const { return locked_ || displayOff_; }
    // On another virtual desktop: passes skip the windows, and only Kite's own cloak is hooked.
    bool Cloaked() const { return cloaked_; }
    // A drag that started near Kite and hasn't had its pass after the drag's end: Covered is
    // never published meanwhile, so the page doesn't hide and show as a window is dragged.
    bool Dragging() const { return dragging_; }
    GlobalHooks Globals() const;
    // `foregroundProcess`: the foreground window's; `foregroundNearKite`: that window is on a
    // monitor Kite's window is on; `shellProcess`: Explorer's (the thumbnails and Alt+Tab).
    ProcessHooks Hooks(uint32_t kiteProcess, uint32_t foregroundProcess, bool foregroundNearKite, uint32_t shellProcess) const;
    bool IsOccluder(uintptr_t window) const;
    bool IsCovered() const { return pass_.covered; }

private:
    bool locked_ = false, displayOff_ = false, cloaked_ = false;
    bool dragging_ = false, dragEnded_ = false;
    Pass pass_;
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
    case kStateChange: event = Event::StateChange; break;
    case kCloaked: event = Event::Cloaked; break;
    case kUncloaked: event = Event::Uncloaked; break;
    default: return std::nullopt;
    }
    // Whole top-level windows: a child window's (a control's, a page's) changes never cover.
    if (!occluder && !topLevel()) return std::nullopt;
    return event;
}

}  // namespace kite::occlusion
