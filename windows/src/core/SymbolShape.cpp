#include "core/SymbolShape.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace kite {
namespace {

constexpr float kPi = 3.14159265358979f;

ShapePoint CubicAt(ShapePoint p0, ShapePoint p1, ShapePoint p2, ShapePoint p3, float t) {
    const float u = 1 - t;
    const float a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return {a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y};
}

float Distance(ShapePoint a, ShapePoint b) { return std::hypot(b.x - a.x, b.y - a.y); }

// How far a circular arc's cubic puts its control points along the tangents, per unit radius, for
// an arc turning `turn` radians.
float ArcHandle(float turn) { return 4.0f / 3.0f * std::tan(turn / 4); }

std::vector<ShapePoint> FlattenFigure(const ShapeFigure& figure, float tolerance) {
    std::vector<ShapePoint> points{figure.start};
    ShapePoint from = figure.start;
    for (const ShapeSegment& s : figure.segments) {
        if (s.cubic) {
            const float length = Distance(from, s.c1) + Distance(s.c1, s.c2) + Distance(s.c2, s.to);
            const int steps = std::clamp(static_cast<int>(std::ceil(std::sqrt(length / tolerance))), 4, 512);
            for (int i = 1; i <= steps; ++i) points.push_back(CubicAt(from, s.c1, s.c2, s.to, static_cast<float>(i) / steps));
        } else {
            points.push_back(s.to);
        }
        from = s.to;
    }
    return points;
}

// Twice the signed area, y down: positive for clockwise on screen.
float SignedArea(const std::vector<ShapePoint>& polygon) {
    float sum = 0;
    for (size_t i = 0; i < polygon.size(); ++i) {
        const ShapePoint a = polygon[i], b = polygon[(i + 1) % polygon.size()];
        sum += a.x * b.y - b.x * a.y;
    }
    return sum;
}

ShapeFigure Reversed(const ShapeFigure& figure) {
    // The points each segment starts from, then walk back.
    std::vector<ShapePoint> starts{figure.start};
    for (const ShapeSegment& s : figure.segments) starts.push_back(s.to);
    ShapeFigure out;
    out.start = starts.back();
    for (size_t i = figure.segments.size(); i-- > 0;) {
        const ShapeSegment& s = figure.segments[i];
        out.segments.push_back(ShapeSegment{s.cubic, s.c2, s.c1, starts[i]});
    }
    return out;
}

}  // namespace

ShapeBuilder& ShapeBuilder::Move(float x, float y) {
    if (open_) Close();
    Figures().push_back(ShapeFigure{{x, y}, {}});
    open_ = true;
    current_ = {x, y};
    return *this;
}

ShapeBuilder& ShapeBuilder::Line(float x, float y) {
    if (!open_) return Move(x, y);
    Figures().back().segments.push_back(ShapeSegment{false, {}, {}, {x, y}});
    current_ = {x, y};
    return *this;
}

ShapeBuilder& ShapeBuilder::Cubic(float x1, float y1, float x2, float y2, float x, float y) {
    if (!open_) Move(current_.x, current_.y);
    Figures().back().segments.push_back(ShapeSegment{true, {x1, y1}, {x2, y2}, {x, y}});
    current_ = {x, y};
    return *this;
}

ShapeBuilder& ShapeBuilder::Arc(float cx, float cy, float r, float a0, float a1) {
    const float start = a0 * kPi / 180, end = a1 * kPi / 180;
    const ShapePoint first{cx + r * std::cos(start), cy + r * std::sin(start)};
    if (open_) Line(first.x, first.y);
    else Move(first.x, first.y);
    const int pieces = std::max(1, static_cast<int>(std::ceil(std::fabs(end - start) / (kPi / 2) - 1e-4f)));
    const float step = (end - start) / pieces;
    const float k = ArcHandle(step);
    float a = start;
    for (int i = 0; i < pieces; ++i) {
        const float b = a + step;
        const float ca = std::cos(a), sa = std::sin(a), cb = std::cos(b), sb = std::sin(b);
        Cubic(cx + r * (ca - k * sa), cy + r * (sa + k * ca), cx + r * (cb + k * sb), cy + r * (sb - k * cb), cx + r * cb, cy + r * sb);
        a = b;
    }
    return *this;
}

