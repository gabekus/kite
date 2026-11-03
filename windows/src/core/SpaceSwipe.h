#pragma once
// Paging the sidebar between spaces: the Mac's SpaceSwipe (KiteCore/SpaceSwipe.swift). Arc pages
// its sidebar horizontally, one page per space, under the fixed address field. This is the
// platform-free part: where the pages sit for a given finger travel, which space a release lands
// on, the settle spring, which pages are built, and how lit each space's icon is. Also the theme
// crossfade's timing (the Mac's ThemeView.spring).

#include <cstddef>
#include <optional>
#include <vector>

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

// The theme crossfade's progress `elapsed` seconds into a space switch that started at
// `startProgress` (0 for a switch, the swipe's progress when one is let go): the step response
// of the Mac's spring, 1 from kThemeDuration on (ThemeView.draw).
double ThemeCrossfadeProgress(double elapsed, double startProgress = 0);

}  // namespace kite
