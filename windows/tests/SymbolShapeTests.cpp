// The drawn symbols' geometry (core/SymbolShape.h): the builder's figures, their bounds and fill.

#include <cmath>
#include <cstdio>
#include <iterator>

#include "Check.h"
#include "core/SymbolShape.h"

using namespace kite;

namespace {
bool Near(float a, float b, float within = 0.01f) { return std::fabs(a - b) <= within; }
}  // namespace

TEST(aShapesCircleAndRoundedRectHaveTheirBoundsAndArea) {
    const SymbolShape circle = ShapeBuilder().Circle(1, 2, 3).Build();
    const ShapeBounds c = BoundsOf(circle);
    CHECK(Near(c.left, -2) && Near(c.right, 4) && Near(c.top, -1) && Near(c.bottom, 5));
    CHECK(Near(InkedArea(circle, 0.02f), 3.14159f * 9, 0.05f));
    const SymbolShape rect = ShapeBuilder().RoundRect(0, 0, 4, 2, 0.5f).Build();
    const ShapeBounds r = BoundsOf(rect);
    CHECK(Near(r.left, 0) && Near(r.right, 4) && Near(r.top, 0) && Near(r.bottom, 2));
    CHECK(Near(InkedArea(rect, 0.02f), 8 - (4 - 3.14159f) * 0.25f, 0.03f));
    CHECK(Covers(rect, 2, 1) && !Covers(rect, 0.02f, 0.02f) && !Covers(rect, 5, 1));
}

TEST(aShapesCutsAndJoinsGoInOrderWhicheverWayFiguresWereWritten) {
    // A cut layer takes its figures out of what's before it, and a later added layer puts ink back.
    const SymbolShape ring = ShapeBuilder().Circle(0, 0, 3).Cut().Circle(0, 0, 1).Build();
    CHECK(!Covers(ring, 0, 0) && Covers(ring, 2, 0));
    CHECK(Near(InkedArea(ring, 0.02f), 3.14159f * 8, 0.06f));
    // A solid written anticlockwise still fills, and overlapping solids join (nonzero).
    const SymbolShape two = ShapeBuilder().Move(0, 0).Line(0, 2).Line(2, 2).Line(2, 0).Close().RoundRect(1, 0, 3, 2, 0).Build();
    CHECK(Covers(two, 0.5f, 1) && Covers(two, 1.5f, 1) && Covers(two, 2.5f, 1));
    CHECK(Near(InkedArea(two, 0.02f), 6, 0.02f));
    const SymbolShape dot = ShapeBuilder().Circle(0, 0, 3).Cut().Circle(0, 0, 2).Add().Circle(0, 0, 1).Build();
    CHECK(Covers(dot, 0, 0) && !Covers(dot, 1.5f, 0) && Covers(dot, 2.5f, 0));
    CHECK(Near(InkedArea(dot, 0.02f), 3.14159f * 6, 0.06f));
    // A cut before anything is inked takes nothing.
    const SymbolShape first = ShapeBuilder().Cut().Circle(0, 0, 1).Add().Circle(0, 0, 2).Build();
    CHECK(Covers(first, 0, 0) && Near(InkedArea(first, 0.02f), 3.14159f * 4, 0.04f));
}

TEST(anArcRunsEitherWayRoundItsCircle) {
    // A half disc: the arc over the top (clockwise on screen from 180 to 360), closed by its diameter.
    const SymbolShape top = ShapeBuilder().Arc(0, 0, 2, 180, 360).Close().Build();
    const ShapeBounds b = BoundsOf(top);
    CHECK(Near(b.left, -2) && Near(b.right, 2) && Near(b.top, -2) && Near(b.bottom, 0));
    // The same half going back (from 0 to -180).
    const ShapeBounds back = BoundsOf(ShapeBuilder().Arc(0, 0, 2, 0, -180).Close().Build());
    CHECK(Near(back.top, -2) && Near(back.bottom, 0));
    CHECK(Near(InkedArea(top, 0.02f), 3.14159f * 2, 0.04f));
}