ShapeBuilder& ShapeBuilder::Close() {
    if (open_) {
        ShapeFigure& figure = Figures().back();
        // Closed back to the start by a line where the last segment doesn't end there.
        if (!figure.segments.empty() && !(figure.segments.back().to == figure.start))
            figure.segments.push_back(ShapeSegment{false, {}, {}, figure.start});
        open_ = false;
    }
    return *this;
}

ShapeBuilder& ShapeBuilder::Ellipse(float cx, float cy, float rx, float ry, float degrees) {
    Close();
    constexpr float k = 0.5522847f;  // a quarter circle's control distance
    const float a = degrees * kPi / 180, cs = std::cos(a), sn = std::sin(a);
    // Points of the upright ellipse about its centre, turned and moved.
    const auto at = [&](float x, float y) { return ShapePoint{cx + x * cs - y * sn, cy + x * sn + y * cs}; };
    const ShapePoint p[13] = {at(rx, 0),       at(rx, k * ry),  at(k * rx, ry),   at(0, ry),     at(-k * rx, ry),
                              at(-rx, k * ry), at(-rx, 0),      at(-rx, -k * ry), at(-k * rx, -ry), at(0, -ry),
                              at(k * rx, -ry), at(rx, -k * ry), at(rx, 0)};
    Move(p[0].x, p[0].y);
    for (int i = 1; i < 13; i += 3) Cubic(p[i].x, p[i].y, p[i + 1].x, p[i + 1].y, p[i + 2].x, p[i + 2].y);
    // The last point is the first, exactly.
    Figures().back().segments.back().to = p[0];
    return Close();
}

ShapeBuilder& ShapeBuilder::RoundRect(float left, float top, float right, float bottom, float radius) {
    Close();
    radius = std::min({radius, (right - left) / 2, (bottom - top) / 2});
    if (radius <= 0) {
        Move(left, top).Line(right, top).Line(right, bottom).Line(left, bottom);
        return Close();
    }
    Arc(right - radius, top + radius, radius, -90, 0);
    Arc(right - radius, bottom - radius, radius, 0, 90);
    Arc(left + radius, bottom - radius, radius, 90, 180);
    Arc(left + radius, top + radius, radius, 180, 270);
    return Close();
}

ShapeBuilder& ShapeBuilder::RoundedPolygon(const std::vector<Corner>& corners) {
    Close();
    const size_t n = corners.size();
    if (n < 3) return *this;
    const auto point = [&](size_t i) { return ShapePoint{corners[i % n].x, corners[i % n].y}; };
    for (size_t i = 0; i < n; ++i) {
        const ShapePoint v = point(i), before = point(i + n - 1), after = point(i + 1);
        const float l0 = Distance(v, before), l1 = Distance(v, after);
        const ShapePoint d0{(before.x - v.x) / l0, (before.y - v.y) / l0}, d1{(after.x - v.x) / l1, (after.y - v.y) / l1};
        const float cosine = std::clamp(d0.x * d1.x + d0.y * d1.y, -1.0f, 1.0f);
        const float interior = std::acos(cosine), turn = kPi - interior;
        // How far back along each edge the round starts, at most half of either edge.
        float cutBack = interior > 1e-4f ? corners[i].radius / std::tan(interior / 2) : 0;
        cutBack = std::min({cutBack, l0 / 2, l1 / 2});
        const float radius = cutBack * std::tan(interior / 2);
        const ShapePoint a{v.x + d0.x * cutBack, v.y + d0.y * cutBack}, b{v.x + d1.x * cutBack, v.y + d1.y * cutBack};
        if (i == 0) Move(a.x, a.y);
        else Line(a.x, a.y);
        if (cutBack > 0) {
            const float h = ArcHandle(turn) * radius;
            Cubic(a.x - d0.x * h, a.y - d0.y * h, b.x - d1.x * h, b.y - d1.y * h, b.x, b.y);
        }
    }
    return Close();
}

ShapeBuilder& ShapeBuilder::Append(const SymbolShape& shape) {
    Close();
    for (const ShapeLayer& layer : shape.layers) shape_.layers.push_back(layer);
    shape_.layers.push_back(ShapeLayer{});
    return *this;
}

ShapeBuilder& ShapeBuilder::Cut() {
    Close();
    shape_.layers.push_back(ShapeLayer{true, {}});
    return *this;
}

ShapeBuilder& ShapeBuilder::Add() {
    Close();
    shape_.layers.push_back(ShapeLayer{false, {}});
    return *this;
}

