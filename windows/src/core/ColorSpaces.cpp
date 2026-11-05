// See ColorSpaces.h.

#include "core/ColorSpaces.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace kite::color {

namespace {

using Matrix = std::array<std::array<double, 3>, 3>;
using Vector = std::array<double, 3>;

Vector Apply(const Matrix& m, const Vector& v) {
    return {m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2], m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]};
}

Matrix Inverse(const Matrix& m) {
    const double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
                       m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    Matrix out{};
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            // The cofactor of (c, r), by cyclic indices.
            const int r1 = (c + 1) % 3, r2 = (c + 2) % 3, c1 = (r + 1) % 3, c2 = (r + 2) % 3;
            out[r][c] = (m[r1][c1] * m[r2][c2] - m[r1][c2] * m[r2][c1]) / det;
        }
    }
    return out;
}

// Linear RGB to XYZ for primaries (x, y) red, green and blue, with a D65 white.
Matrix ToXYZ(const double (&xy)[3][2]) {
    Matrix p{};
    for (int c = 0; c < 3; ++c) {
        const double x = xy[c][0], y = xy[c][1];
        p[0][c] = x / y;
        p[1][c] = 1;
        p[2][c] = (1 - x - y) / y;
    }
    const double wx = 0.3127, wy = 0.3290;
    const Vector scale = Apply(Inverse(p), Vector{wx / wy, 1, (1 - wx - wy) / wy});
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) p[r][c] *= scale[c];
    }
    return p;
}

double ToLinear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }
double ToGamma(double c) {
    c = std::clamp(c, 0.0, 1.0);
    return c <= 0.0031308 ? 12.92 * c : 1.055 * std::pow(c, 1 / 2.4) - 0.055;
}

}  // namespace

float SrgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : static_cast<float>(std::pow((static_cast<double>(c) + 0.055) / 1.055, 2.4)); }

float LinearToSrgb(float c) {
    const float x = std::clamp(c, 0.f, 1.f);
    return x <= 0.0031308f ? 12.92f * x : static_cast<float>(1.055 * std::pow(static_cast<double>(x), 1 / 2.4) - 0.055);
}

Color BlendCalibrated(const Color& a, const Color& b, double fraction) {
    static const double kSrgb[3][2] = {{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}};
    static const double kGeneric[3][2] = {{0.630, 0.340}, {0.295, 0.605}, {0.155, 0.077}};
    static const Matrix srgbToXYZ = ToXYZ(kSrgb), xyzToSrgb = Inverse(srgbToXYZ);
    static const Matrix genericToXYZ = ToXYZ(kGeneric), xyzToGeneric = Inverse(genericToXYZ);
    constexpr double kGamma = 1.8;
    const double f = std::clamp(fraction, 0.0, 1.0);
    // Each colour in calibrated RGB, gamma-encoded and clipped to its gamut.
    const auto calibrated = [&](const Color& c) {
        Vector v = Apply(xyzToGeneric, Apply(srgbToXYZ, Vector{ToLinear(c.r), ToLinear(c.g), ToLinear(c.b)}));
        for (double& x : v) x = std::pow(std::clamp(x, 0.0, 1.0), 1 / kGamma);
        return v;
    };
    const Vector from = calibrated(a), to = calibrated(b);
    Vector mixed{};
    for (int i = 0; i < 3; ++i) mixed[i] = std::pow(from[i] * (1 - f) + to[i] * f, kGamma);
    const Vector srgb = Apply(xyzToSrgb, Apply(genericToXYZ, mixed));
    return Color{static_cast<float>(ToGamma(srgb[0])), static_cast<float>(ToGamma(srgb[1])), static_cast<float>(ToGamma(srgb[2])),
                 static_cast<float>(a.a * (1 - f) + b.a * f)};
}

}  // namespace kite::color
