#pragma once
// The SF Symbols that neither Segoe icon font has an object for (bookmark, paw, bed, cutlery,
// dumbbell, bandage, baseball, takeaway bag, theatre masks), drawn as Kite's own geometry: simple
// original shapes, each sized and placed to the ink the Mac's symbol makes at the same point
// size (measured from the Mac's renders, docs/windows.md). Nothing here is Apple's outline.
//
// A shape is layers of filled figures in points for a 12.5 pt icon (the space bar's), its origin
// on the point the icon is centred on; it scales with the icon's size. Each layer is added to
// what's drawn so far or cut out of it, in order (so a front mask can cut a gap round itself in
// the one behind). In a layer, figures fill with the nonzero rule, solids clockwise and holes
// counter-clockwise (made so here whichever way they were written), so overlapping solids join
// and a hole cuts every solid of its layer under it once.

#include <optional>
#include <string_view>
#include <vector>

namespace kite {

struct ShapePoint {
    float x = 0, y = 0;
    bool operator==(const ShapePoint&) const = default;
};

// One closed figure: from `start`, each segment a line (to `to`) or a cubic Bézier (through `c1`
// and `c2` to `to`).
struct ShapeSegment {
    bool cubic = false;
    ShapePoint c1, c2, to;
};
struct ShapeFigure {
    ShapePoint start;
    std::vector<ShapeSegment> segments;
    bool hole = false;
};

struct ShapeLayer {
    bool cut = false;
    std::vector<ShapeFigure> figures;
};
struct SymbolShape {
    std::vector<ShapeLayer> layers;
};

// The ink's bounds, in the shape's points.
struct ShapeBounds {
    float left = 0, top = 0, right = 0, bottom = 0;
    float Width() const { return right - left; }
    float Height() const { return bottom - top; }
};

// Builds figures, then orients them (solids clockwise on screen, y down; holes the other way).
class ShapeBuilder {
public:
    ShapeBuilder& Move(float x, float y);
    ShapeBuilder& Line(float x, float y);
    ShapeBuilder& Cubic(float x1, float y1, float x2, float y2, float x, float y);
    // An arc of the circle centred on (cx, cy), radius r, from angle a0 to a1 (degrees, clockwise
    // on screen from +x; a1 < a0 goes the other way), as cubics, joined to the current point by a
    // line (or starting the figure).
    ShapeBuilder& Arc(float cx, float cy, float r, float a0, float a1);
    ShapeBuilder& Close();
    // Whole figures.
    // An ellipse turned `degrees` clockwise about its centre.
    ShapeBuilder& Ellipse(float cx, float cy, float rx, float ry, float degrees = 0);
    ShapeBuilder& Circle(float cx, float cy, float r) { return Ellipse(cx, cy, r, r); }
    ShapeBuilder& RoundRect(float left, float top, float right, float bottom, float radius);
    // A polygon through `corners`, each rounded to its own radius (clamped to fit its edges).
    struct Corner {
        float x = 0, y = 0, radius = 0;
    };
    ShapeBuilder& RoundedPolygon(const std::vector<Corner>& corners);
    // Another shape's layers after these, as they are.
    ShapeBuilder& Append(const SymbolShape& shape);
    // The next figure (and every one after, until Solid()) is a hole.
    ShapeBuilder& Hole();
    ShapeBuilder& Solid();
    // The figures after this are a new layer cut out of everything before (Cut) or added to it
    // (Add).
    ShapeBuilder& Cut();
    ShapeBuilder& Add();
    // Turns everything so far `degrees` clockwise about (cx, cy).
    ShapeBuilder& Rotate(float degrees, float cx, float cy);
    // Maps everything so far by x' = x * sx + dx, y' = y * sy + dy.
    ShapeBuilder& Scale(float sx, float sy, float dx = 0, float dy = 0);
    SymbolShape Build();

private:
    std::vector<ShapeFigure>& Figures() { return shape_.layers.back().figures; }
    void Map(float a, float b, float c, float d, float e, float f);  // x' = ax + cy + e, y' = bx + dy + f
    SymbolShape shape_{{ShapeLayer{}}};
    bool open_ = false, hole_ = false;
    ShapePoint current_;
};

// A layer's figures flattened to polygons, each about `tolerance` points from its curves.
std::vector<std::vector<ShapePoint>> Flatten(const ShapeLayer& layer, float tolerance = 0.01f);
// The bounds of the added layers' figures (a cut that trims an edge isn't counted).
ShapeBounds BoundsOf(const SymbolShape& shape);
// Whether (x, y) is inked (the nonzero rule).
bool Covers(const SymbolShape& shape, float x, float y);
// The inked area in square points (sampled on a grid `step` apart, for tests).
float InkedArea(const SymbolShape& shape, float step = 0.05f);

// The shape for an SF Symbol name, for the names drawn this way; none for every other.
const SymbolShape* SymbolShapeFor(std::string_view name);
// The names drawn this way, in the Icon tab's order.
const std::vector<std::string_view>& DrawnSymbols();
// The size shapes are designed at (the bar's icon size).
inline constexpr float kSymbolShapeSize = 12.5f;

}  // namespace kite