void ShapeBuilder::Map(float a, float b, float c, float d, float e, float f) {
    const auto map = [&](ShapePoint& p) { p = ShapePoint{a * p.x + c * p.y + e, b * p.x + d * p.y + f}; };
    for (ShapeLayer& layer : shape_.layers) {
        for (ShapeFigure& figure : layer.figures) {
            map(figure.start);
            for (ShapeSegment& s : figure.segments) map(s.c1), map(s.c2), map(s.to);
        }
    }
    map(current_);
}

ShapeBuilder& ShapeBuilder::Rotate(float degrees, float cx, float cy) {
    const float r = degrees * kPi / 180, cs = std::cos(r), sn = std::sin(r);
    Map(cs, sn, -sn, cs, cx - cs * cx + sn * cy, cy - sn * cx - cs * cy);
    return *this;
}

ShapeBuilder& ShapeBuilder::Translate(float dx, float dy) {
    Map(1, 0, 0, 1, dx, dy);
    return *this;
}

SymbolShape ShapeBuilder::Build() {
    Close();
    for (ShapeLayer& layer : shape_.layers) {
        for (ShapeFigure& figure : layer.figures) {
            if (SignedArea(FlattenFigure(figure, 0.05f)) < 0) figure = Reversed(figure);
        }
    }
    std::erase_if(shape_.layers, [](const ShapeLayer& l) { return l.figures.empty(); });
    SymbolShape out = std::move(shape_);
    shape_ = SymbolShape{{ShapeLayer{}}};
    open_ = false;
    return out;
}

namespace {

using Polygons = std::vector<std::vector<ShapePoint>>;

// A layer's figures as polygons, each about `tolerance` points from its curves.
Polygons Flatten(const ShapeLayer& layer, float tolerance = 0.01f) {
    Polygons out;
    for (const ShapeFigure& figure : layer.figures) out.push_back(FlattenFigure(figure, tolerance));
    return out;
}

}  // namespace

ShapeBounds BoundsOf(const SymbolShape& shape) {
    ShapeBounds b{1e9f, 1e9f, -1e9f, -1e9f};
    bool any = false;
    for (const ShapeLayer& layer : shape.layers) {
        if (layer.cut) continue;
        for (const auto& polygon : Flatten(layer, 0.002f)) {
            for (const ShapePoint p : polygon) {
                any = true;
                b.left = std::min(b.left, p.x), b.right = std::max(b.right, p.x);
                b.top = std::min(b.top, p.y), b.bottom = std::max(b.bottom, p.y);
            }
        }
    }
    return any ? b : ShapeBounds{};
}

namespace {

bool Inside(const Polygons& polygons, float x, float y) {
    int winding = 0;
    for (const auto& polygon : polygons) {
        for (size_t i = 0; i < polygon.size(); ++i) {
            const ShapePoint a = polygon[i], b = polygon[(i + 1) % polygon.size()];
            const float side = (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y);
            if (a.y <= y && b.y > y && side > 0) ++winding;       // crossing downward, the point on its right
            else if (a.y > y && b.y <= y && side < 0) --winding;  // crossing upward
        }
    }
    return winding != 0;
}

bool Covered(const SymbolShape& shape, const std::vector<Polygons>& layers, float x, float y) {
    bool covered = false;
    for (size_t i = 0; i < layers.size(); ++i) {
        if (shape.layers[i].cut) {
            if (covered && Inside(layers[i], x, y)) covered = false;
        } else if (!covered && Inside(layers[i], x, y)) {
            covered = true;
        }
    }
    return covered;
}

std::vector<Polygons> FlattenLayers(const SymbolShape& shape) {
    std::vector<Polygons> out;
    for (const ShapeLayer& layer : shape.layers) out.push_back(Flatten(layer));
    return out;
}

}  // namespace

bool Covers(const SymbolShape& shape, float x, float y) { return Covered(shape, FlattenLayers(shape), x, y); }

