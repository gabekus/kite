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
// see-through (layered with alpha or a colour key, click-through, acrylic), a tool window, a
// window with a shaped region, a popup that something owns, a screen recorder running, an
// occluder being dragged, Alt+Tab or a thumbnail up, Kite being the foreground app, or a
// handful of pixels still showing all count as "seen".

#include <cstdint>
#include <set>
#include <string_view>
#include <vector>

namespace kite::occlusion {

// Screen pixels, right and bottom exclusive (a Win32 RECT).
struct Rect {
    int32_t left = 0, top = 0, right = 0, bottom = 0;
    bool Empty() const { return right <= left || bottom <= top; }
    int64_t Area() const { return Empty() ? 0 : int64_t{right - left} * int64_t{bottom - top}; }
    bool Intersects(const Rect& o) const { return !Intersection(o).Empty(); }
    Rect Intersection(const Rect& o) const;
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

private:
    std::vector<Rect> rects_;
    bool overflowed_ = false;
};

// How many of `window`'s pixels show: the part on a monitor (`monitors`, which may overlap,
// as mirrored displays do) less every occluder (the opaque windows above it). Past the
// region's limit it answers the whole window (visible).
int64_t VisiblePixels(const Rect& window, const std::vector<Rect>& monitors, const std::vector<Rect>& occluders);
inline bool Covered(int64_t visiblePixels) { return visiblePixels < kMinVisiblePixels; }

// What the shell reads of a window above Kite's, to decide whether it can cover it
// (Chromium's IsWindowVisibleAndFullyOpaque, with the deviations noted on CanOcclude).
struct WindowFacts {
    bool visible = false;        // IsWindowVisible
    bool minimized = false;      // IsIconic
    bool cloaked = false;        // DWMWA_CLOAKED: another virtual desktop, a suspended app
    bool clickThrough = false;   // WS_EX_TRANSPARENT
    bool toolWindow = false;     // WS_EX_TOOLWINDOW
    bool popup = false;          // WS_POPUP
    bool owned = false;          // GW_OWNER: a menu, a dropdown, a tooltip, a dialog's part
    bool taskbar = false;        // Shell_TrayWnd / Shell_SecondaryTrayWnd
    bool layered = false;        // WS_EX_LAYERED
    bool layeredKnown = false;   // GetLayeredWindowAttributes answered (not UpdateLayeredWindow)
    bool layeredAlpha = false;   // LWA_ALPHA set...
    uint8_t alpha = 255;         // ...with this alpha
    bool layeredColorKey = false;  // LWA_COLORKEY
    bool shapedRegion = false;   // GetWindowRgn: COMPLEXREGION
    bool acrylic = false;        // DWMWA_SYSTEMBACKDROP_TYPE acrylic, or a host backdrop brush
    bool ownProcess = false;     // one of Kite's own windows
    bool maximized = false;
    Rect rect;                   // DWMWA_EXTENDED_FRAME_BOUNDS (no invisible resize borders)
    Rect workArea;               // its monitor's, for a maximized window
};

// Whether the window hides what's under it. Chromium's rules, but: Kite's own windows never
// cover it (it's the foreground app then anyway), acrylic windows show what's under them, and
// an unowned non-tool popup does cover (a borderless app or a full-screen video), where
// Chromium skips every popup.
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

// The window events the shell hooks (SetWinEventHook), already filtered to whole top-level
// windows (OBJID_WINDOW, CHILDID_SELF).
enum class Event { Foreground, MoveSizeStart, MoveSizeEnd, MinimizeStart, MinimizeEnd, Show, Hide, Cloaked, Uncloaked, LocationChange, Reorder };

struct EventFacts {
    Event event = Event::Foreground;
    bool kiteProcess = false;    // the window is one of Kite's (for Foreground: Kite is now in front)
    bool kiteWindow = false;     // Kite's own browser window
    bool occluder = false;       // it covered part of Kite in the last pass
    bool overKite = false;       // its rect meets Kite's (asked only when visible, see NeedsOverKite)
    bool previewWindow = false;  // IsPreviewWindowClass
};

// The per-process hooks the shell keeps for what can change Kite's state now. Visible: the
// foreground app's moves (maximizing or snapping it over Kite). Covered: the occluders'
// moves, hides and z-order, and the shell's hides (a thumbnail or Alt+Tab going). Never
// Kite's own (its window's moves reach it as messages).
struct ProcessHooks {
    std::set<uint32_t> location;  // EVENT_OBJECT_LOCATIONCHANGE
    std::set<uint32_t> hideReorder;  // EVENT_OBJECT_HIDE...EVENT_OBJECT_REORDER
    bool operator==(const ProcessHooks&) const = default;
};

// The state machine: the signals, what each event does to them, and the verdict.
class Tracker {
public:
    struct Reaction {
        bool recompute = false;  // run a (debounced) pass over the screen's windows
        bool reevaluate = false;  // a signal changed: the verdict may have, now
    };

    // Session lock (WTS), display power (GUID_SESSION_DISPLAY_STATUS: off, not dimmed), Kite's
    // window cloaked: each true or false as Windows reports it.
    Reaction SetLocked(bool locked);
    Reaction SetDisplayOff(bool off);
    Reaction SetCloaked(bool cloaked);
    // Kite's window moved, resized, was minimized or restored.
    Reaction KiteChanged();
    Reaction OnEvent(const EventFacts& facts);
    // Whether OnEvent needs `overKite` for this event: only for what could newly cover a
    // visible Kite, so the shell asks for a window's rect only then.
    bool NeedsOverKite(Event event) const;

    // A pass's result. `previewing`: a preview window is up; `recording`: a recorder runs
    // (asked only when the pass found Kite covered); `kiteForeground`: a Kite window is in
    // front (the pass skips the windows then).
    struct Pass {
        bool kiteForeground = false;
        bool covered = false;
        bool previewing = false;
        bool recording = false;
        std::set<uintptr_t> occluders;      // windows that cover part of Kite
        std::set<uint32_t> occluderProcesses;
    };
    void SetPass(Pass pass);

    Hidden Verdict() const;
    ProcessHooks Hooks(uint32_t kiteProcess, uint32_t foregroundProcess, uint32_t shellProcess) const;
    bool IsOccluder(uintptr_t window) const { return pass_.occluders.contains(window); }
    bool covered() const { return pass_.covered; }

private:
    bool locked_ = false, displayOff_ = false, cloaked_ = false;
    bool occluderMoving_ = false;
    Pass pass_;
};

}  // namespace kite::occlusion
