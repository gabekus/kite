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
        // The UI gate's four (review/w9e-mac picker-icon): the Mac's 16pt Icon tab ink, less the
        // gate's half-point halo, scaled to 12.5 (the bar's own aren't measured yet).
        {"cylinder.split.1x2.fill", -5.27f, 5.27f, -6.45f, 6.45f, 98.0f},
        {"pawprint.fill", -6.5f, 7.0f, -6.5f, 6.5f, 94.5f},
        {"bed.double.fill", -8, 8, -5.5f, 5.5f, 109.2f},
        {"fork.knife", -4.5f, 4.5f, -7.58f, 7.0f, 61.9f},
        {"dumbbell.fill", -8.5f, 8.5f, -4.63f, 5.0f, 90.2f},
        {"bandage.fill", -6.62f, 6.14f, -6.13f, 6.63f, 68.6f},
        {"chevron.left.forwardslash.chevron.right", -8.79f, 8.79f, -5.86f, 5.86f, 62.0f},
        {"baseball.fill", -6.5f, 6.5f, -6.5f, 6.5f, 101.6f},
        {"takeoutbag.and.cup.and.straw.fill", -8, 8, -7.0f, 7.59f, 165.9f},
        {"theatermasks.fill", -11.0f, 10.6f, -7.5f, 7.0f, 183.6f},
        {"scroll.fill", -6.64f, 6.64f, -6.45f, 6.45f, 122.0f},
        {"tram.fill", -5.47f, 5.47f, -7.81f, 7.81f, 104.0f},
        // review/w9d-mac rest.png and w9b-mac two-spaces.png (the same box lit and greyed); the
        // area from the dark one, where no grain adds to it. Kite's own case: only the box, the
        // area, the centre and the stroke weight are the Mac's.
        {"briefcase", -7.5f, 7.0f, -6.0f, 6.5f, 87.1f},
    };
    CHECK(DrawnSymbols().size() == std::size(mac));
    if (DrawnSymbols().size() != std::size(mac)) return;
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
    // A seam (the left one's middle, the ball turned 20 degrees) between inked leather.
    const SymbolShape& ball = *SymbolShapeFor("baseball.fill");
    CHECK(Covers(ball, 0, 0) && !Covers(ball, -2.35f, -0.86f) && Covers(ball, -4.2f, -1.5f));
    // Both masks, the gap between them across the middle, and the front one's open mouth.
    const SymbolShape& masks = *SymbolShapeFor("theatermasks.fill");
    CHECK(Covers(masks, -5, -4) && Covers(masks, 5, 3));
    CHECK(Covers(masks, -0.75f, 0) && !Covers(masks, 0.25f, 0) && Covers(masks, 1.0f, 0));
    CHECK(!Covers(masks, -4.4f, 1.17f) && Covers(masks, -4.4f, 4.0f));
    // Every other cut and part, each next to ink: the masks' eyes and the back one's mouth, the
    // bandage's cuts, a stitch, the gap round the cup and the straw, the fork's head under its
    // tines, a toe apart from the next.
    const auto pinned = [](const char* name, float x, float y, float inkX, float inkY) {
        const SymbolShape& shape = *SymbolShapeFor(name);
        return !Covers(shape, x, y) && Covers(shape, inkX, inkY);
    };
    CHECK(pinned("theatermasks.fill", 2.76f, -0.69f, 2.40f, 0.56f));    // the back mask's eye
    CHECK(pinned("theatermasks.fill", 3.64f, 3.83f, 3.89f, 2.97f));     // its frown
    CHECK(pinned("theatermasks.fill", -7.55f, -1.96f, -7.89f, -3.32f));  // the front mask's eye
    CHECK(pinned("bandage.fill", 1.63f, -1.62f, 2.31f, -2.30f));
    CHECK(pinned("baseball.fill", -1.55f, -0.56f, -1.86f, 0.28f));
    CHECK(pinned("takeoutbag.and.cup.and.straw.fill", 0.4f, 2.0f, -1.0f, 2.0f) &&
          Covers(*SymbolShapeFor("takeoutbag.and.cup.and.straw.fill"), 3.5f, 2.0f));
    CHECK(pinned("takeoutbag.and.cup.and.straw.fill", 5.0f, -3.6f, 5.95f, -2.9f));  // the straw
    CHECK(pinned("fork.knife", -3.25f, -5.5f, -3.25f, -3.0f));
    CHECK(pinned("pawprint.fill", 0.25f, -4.4f, -1.75f, -4.4f) && Covers(*SymbolShapeFor("pawprint.fill"), -4.95f, -0.7f));
    CHECK(!Covers(*SymbolShapeFor("pawprint.fill"), -1.75f, -2.0f));  // between a toe and the pad
}

