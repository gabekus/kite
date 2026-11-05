#pragma once
// The SF Symbols that neither Segoe icon font has an object for (bookmark, paw, bed, cutlery,
// dumbbell, bandage, baseball, takeaway bag, theatre masks), and the briefcase, whose Segoe
// glyph is a plain case, drawn as Kite's own geometry: simple original shapes, each sized and
// placed to the ink box the Mac's symbol makes at the same point size, with its inked area and
// weight (numbers measured from the Mac's renders, docs/windows.md). Nothing here is Apple's
// outline or fitted to it.
//
// A shape is layers of filled figures in points for a 12.5 pt icon (the space bar's), its origin
// on the point the icon is centred on; it scales with the icon's size. Each layer is added to
// what's drawn so far or cut out of it, in order (so a front mask can cut a gap round itself in
// the one behind). In a layer, figures fill with the nonzero rule, each made clockwise here
// whichever way it was written, so overlapping figures join.

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

// Builds figures, then orients them (clockwise on screen, y down).
class ShapeBuilder {
public:
    // After a Close (or a whole figure), a Line or an Arc starts a new figure at its own first point
    // (a Line's end) and a Cubic at the last point.
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
    // A polygon through `corners`, each rounded to its own radius (clamped to fit its edges; a
    // corner repeated straight after itself counts once).
    struct Corner {
        float x = 0, y = 0, radius = 0;
    };
    ShapeBuilder& RoundedPolygon(const std::vector<Corner>& corners);
    // Another shape's layers after these, as they are.
    ShapeBuilder& Append(const SymbolShape& shape);
    // The figures after this are a new layer cut out of everything before (Cut) or added to it
    // (Add).
    ShapeBuilder& Cut();
    ShapeBuilder& Add();
    // Turns everything so far `degrees` clockwise about (cx, cy).
    ShapeBuilder& Rotate(float degrees, float cx, float cy);
    // Moves everything so far by (dx, dy).
    ShapeBuilder& Translate(float dx, float dy);
    SymbolShape Build();

private:
    std::vector<ShapeFigure>& Figures() { return shape_.layers.back().figures; }
    void Map(float a, float b, float c, float d, float e, float f);  // x' = ax + cy + e, y' = bx + dy + f
    SymbolShape shape_{{ShapeLayer{}}};
    bool open_ = false;
    ShapePoint current_;
};

// A straight stroke from `a` to `b`, `half` its width either side, with round ends: a rounded
// rectangle round the line (the top row's X and reload's chevron, the empty favorites' close button).
void AddStroke(ShapeBuilder& builder, ShapePoint a, ShapePoint b, float half);

// The bounds of the added layers' figures (a cut that trims an edge isn't counted), which the
// header's placement centres. For tests: whether (x, y) is inked, and the inked area in square
// points (exact along rows `step` apart).
ShapeBounds BoundsOf(const SymbolShape& shape);
bool Covers(const SymbolShape& shape, float x, float y);
float InkedArea(const SymbolShape& shape, float step = 0.02f);

// The shape for an SF Symbol name, for the names drawn this way; none for every other.
const SymbolShape* SymbolShapeFor(std::string_view name);
// The names drawn this way, in the Icon tab's order, then "briefcase".
const std::vector<std::string_view>& DrawnSymbols();
// The size shapes are designed at (the bar's icon size).
inline constexpr float kSymbolShapeSize = 12.5f;
// The page header's icon size, where each shape has its own place (below).
inline constexpr float kHeaderSymbolSize = 15.0f;

// Where a drawn symbol draws for an icon `size` points: scaled by `scale` about its origin, which
// goes `dx`, `dy` points from the icon's centre. At the bar's 12.5 the shape already sits as the
// Mac's ink does in its cell. The Mac redraws a symbol at the header's 15 and places it by
// metrics it rounds to the half point (SidebarKit's place(.center)), which Kite's shapes don't
// have, so each shape carries the centre of the Mac's 15pt ink in its slot, measured from the
// Mac's header renders (as the Mac's own SymbolOrigins are): its ink box's middle goes there.
// Any other size scales the bar's placement.
struct ShapePlacement {
    const SymbolShape* shape = nullptr;
    float scale = 1, dx = 0, dy = 0;
};
// The shape and where it goes; none for a name that isn't drawn.
std::optional<ShapePlacement> PlaceDrawnSymbol(std::string_view name, float size);

}  // namespace kite