TEST(eachDrawnSymbolInksTheMacsBoxWithItsWeight) {
    // The Mac's bar at 12.5 pt (review/w9b4-mac, 2x): each symbol's ink box from the cell's centre,
    // to a quarter point, and its inked area in square points. The shapes are Kite's own; they
    // match the box and come within an eighth of the area, so each sits and weighs as the Mac's.
    struct Mac {
        const char* name;
        float left, right, top, bottom, area;
    };
    const Mac mac[] = {
        {"bookmark.fill", -4.5f, 4.5f, -6.58f, 7.0f, 106.4f},
        {"pawprint.fill", -6.5f, 7.0f, -6.5f, 6.5f, 94.5f},
        {"bed.double.fill", -8, 8, -5.5f, 5.5f, 109.2f},
        {"fork.knife", -4.5f, 4.5f, -7.58f, 7.0f, 61.9f},
        {"dumbbell.fill", -8.5f, 8.5f, -4.63f, 5.0f, 90.2f},
        {"bandage.fill", -6.62f, 6.14f, -6.13f, 6.63f, 68.6f},
        {"baseball.fill", -6.5f, 6.5f, -6.5f, 6.5f, 101.6f},
        {"takeoutbag.and.cup.and.straw.fill", -8, 8, -7.0f, 7.59f, 165.9f},
        {"theatermasks.fill", -11.0f, 10.6f, -7.5f, 7.0f, 183.6f},
    };
    CHECK(DrawnSymbols().size() == std::size(mac));
    for (size_t i = 0; i < std::size(mac); ++i) {
        const Mac& m = mac[i];
        CHECK(DrawnSymbols()[i] == m.name);
        const SymbolShape* shape = SymbolShapeFor(m.name);
        CHECK(shape);
        if (!shape) continue;
        const ShapeBounds b = BoundsOf(*shape);
        const bool boxed =
            Near(b.left, m.left, 0.25f) && Near(b.right, m.right, 0.25f) && Near(b.top, m.top, 0.25f) && Near(b.bottom, m.bottom, 0.25f);
        if (!boxed) std::fprintf(stderr, "%s: %.2f %.2f %.2f %.2f\n", m.name, b.left, b.right, b.top, b.bottom);
        CHECK(boxed);
        const float area = InkedArea(*shape);
        if (std::fabs(area - m.area) > m.area / 8) std::fprintf(stderr, "%s: area %.1f\n", m.name, area);
        CHECK(std::fabs(area - m.area) <= m.area / 8);
    }
    CHECK(!SymbolShapeFor("star.fill") && !SymbolShapeFor(""));
}

TEST(aDrawnSymbolsHolesAndGapsShowThrough) {
    // What makes each read as its object: the notch, the bed's pillow openings, the bandage's pad
    // holes, the seams, the bag's handle slot, the gap round the front mask and its mouth.
    CHECK(!Covers(*SymbolShapeFor("bookmark.fill"), 0, 6.5f) && Covers(*SymbolShapeFor("bookmark.fill"), 0, 0));
    CHECK(!Covers(*SymbolShapeFor("bed.double.fill"), -2.8f, -2.6f) && Covers(*SymbolShapeFor("bed.double.fill"), 0, 1));
    // A pad hole (0.85, 0.85 along and across the strip, turned 45 degrees) and the pad's middle.
    CHECK(!Covers(*SymbolShapeFor("bandage.fill"), 0.96f, 0.25f) && Covers(*SymbolShapeFor("bandage.fill"), -0.24f, 0.25f));
    CHECK(!Covers(*SymbolShapeFor("takeoutbag.and.cup.and.straw.fill"), -3.2f, -5.5f));
    CHECK(Covers(*SymbolShapeFor("baseball.fill"), 0, 0));
    const SymbolShape& masks = *SymbolShapeFor("theatermasks.fill");
    CHECK(Covers(masks, -5, -4) && Covers(masks, 5, 3));
    CHECK(!Covers(*SymbolShapeFor("pawprint.fill"), -1.75f, -2.0f));  // between a toe and the pad
}