TEST(eachDrawnSymbolInksTheMacsBoxInTheHeader) {
    // The Mac's page header at 15pt (2x): each symbol's ink box from its 26pt slot's centre, the
    // ink more than half covered, so to the 2x render's half point (review/w9b4-mac's slot crops;
    // the briefcase from review/w9b-mac two-spaces.png, its slot [13,150 26x26]). The painter
    // draws a shape scaled and moved by PlaceDrawnSymbol; that inks the Mac's box to within that
    // half point's rounding (0.35pt; scaling the bar's place instead puts five of them 0.4 to
    // 0.63pt off). The slot clips the masks' sides, so only their height is here.
    struct Mac {
        const char* name;
        float left, right, top, bottom;
    };
    const Mac mac[] = {
        {"bookmark.fill", -5.0f, 5.5f, -8.0f, 8.5f},
        // The UI gate's four: no header render, so the bar's box scaled (1.2), centred.
        {"cylinder.split.1x2.fill", -6.32f, 6.32f, -7.74f, 7.74f},
        {"chevron.left.forwardslash.chevron.right", -10.55f, 10.55f, -7.03f, 7.03f},
        {"scroll.fill", -7.97f, 7.97f, -7.74f, 7.74f},
        {"tram.fill", -6.56f, 6.56f, -9.37f, 9.37f},
        {"pawprint.fill", -8.0f, 8.0f, -7.5f, 8.0f},
        {"bed.double.fill", -9.5f, 9.5f, -6.5f, 6.5f},
        {"fork.knife", -5.5f, 5.0f, -9.0f, 8.5f},
        {"dumbbell.fill", -10.0f, 10.0f, -5.5f, 6.0f},
        {"bandage.fill", -7.5f, 8.0f, -7.5f, 8.0f},
        {"baseball.fill", -7.5f, 7.5f, -7.5f, 8.0f},
        {"takeoutbag.and.cup.and.straw.fill", -9.5f, 9.5f, -8.5f, 9.0f},
        {"theatermasks.fill", 0, 0, -8.5f, 8.5f},
        {"briefcase", -9.0f, 8.5f, -7.5f, 7.5f},
    };
    CHECK(std::size(mac) == DrawnSymbols().size());
    for (const Mac& m : mac) {
        const auto place = PlaceDrawnSymbol(m.name, kHeaderSymbolSize);
        CHECK(place && Near(place->scale, 1.2f, 1e-6f));
        if (!place) continue;
        CHECK(place->shape == SymbolShapeFor(m.name));
        const ShapeBounds b = BoundsOf(*place->shape);
        const float left = b.left * place->scale + place->dx, right = b.right * place->scale + place->dx;
        const float top = b.top * place->scale + place->dy, bottom = b.bottom * place->scale + place->dy;
        const bool across = m.left == m.right || (Near(left, m.left, 0.35f) && Near(right, m.right, 0.35f));
        const bool down = Near(top, m.top, 0.35f) && Near(bottom, m.bottom, 0.35f);
        if (!across || !down) std::fprintf(stderr, "%s header: %.2f %.2f %.2f %.2f\n", m.name, left, right, top, bottom);
        CHECK(across && down);
    }
    // The bar's 12.5 is the shape as it is; any other size scales it about the icon's centre.
    const auto bar = PlaceDrawnSymbol("briefcase", kSymbolShapeSize);
    CHECK(bar && bar->scale == 1 && bar->dx == 0 && bar->dy == 0);
    const auto other = PlaceDrawnSymbol("briefcase", 25);
    CHECK(other && other->scale == 2 && other->dx == 0 && other->dy == 0);
    CHECK(!PlaceDrawnSymbol("star.fill", kHeaderSymbolSize));
}

TEST(aRoundedPolygonsRepeatedCornerCountsOnce) {
    using C = ShapeBuilder::Corner;
    const SymbolShape square =
        ShapeBuilder().RoundedPolygon({C{0, 0, 1}, C{4, 0, 1}, C{4, 0, 1}, C{4, 4, 1}, C{0, 4, 1}, C{0, 0, 1}}).Build();
    const ShapeBounds b = BoundsOf(square);
    CHECK(Near(b.left, 0) && Near(b.right, 4) && Near(b.top, 0) && Near(b.bottom, 4));
    CHECK(Near(InkedArea(square), 16 - (4 - 3.14159f), 0.05f));
}
