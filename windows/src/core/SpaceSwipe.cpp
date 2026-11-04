#include "core/SpaceSwipe.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <numbers>
#include <utility>

namespace kite {

SpaceSwipe::SpaceSwipe(double pageWidth, bool hasPrevious, bool hasNext, double travel)
    : pageWidth_(std::max(pageWidth, 1.0)), travel_(travel), hasPrevious_(hasPrevious), hasNext_(hasNext) {}

double SpaceSwipe::RubberBand(double overshoot, double dimension) {
    constexpr double c = 0.55;
    return (1 - 1 / (std::abs(overshoot) * c / dimension + 1)) * dimension * (overshoot < 0 ? -1 : 1);
}

double SpaceSwipe::Offset() const {
    if (travel_ > 0 && !hasPrevious_) return RubberBand(travel_, pageWidth_);
    if (travel_ < 0 && !hasNext_) return RubberBand(travel_, pageWidth_);
    return std::min(std::max(travel_, -pageWidth_), pageWidth_);
}

double SpaceSwipe::Progress() const {
    const double offset = Offset();
    const bool neighbour = offset > 0 ? hasPrevious_ : hasNext_;
    return neighbour ? std::min(std::abs(offset) / pageWidth_, 1.0) : 0;
}

int SpaceSwipe::Direction() const {
    const double offset = Offset();
    if (offset > 0 && hasPrevious_) return -1;
    if (offset < 0 && hasNext_) return 1;
    return 0;
}

void SpaceSwipe::Move(double delta, double time) {
    travel_ += delta;
    if (lastTime_ && time > *lastTime_) {
        const double instant = delta / (time - *lastTime_);
        velocity_ = velocity_ * 0.6 + instant * 0.4;
    }
    lastTime_ = time;
}

int SpaceSwipe::Landing() const {
    const int d = Direction();
    if (d == 0) return 0;
    const double towards = d == -1 ? velocity_ : -velocity_;
    if (towards > kFlickVelocity) return d;
    if (towards < -kFlickVelocity) return 0;
    return std::abs(Offset()) >= pageWidth_ / 2 ? d : 0;
}

double SpaceSwipe::Settle(double from, double elapsed, double response) {
    if (!(elapsed > 0)) return from;
    const double omega = 2 * std::numbers::pi / std::max(response, 0.001);
    const double x = from * (1 + omega * elapsed) * std::exp(-omega * elapsed);
    return std::abs(x) < 0.1 ? 0 : x;
}

std::vector<size_t> SpaceSwipe::BuiltPages(size_t selected, std::optional<size_t> anchor, size_t count) {
    if (count == 0) return {};
    const size_t centre = anchor.value_or(selected);
    std::vector<size_t> pages;
    for (size_t i = centre == 0 ? 0 : centre - 1; i <= std::min(centre + 1, count - 1); ++i) pages.push_back(i);
    if (std::find(pages.begin(), pages.end(), selected) == pages.end()) pages.push_back(selected);
    std::sort(pages.begin(), pages.end());
    return pages;
}

double SpaceSwipe::Highlight(size_t index, size_t selected, const std::vector<size_t>& built, double offset, double pageWidth) {
    if (!(pageWidth > 0)) return index == selected ? 1 : 0;
    const auto cover = [&](size_t i) {
        const double distance = (static_cast<double>(i) - static_cast<double>(selected)) * pageWidth + offset;
        return std::max(0.0, 1 - std::abs(distance) / pageWidth);
    };
    double total = 0;
    for (size_t i : built) total += cover(i);
    if (!(total > 0)) return index == selected ? 1 : 0;
    return std::find(built.begin(), built.end(), index) != built.end() ? cover(index) / total : 0;
}

double SettleDuration(double from, double response) {
    if (std::abs(from) < 0.1) return 0;  // already at rest, as Settle reads it
    // |x| falls steadily to rest: the first time it reads 0.
    double low = 0, high = response;
    while (SpaceSwipe::Settle(from, high, response) != 0) high *= 2;
    for (int i = 0; i < 60; ++i) {
        const double mid = (low + high) / 2;
        (SpaceSwipe::Settle(from, mid, response) == 0 ? high : low) = mid;
    }
    return high;
}

std::vector<CubicSegment> SettleSegments(double from, double response, int count) {
    const double end = SettleDuration(from, response);
    if (end <= 0 || count < 1) return {};
    // Cubic Hermite pieces of x(t) = from·(1 + ωt)·e^(−ωt), closer together early, where it
    // bends most.
    const double omega = 2 * std::numbers::pi / std::max(response, 0.001);
    const auto x = [&](double t) { return from * (1 + omega * t) * std::exp(-omega * t); };
    const auto dx = [&](double t) { return -from * omega * omega * t * std::exp(-omega * t); };
    std::vector<CubicSegment> segments;
    for (int i = 0; i < count; ++i) {
        const double t0 = end * std::pow(static_cast<double>(i) / count, 1.5);
        const double t1 = end * std::pow(static_cast<double>(i + 1) / count, 1.5);
        const double h = t1 - t0;
        const double p0 = x(t0), p1 = x(t1);
        const double m0 = dx(t0) * h, m1 = dx(t1) * h;
        segments.push_back(CubicSegment{t0, p0, m0 / h, (-3 * p0 - 2 * m0 + 3 * p1 - m1) / (h * h), (2 * p0 + m0 - 2 * p1 + m1) / (h * h * h)});
    }
    return segments;
}

double ValueAt(const std::vector<CubicSegment>& segments, double end, double time) {
    // From `end` on, at rest, as Settle drops the last tenth of a point.
    if (segments.empty() || time >= end) return 0;
    auto it = std::upper_bound(segments.begin(), segments.end(), time, [](double t, const CubicSegment& s) { return t < s.begin; });
    const CubicSegment& s = it == segments.begin() ? segments.front() : *std::prev(it);
    const double u = std::max(time - s.begin, 0.0);
    return s.constant + u * (s.linear + u * (s.quadratic + u * s.cubic));
}

namespace {
// The Bézier's parameter where its x is `x` (x(u) rises from 0 to 1 for control points in 0...1).
double BezierParameter(double x1, double x2, double x) {
    const auto at = [&](double u) { return 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u; };
    double lo = 0, hi = 1;
    for (int i = 0; i < 60; ++i) {
        const double mid = (lo + hi) / 2;
        (at(mid) < x ? lo : hi) = mid;
    }
    return (lo + hi) / 2;
}
double Bezier(double a, double b, double u) { return 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u; }
double BezierSlope(double a, double b, double u) {
    return 3 * (1 - u) * (1 - u) * a + 6 * (1 - u) * u * (b - a) + 3 * u * u * (1 - b);
}
}  // namespace

double TimingCurveAt(double x1, double y1, double x2, double y2, double progress) {
    if (progress <= 0) return 0;
    if (progress >= 1) return 1;
    return Bezier(y1, y2, BezierParameter(x1, x2, progress));
}

std::vector<CubicSegment> TimingCurveSegments(double x1, double y1, double x2, double y2, double duration, int count) {
    if (duration <= 0 || count < 1) return {};
    // dy/dt along the time: (dy/du) / (dx/du), over the duration.
    const auto value = [&](double t) { return TimingCurveAt(x1, y1, x2, y2, t / duration); };
    const auto slope = [&](double t) {
        const double u = BezierParameter(x1, x2, std::clamp(t / duration, 0.0, 1.0));
        const double dx = BezierSlope(x1, x2, u);
        return dx > 1e-9 ? BezierSlope(y1, y2, u) / dx / duration : 0;
    };
    std::vector<CubicSegment> segments;
    for (int i = 0; i < count; ++i) {
        const double t0 = duration * i / count, t1 = duration * (i + 1) / count, h = t1 - t0;
        const double p0 = value(t0), p1 = value(t1);
        const double m0 = slope(t0) * h, m1 = slope(t1) * h;
        segments.push_back(CubicSegment{t0, p0, m0 / h, (-3 * p0 - 2 * m0 + 3 * p1 - m1) / (h * h), (2 * p0 + m0 - 2 * p1 + m1) / (h * h * h)});
    }
    return segments;
}

double ThemeCrossfadeProgress(double elapsed, double startProgress) {
    if (elapsed >= space_motion::kThemeDuration) return 1;
    const double t = std::max(elapsed, 0.0);
    const double zeta = space_motion::kSwitchDamping;
    const double omega = 2 * std::numbers::pi / space_motion::kSwitchResponse;
    const double omegaD = omega * std::sqrt(1 - zeta * zeta);
    const double spring = 1 - std::exp(-zeta * omega * t) * (std::cos(omegaD * t) + zeta * omega / omegaD * std::sin(omegaD * t));
    return startProgress + (1 - startProgress) * std::min(spring, 1.0);
}

bool ThemeCrossfade::Set(const Theme& theme, double now) {
    if (interactive || theme == to) return false;
    if (start && now - *start < space_motion::kThemeDuration / 2) to = from;
    from = to;
    to = theme;
    startProgress = 0;
    if (from == to) {
        start.reset();
        return false;
    }
    start = now;
    return true;
}

void ThemeCrossfade::Snap(const Theme& theme) {
    from = to = theme;
    start.reset();
    interactive.reset();
    startProgress = 0;
}

void ThemeCrossfade::SetInteractive(const Theme& fromTheme, const Theme& toTheme, float progress) {
    from = fromTheme;
    to = toTheme;
    interactive = from == to ? 1.0f : std::clamp(progress, 0.0f, 1.0f);
    start.reset();
}

void ThemeCrossfade::FinishInteractive(const Theme& theme, double now) {
    const float progress = interactive.value_or(1.0f);
    interactive.reset();
    // Rubber-banded past the last space, or between two spaces with the same theme.
    if (from == to && theme == to) return Snap(theme);
    if (theme != to && theme != from) {
        // Another space selected under the swipe: a switch to it, from whichever side was
        // showing more.
        if (progress >= 0.5f) from = to;
        to = theme;
        startProgress = 0;
        start = now;
        return;
    }
    if (theme == to) {
        startProgress = progress;
    } else {
        // Back where it started: the same mix, read from the other end.
        std::swap(from, to);
        startProgress = 1 - progress;
    }
    // Already all the way there (a whole page's drag, or none back): nothing to fade.
    if (startProgress >= 1) return Snap(theme);
    start = now;
}

float ThemeCrossfade::Progress(double time) {
    if (interactive) return *interactive;
    if (!start) return 1;
    const double elapsed = std::max(time - *start, 0.0);
    if (elapsed >= space_motion::kThemeDuration) {
        start.reset();
        from = to;
        startProgress = 0;
        return 1;
    }
    return static_cast<float>(ThemeCrossfadeProgress(elapsed, startProgress));
}

}  // namespace kite

namespace kite {

std::optional<SpaceSwipe::Neighbours> SpaceSwipe::Neighbours::Make(const std::vector<std::string>& spaces, size_t selected) {
    if (selected >= spaces.size()) return std::nullopt;
    Neighbours n;
    if (selected > 0) n.previous = spaces[selected - 1];
    n.current = spaces[selected];
    if (selected + 1 < spaces.size()) n.next = spaces[selected + 1];
    return n;
}

std::optional<std::string> SpaceSwipe::Neighbours::Towards(int direction) const {
    if (direction < 0) return previous;
    if (direction > 0) return next;
    return current;
}

std::optional<std::string> SpaceSwipe::Neighbours::Target(int direction, const std::vector<std::string>& spaces, const std::string& selected) const {
    if (selected != current) return std::nullopt;
    const auto here = std::find(spaces.begin(), spaces.end(), current);
    const std::optional<std::string> id = Towards(direction);
    if (here == spaces.end() || !id) return std::nullopt;
    const auto at = std::find(spaces.begin(), spaces.end(), *id);
    const std::ptrdiff_t step = direction < 0 ? -1 : direction > 0 ? 1 : 0;
    if (at == spaces.end() || at - here != step) return std::nullopt;
    return id;
}

}  // namespace kite
