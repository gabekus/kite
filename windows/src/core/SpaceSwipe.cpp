#include "core/SpaceSwipe.h"

#include <algorithm>
#include <cmath>
#include <numbers>

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

double ThemeCrossfadeProgress(double elapsed, double startProgress) {
    if (elapsed >= space_motion::kThemeDuration) return 1;
    const double t = std::max(elapsed, 0.0);
    const double zeta = space_motion::kSwitchDamping;
    const double omega = 2 * std::numbers::pi / space_motion::kSwitchResponse;
    const double omegaD = omega * std::sqrt(1 - zeta * zeta);
    const double spring = 1 - std::exp(-zeta * omega * t) * (std::cos(omegaD * t) + zeta * omega / omegaD * std::sin(omegaD * t));
    return startProgress + (1 - startProgress) * std::min(spring, 1.0);
}

}  // namespace kite
