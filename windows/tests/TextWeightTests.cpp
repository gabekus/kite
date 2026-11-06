// Kite-wide text weight (core/TextWeight.h): the Mac's SF Pro weights as Segoe UI Variable's axes
// (Windows 11) and Segoe UI's named weights (Windows 10). Windows-only: the Mac draws SF itself.

#include <cmath>

#include "Check.h"
#include "core/TextWeight.h"

using namespace kite;
namespace W = kite::text_weight;

namespace {
bool Near(float a, float b) { return std::fabs(a - b) < 0.001f; }
// Heavier on Segoe UI Variable: more weight, or as much at a smaller optical size (the smaller
// optical sizes ink heavier). The renders' ink steps (each 5% or more, 11–18pt) are the PR's.
bool Heavier(W::VariableSetting a, W::VariableSetting b) {
    return a.weight > b.weight + 20 || (a.weight >= b.weight && a.opticalSize < b.opticalSize - 1);
}
}  // namespace

TEST(theOpticalSizeIsTheSizeInWindowsPoints) {
    // Kite's sizes are the Mac's points, which are DIPs; Segoe UI Variable's opsz is in points at 96 DPI.
    CHECK(Near(W::OpticalSize(14), 10.5f));
    CHECK(Near(W::OpticalSize(13), 9.75f));
    CHECK(Near(W::OpticalSize(18), 13.5f));
    // Clamped to the axis.
    CHECK(Near(W::OpticalSize(4), W::kMinOpticalSize));
    CHECK(Near(W::OpticalSize(100), W::kMaxOpticalSize));
    CHECK(Near(W::OpticalSize(NAN), W::kTextOpticalSize));
}

TEST(eachMacWeightMapsHigherOnTheWeightAxis) {
    // SF inks heavier than Segoe at the same weight, so each lands above its own number.
    CHECK(Near(W::Variable(MacWeight::Regular, 14).weight, 590));
    CHECK(Near(W::Variable(MacWeight::Medium, 14).weight, 650));
    CHECK(Near(W::Variable(MacWeight::Semibold, 14).weight, 675));
    CHECK(Near(W::Variable(MacWeight::Bold, 14).weight, 700));
    for (const MacWeight weight : W::kAllWeights) {
        CHECK(W::Variable(weight, 14).weight > static_cast<float>(W::MacWeightValue(weight)) - 0.001f);
    }
    // Regular follows the size's optical size all the way; medium and semibold (and bold, where
    // there's no Segoe UI Black) follow it above the Text instance only.
    CHECK(Near(W::Variable(MacWeight::Regular, 11).opticalSize, 8.25f));
    CHECK(Near(W::Variable(MacWeight::Medium, 13).opticalSize, W::kTextOpticalSize));
    CHECK(Near(W::Variable(MacWeight::Semibold, 12).opticalSize, W::kTextOpticalSize));
    CHECK(Near(W::Variable(MacWeight::Semibold, 15).opticalSize, 11.25f));
    CHECK(Near(W::Variable(MacWeight::Medium, 18).opticalSize, 13.5f));
    CHECK(Near(W::Variable(MacWeight::Bold, 17).opticalSize, 12.75f));
    CHECK(Near(W::Variable(MacWeight::Bold, 12).opticalSize, W::kTextOpticalSize));
}

TEST(windows11DrawsBoldInSegoeUIBlack) {
    // Past the weight axis: Segoe UI Variable's 700 inks under the semibold beside it.
    CHECK(W::Windows11UsesBlack(MacWeight::Bold));
    CHECK(W::kBoldBlackWeight == 900);
    for (const MacWeight weight : {MacWeight::Regular, MacWeight::Medium, MacWeight::Semibold}) CHECK(!W::Windows11UsesBlack(weight));
}

TEST(regularGivesBackWhatTheSmallOpticalSizesAdd) {
    // At and above the Text instance's 10.5 (14pt) regular is 590; below it, 22 a point less.
    CHECK(Near(W::Variable(MacWeight::Regular, 15).weight, 590));
    CHECK(Near(W::Variable(MacWeight::Regular, 13).weight, 590 - 22 * 0.75f));
    CHECK(Near(W::Variable(MacWeight::Regular, 11).weight, 590 - 22 * 2.25f));
    CHECK(W::Variable(MacWeight::Regular, 11).weight < W::Variable(MacWeight::Regular, 13).weight);
    // Never off the axis, at the smallest size there is.
    CHECK(W::Variable(MacWeight::Regular, 1).weight >= W::kMinWeightAxis);
}

TEST(theMacsHierarchyStaysApartAtEverySize) {
    // regular < medium < semibold < bold, never two the same, on both faces.
    for (float size = 6; size <= 40; size += 0.5f) {
        const W::VariableSetting r = W::Variable(MacWeight::Regular, size), m = W::Variable(MacWeight::Medium, size),
                                 s = W::Variable(MacWeight::Semibold, size), b = W::Variable(MacWeight::Bold, size);
        CHECK(Heavier(m, r));
        CHECK(Heavier(s, m));
        CHECK(Heavier(b, s));
        for (const W::VariableSetting v : {r, m, s, b}) {
            CHECK(v.weight >= W::kMinWeightAxis && v.weight <= W::kMaxWeightAxis);
            CHECK(v.opticalSize >= W::kMinOpticalSize && v.opticalSize <= W::kMaxOpticalSize);
        }
    }
}

TEST(windows10KeepsTodaysWeights) {
    // Segoe UI's Regular, Semibold and Bold: medium is the Semibold its 500 matched before (Segoe UI
    // has no Medium); regular can't go past 400, so nothing above it steps further.
    CHECK(W::StaticWeight(MacWeight::Regular) == 400);
    CHECK(W::StaticWeight(MacWeight::Medium) == 600);
    CHECK(W::StaticWeight(MacWeight::Semibold) == 600);
    CHECK(W::StaticWeight(MacWeight::Bold) == 700);
}

TEST(weightsHaveTheMacsNames) {
    for (const MacWeight weight : W::kAllWeights) CHECK(W::ParseWeight(W::Name(weight)) == weight);
    CHECK(W::Name(MacWeight::Semibold) == "semibold");
    CHECK(W::MacWeightValue(MacWeight::Medium) == 500);
    CHECK(!W::ParseWeight("heavy"));
    CHECK(!W::ParseWeight(""));
}