namespace {

using Spans = std::vector<std::pair<float, float>>;  // sorted, apart

// Where row `y` is inside a layer's polygons (the nonzero rule), left to right.
Spans SpansAt(const Polygons& polygons, float y) {
    std::vector<std::pair<float, int>> crossings;
    for (const auto& polygon : polygons) {
        for (size_t i = 0; i < polygon.size(); ++i) {
            const ShapePoint a = polygon[i], b = polygon[(i + 1) % polygon.size()];
            if ((a.y <= y) == (b.y <= y)) continue;
            const float x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x);
            crossings.emplace_back(x, b.y > a.y ? 1 : -1);
        }
    }
    std::sort(crossings.begin(), crossings.end());
    Spans out;
    int winding = 0;
    float from = 0;
    for (const auto& [x, step] : crossings) {
        const int before = winding;
        winding += step;
        if (before == 0 && winding != 0) from = x;
        else if (before != 0 && winding == 0 && x > from) out.emplace_back(from, x);
    }
    return out;
}

Spans Joined(const Spans& a, const Spans& b) {
    Spans all(a);
    all.insert(all.end(), b.begin(), b.end());
    std::sort(all.begin(), all.end());
    Spans out;
    for (const auto& span : all) {
        if (!out.empty() && span.first <= out.back().second) out.back().second = std::max(out.back().second, span.second);
        else out.push_back(span);
    }
    return out;
}

Spans Without(const Spans& a, const Spans& cut) {
    Spans out;
    for (auto [from, to] : a) {
        for (const auto& [c0, c1] : cut) {
            if (c1 <= from || c0 >= to) continue;
            if (c0 > from) out.emplace_back(from, c0);
            from = std::max(from, c1);
            if (from >= to) break;
        }
        if (from < to) out.emplace_back(from, to);
    }
    return out;
}

}  // namespace

float InkedArea(const SymbolShape& shape, float step) {
    const ShapeBounds b = BoundsOf(shape);
    const auto layers = FlattenLayers(shape);
    float area = 0;
    for (float y = b.top + step / 2; y < b.bottom; y += step) {
        Spans inked;
        for (size_t i = 0; i < layers.size(); ++i) {
            const Spans spans = SpansAt(layers[i], y);
            inked = shape.layers[i].cut ? Without(inked, spans) : Joined(inked, spans);
        }
        for (const auto& [from, to] : inked) area += (to - from) * step;
    }
    return area;
}

