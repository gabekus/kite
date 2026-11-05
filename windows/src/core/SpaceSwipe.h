#pragma once
// Paging the sidebar between spaces: the Mac's SpaceSwipe (KiteCore/SpaceSwipe.swift). Arc pages
// its sidebar horizontally, one page per space, under the fixed address field. This is the
// platform-free part: where the pages sit for a given finger travel, which space a release lands
// on, the settle spring, which pages are built, and how lit each space's icon is. Also the theme
// crossfade's timing (the Mac's ThemeView.spring).

#include <cstddef>
#include <optional>
#include <vector>

#include "core/Models.h"

namespace kite {

// Arc's space-switch motion (ArcMetrics.Motion).
namespace space_motion {
// The theme settles like SwiftUI's spring(response: 0.15, dampingFraction: 0.95).
constexpr double kSwitchResponse = 0.15;
constexpr double kSwitchDamping = 0.95;
// Long enough for that spring to settle within half a percent (ThemeView.transitionDuration).
constexpr double kThemeDuration = 0.3;
// The pages' slide: a critically damped spring of about this response.
constexpr double kPageResponse = 0.1;
}  // namespace space_motion

class SpaceSwipe {
public:
    // `pageWidth` is the sidebar's (at least 1). `travel` carries on from pages caught mid-settle.
    SpaceSwipe(double pageWidth, bool hasPrevious, bool hasNext, double travel = 0);

    double PageWidth() const { return pageWidth_; }
    // Finger travel since the swipe began, in points. Positive moves the pages right, towards
    // the previous space.
    double Travel() const { return travel_; }
    // Points per second, smoothed over the last few events.
    double Velocity() const { return velocity_; }
    bool HasPrevious() const { return hasPrevious_; }
    bool HasNext() const { return hasNext_; }

    // AppKit's rubber band: past the last page the pages follow the fingers ever more stiffly,
    // approaching but never reaching a further page width.
    static double RubberBand(double overshoot, double dimension);
    // Where the pages sit, in points from rest: free towards a neighbouring space,
    // rubber-banded where there is none, and never more than a page either way.
    double Offset() const;
    // How far the swipe is towards the neighbouring space, 0...1, for crossfading the themes.
    double Progress() const;
    // The neighbour the pages are moving towards: -1 previous, +1 next, 0 none.
    int Direction() const;

    void Move(double delta, double time);

    // Velocity past which a flick changes space however short it was.
    static constexpr double kFlickVelocity = 300;
    // The space a release lands on, relative to the current one: -1, 0 or +1. Past half a page
    // it goes; short of it, a flick towards the neighbour still goes, and a flick back stays.
    int Landing() const;

    // Where the pages sit `elapsed` seconds into a settle that started `from` points off rest:
    // a critically damped spring with this response, as SwiftUI's
    // .spring(response:dampingFraction: 1) draws it. Under a tenth of a point is at rest (0).
    static double Settle(double from, double elapsed, double response);

    // The spaces whose pages are built, by index: the selected one and its neighbours, so a
    // swipe has both sides ready the moment it starts. While the pages settle after a switch
    // they stay those of `anchor`, the space the switch left, plus the new one; a far jump
    // shows just the two.
    static std::vector<size_t> BuiltPages(size_t selected, std::optional<size_t> anchor, size_t count);

    // How lit space `index`'s icon in the bar is, 0...1, with the pages `offset` points from
    // rest: each built page counts by how much of the sidebar it covers, shared out so the lit
    // amounts add up to one.
    static double Highlight(size_t index, size_t selected, const std::vector<size_t>& built, double offset, double pageWidth);

private:
    double pageWidth_;
    double travel_ = 0;
    double velocity_ = 0;
    bool hasPrevious_;
    bool hasNext_;
    std::optional<double> lastTime_;
};

// The settle as a compositor animation: how long it takes from `from` points off rest to
// SpaceSwipe::Settle's rest (under a tenth of a point), and the curve as cubic segments in
// seconds since it began, each a polynomial in the time since its own `begin` (what
// IDCompositionAnimation::AddCubic takes), within 0.05 pt of the spring; it then ends at rest
// at SettleDuration, as Settle drops the last tenth of a point. Empty at rest.
double SettleDuration(double from, double response);
struct CubicSegment {
    double begin, constant, linear, quadratic, cubic;
};
std::vector<CubicSegment> SettleSegments(double from, double response, int count = 16);
double ValueAt(const std::vector<CubicSegment>& segments, double end, double time);

// A CAMediaTimingFunction's cubic Bézier, (0,0) (x1,y1) (x2,y2) (1,1): its value at `progress`
// (0...1 of the time), as Core Animation evaluates it.
double TimingCurveAt(double x1, double y1, double x2, double y2, double progress);
// The same curve over `duration` seconds as cubic segments of the time since it began (Hermite
// pieces, within 0.002 of it), for IDCompositionAnimation::AddCubic; it ends at 1.
std::vector<CubicSegment> TimingCurveSegments(double x1, double y1, double x2, double y2, double duration, int count = 8);
// Core Animation's default timing (kCAMediaTimingFunctionDefault), which NSAnimationContext's
// animator uses when none is set.
constexpr double kDefaultTiming[4] = {0.25, 0.1, 0.25, 1.0};

// The theme crossfade's progress `elapsed` seconds into a space switch that started at
// `startProgress` (0 for a switch, the swipe's progress when one is let go): the step response
// of the Mac's spring, 1 from kThemeDuration on (ThemeView.draw).
double ThemeCrossfadeProgress(double elapsed, double startProgress = 0);

// The backdrop's crossfade from one theme to another (the same theme at rest): the Mac's
// ThemeView.setTheme and draw, and its swipe's setInteractiveTheme and finishInteractiveTheme.
// Times are seconds on the caller's clock.
struct ThemeCrossfade {
    Theme from, to;
    std::optional<double> start;  // while fading
    // Where the fade starts from: 0 for a switch, the swipe's progress when one is let go.
    double startProgress = 0;
    // While fingers swipe between spaces: the crossfade follows them, not the clock.
    std::optional<float> interactive;

    ThemeCrossfade() = default;
    explicit ThemeCrossfade(const Theme& theme) : from(theme), to(theme) {}
    // Fades to `theme` from `now`. Interrupted before halfway it carries on from the side that
    // was showing more (to = from), as ThemeView. True when a fade began; false for the theme
    // it's already going to, back to the one it came from before halfway (nothing to fade), or
    // mid-swipe (the swipe's release settles it).
    bool Set(const Theme& theme, double now);
    // At `theme` at once (nothing on screen to fade), a swipe's crossfade too.
    void Snap(const Theme& theme);
    // Mid-swipe: `fromTheme` crossfaded towards `toTheme` by `progress` (clamped to 0...1),
    // held until the swipe moves again. Between one theme and itself the progress stays put, so
    // nothing draws again for it.
    void SetInteractive(const Theme& fromTheme, const Theme& toTheme, float progress);
    // The swipe was let go at `now`: settles on `theme`, either side of the crossfade, with the
    // switch's spring from wherever the fingers left it (at once when there's nothing to fade).
    // A third theme (a space selected under the swipe) fades in as a switch would, from the
    // side that was showing more.
    void FinishInteractive(const Theme& theme, double now);
    // The progress for a frame shown at `time`, 0...1; from kThemeDuration on, 1 and at rest on
    // `to`.
    float Progress(double time);
    bool Fading() const { return start.has_value(); }
    bool Interactive() const { return interactive.has_value(); }
};

}  // namespace kite