namespace {

struct DrawnSymbol {
    std::string_view name;
    SymbolShape shape;
};

// Each shape in the bar's points about the cell's centre, its ink box the Mac's (review/w9b4-mac:
// the Mac's bar at 2x, ink more than half covered, to a quarter point).
using C = ShapeBuilder::Corner;

SymbolShape Bookmark() {
    // A ribbon with a notch: box -4.5..4.5 x -6.58..7.0.
    return ShapeBuilder()
        .RoundedPolygon({C{-4.5f, -6.58f, 1.5f}, C{4.5f, -6.58f, 1.5f}, C{4.5f, 7.35f, 0.35f}, C{0, 3.75f, 0.4f}, C{-4.5f, 7.35f, 0.35f}})
        .Build();
}

SymbolShape Pawprint() {
    // A pad and four toes: box -6.5..7.0 x -6.5..6.5.
    ShapeBuilder b;
    b.Ellipse(-1.75f, -4.4f, 1.55f, 2.1f, -8).Ellipse(2.25f, -4.4f, 1.55f, 2.1f, 8);
    b.Ellipse(-4.95f, -0.7f, 1.55f, 2.15f, -22).Ellipse(5.45f, -0.7f, 1.55f, 2.15f, 22);
    b.RoundedPolygon(
        {C{-1.0f, -1.6f, 1.5f}, C{1.5f, -1.6f, 1.5f}, C{5.0f, 4.0f, 1.8f},  // the top and right
         C{3.7f, 6.5f, 1.5f}, C{-3.2f, 6.5f, 1.5f}, C{-4.5f, 4.0f, 1.8f}});
    return b.Build();
}

SymbolShape BedDouble() {
    // A headboard with two pillows' openings, the mattress and two legs: box -8..8 x -5.5..5.5.
    ShapeBuilder b;
    b.RoundRect(-6.4f, -5.5f, 6.4f, -1.8f, 1.3f);
    b.Cut().RoundRect(-5.0f, -3.7f, -0.7f, -1.0f, 0.5f).RoundRect(0.7f, -3.7f, 5.0f, -1.0f, 0.5f);
    b.Add().RoundRect(-8.0f, -1.0f, 8.0f, 4.1f, 1.0f).RoundRect(-8.0f, 3.0f, -6.5f, 5.5f, 0.55f).RoundRect(6.5f, 3.0f, 8.0f, 5.5f, 0.55f);
    return b.Build();
}

SymbolShape ForkKnife() {
    // A fork and a knife side by side: box -4.5..4.5 x -7.58..7.0.
    ShapeBuilder b;
    for (const float x : {-4.5f, -2.9f, -1.3f}) b.RoundRect(x, -7.58f, x + 0.9f, -2.5f, 0.45f);
    b.RoundRect(-4.5f, -4.2f, -0.4f, -1.5f, 1.6f);
    b.RoundRect(-3.2f, -2.5f, -1.7f, 7.0f, 0.75f);
    b.Move(4.5f, -7.3f).Line(4.5f, 0.9f).Line(1.9f, 0.9f).Cubic(1.6f, 0.9f, 1.4f, 0.6f, 1.4f, 0.1f).Line(1.4f, -2.6f);
    b.Cubic(1.4f, -4.9f, 2.5f, -6.9f, 4.0f, -7.55f).Cubic(4.25f, -7.65f, 4.5f, -7.55f, 4.5f, -7.3f).Close();
    b.RoundRect(2.6f, 0, 4.5f, 7.0f, 0.95f);
    return b.Build();
}

SymbolShape Dumbbell() {
    // Two plates a side and the bar between: box -8.5..8.5 x -4.63..5.0.
    ShapeBuilder b;
    for (const float side : {-1.0f, 1.0f}) {
        const auto rect = [&](float x0, float y0, float x1, float y1, float r) {
            b.RoundRect(std::min(side * x0, side * x1), y0, std::max(side * x0, side * x1), y1, r);
        };
        rect(6.6f, -3.0f, 8.5f, 3.4f, 0.95f);
        rect(3.1f, -4.63f, 6.0f, 5.0f, 1.3f);
    }
    b.RoundRect(-2.4f, -1.15f, 2.4f, 1.55f, 0.25f);
    return b.Build();
}

SymbolShape Bandage() {
    // A strip across from bottom left to top right, its pad marked by two cuts and four dots:
    // box -6.62..6.14 x -6.13..6.63.
    ShapeBuilder b;
    b.RoundRect(-7.9f, -2.7f, 7.9f, 2.7f, 2.7f);
    b.Cut().RoundRect(-3.05f, -3.0f, -2.25f, 3.0f, 0).RoundRect(2.25f, -3.0f, 3.05f, 3.0f, 0);
    for (const float x : {-0.85f, 0.85f}) {
        for (const float y : {-0.85f, 0.85f}) b.Circle(x, y, 0.5f);
    }
    return b.Rotate(-45, 0, 0).Translate(-0.24f, 0.25f).Build();
}

SymbolShape Baseball() {
    // A ball with two seams bowing in from the left and the right, three stitches across each:
    // box -6.5..6.5 square.
    ShapeBuilder b;
    b.Circle(0, 0, 6.5f);
    b.Cut();
    for (const float side : {-1.0f, 1.0f}) {
        // A band 1.0 wide on the circle centred 9.2 out, bowing towards the middle.
        const float cx = side * 9.2f, inner = 6.2f, outer = 7.2f;
        const float from = side < 0 ? -52.0f : 128.0f, to = side < 0 ? 52.0f : 232.0f;
        b.Arc(cx, 0, outer, from, to).Arc(cx, 0, inner, to, from).Close();
        // Stitches: short cuts across the band, sticking out either side.
        for (const float t : {-24.0f, 0.0f, 24.0f}) {
            const float a = (side < 0 ? t : 180 + t) * kPi / 180;
            const float ux = std::cos(a), uy = std::sin(a), px = -uy * 0.32f, py = ux * 0.32f;
            const float r0 = inner - 0.75f, r1 = outer + 0.75f;
            b.Move(cx + ux * r0 - px, uy * r0 - py).Line(cx + ux * r0 + px, uy * r0 + py);
            b.Line(cx + ux * r1 + px, uy * r1 + py).Line(cx + ux * r1 - px, uy * r1 - py).Close();
        }
    }
    return b.Rotate(20, 0, 0).Build();
}

SymbolShape TakeoutBagAndCup() {
    // A folded bag with a handle slot, and in front of it a cup with a lid and a straw:
    // box -8..8 x -7.0..7.59.
    ShapeBuilder b;
    b.RoundRect(-6.2f, -7.0f, -0.2f, -4.2f, 1.1f);
    b.RoundedPolygon(
        {C{-6.6f, -4.6f, 0.6f}, C{0.2f, -4.6f, 0.6f}, C{2.3f, -2.6f, 0.6f},  // the folded top
         C{2.3f, 6.1f, 1.1f}, C{-8.0f, 6.1f, 1.1f}, C{-8.0f, -2.6f, 0.6f}});
    b.Cut().RoundRect(-5.2f, -6.05f, -1.2f, -4.95f, 0.55f);
    // The cup's outline and the gap round it.
    b.RoundedPolygon({C{-0.3f, -2.8f, 1.0f}, C{8.7f, -2.8f, 1.0f}, C{7.6f, 8.3f, 1.4f}, C{0.6f, 8.3f, 1.4f}});
    b.Add().RoundRect(0.8f, -1.7f, 8.0f, -0.6f, 0.55f);
    b.RoundedPolygon({C{1.3f, -1.0f, 0}, C{7.5f, -1.0f, 0}, C{6.9f, 7.59f, 0.9f}, C{1.9f, 7.59f, 0.9f}});
    b.RoundedPolygon({C{3.5f, -1.2f, 0.2f}, C{4.4f, -1.2f, 0.2f}, C{7.6f, -4.3f, 0.45f}, C{6.95f, -4.95f, 0.45f}});
    return b.Build();
}

// A mask's outline about its centre: a shield, its top a little wider than its chin.
void Shield(ShapeBuilder& b, float w, float h) {
    b.RoundedPolygon(
        {C{-w / 2, -h / 2, 1.6f}, C{w / 2, -h / 2, 1.6f}, C{w * 0.44f, h * 0.12f, 3.0f},  // the brow and right cheek
         C{0, h / 2, 2.6f}, C{-w * 0.44f, h * 0.12f, 3.0f}});
}

SymbolShape TheaterMasks() {
    // A smiling mask in front, up on the left, and a frowning one behind it on the right, the
    // front one cutting a gap round itself in the other: box -11..10.6 x -7.5..7.0.
    ShapeBuilder back;
    Shield(back, 10.4f, 13.6f);
    back.Cut().Circle(-2.1f, -1.9f, 0.8f).Circle(2.1f, -1.9f, 0.8f);
    back.Arc(0, 4.4f, 2.6f, 215, 325).Arc(0, 4.4f, 1.85f, 325, 215).Close();
    back.Rotate(16, 0, 0).Translate(4.25f, 1.72f);

    ShapeBuilder front;
    Shield(front, 10.6f, 12.2f);
    front.Cut().Arc(-2.3f, -1.5f, 1.05f, 180, 360).Close().Arc(2.3f, -1.5f, 1.05f, 180, 360).Close();
    front.Arc(0, 0.7f, 2.4f, 0, 180).Close();
    front.Rotate(-14, 0, 0).Translate(-4.86f, -0.67f);
    const SymbolShape face = front.Build();

    ShapeBuilder gap;
    gap.Cut();
    Shield(gap, 13.0f, 14.6f);
    gap.Rotate(-14, 0, 0).Translate(-4.86f, -0.67f);

    return ShapeBuilder().Append(back.Build()).Append(gap.Build()).Append(face).Build();
}

const std::vector<DrawnSymbol>& Drawn() {
    // In the Icon tab's order.
    static const std::vector<DrawnSymbol> drawn = {
        {"bookmark.fill", Bookmark()},
        {"pawprint.fill", Pawprint()},
        {"bed.double.fill", BedDouble()},
        {"fork.knife", ForkKnife()},
        {"dumbbell.fill", Dumbbell()},
        {"bandage.fill", Bandage()},
        {"baseball.fill", Baseball()},
        {"takeoutbag.and.cup.and.straw.fill", TakeoutBagAndCup()},
        {"theatermasks.fill", TheaterMasks()},
    };
    return drawn;
}

}  // namespace

const SymbolShape* SymbolShapeFor(std::string_view name) {
    for (const DrawnSymbol& d : Drawn()) {
        if (d.name == name) return &d.shape;
    }
    return nullptr;
}

const std::vector<std::string_view>& DrawnSymbols() {
    static const std::vector<std::string_view> names = [] {
        std::vector<std::string_view> out;
        for (const DrawnSymbol& d : Drawn()) out.push_back(d.name);
        return out;
    }();
    return names;
}

}  // namespace kite
