// Chromium's browser-process switches as Kite gives them (core/ChromiumSwitches.h): Chromium's
// native occlusion tracker is off by default, --chromium-switches turns it back on, and the
// feature lists merge with what CEF already has. On Windows, also --chromium-switches' allow-list
// (shell/PerfProtocol.h) for the override.

#include "Check.h"
#include "core/ChromiumSwitches.h"

#ifdef _WIN32
#include "shell/PerfProtocol.h"
#endif

using namespace kite::chromium_switches;

namespace {

using Switches = std::vector<std::string>;

}  // namespace

TEST(nativeOcclusionIsOffByDefault) {
    CHECK(BrowserSwitches({}, "", "") == Switches{"disable-features=CalculateNativeWinOcclusion"});
    CHECK(FeatureProblem({}, "", "", "", "CalculateNativeWinOcclusion").empty());
    CHECK(!FeatureProblem({}, "", "", "", "").empty());
    CHECK(!FeatureProblem({}, "", "", "", "SomethingElse").empty());
}

TEST(theDefaultMergesWithExistingDisabledFeatures) {
    // CEF's own list stays, first; the default goes after it.
    CHECK(BrowserSwitches({}, "", "A,B<Trial") == Switches{"disable-features=A,B<Trial,CalculateNativeWinOcclusion"});
    // Already there: the list isn't repeated, nor the feature.
    CHECK(BrowserSwitches({}, "", "A,CalculateNativeWinOcclusion").empty());
    CHECK(BrowserSwitches({}, "", "*CalculateNativeWinOcclusion").empty());
    // An existing enable-features is left alone.
    CHECK(BrowserSwitches({}, "X", "") == Switches{"disable-features=CalculateNativeWinOcclusion"});
}

TEST(requestedSwitchesComeFirstAndFeatureListsMerge) {
    const Switches requested = {"disable-gpu-vsync", "disable-features=BackForwardCache", "renderer-process-limit=4",
                                "disable-features=IntensiveWakeUpThrottling,BackForwardCache"};
    CHECK(BrowserSwitches(requested, "", "A") ==
          (Switches{"disable-gpu-vsync", "renderer-process-limit=4",
                    "disable-features=A,CalculateNativeWinOcclusion,BackForwardCache,IntensiveWakeUpThrottling"}));
    // The old "off" arm's explicit switch is the default, once.
    CHECK(BrowserSwitches({"disable-features=CalculateNativeWinOcclusion"}, "", "") ==
          Switches{"disable-features=CalculateNativeWinOcclusion"});
}

TEST(enableFeaturesTurnsTheTrackerBackOn) {
    const Switches on = {"enable-features=CalculateNativeWinOcclusion"};
    CHECK(BrowserSwitches(on, "", "") == Switches{"enable-features=CalculateNativeWinOcclusion"});
    CHECK(BrowserSwitches(on, "X", "A") == Switches{"enable-features=X,CalculateNativeWinOcclusion"});
    // Never both: a disable from CEF, or from the same request, loses to the request's enable.
    CHECK(BrowserSwitches(on, "", "A,CalculateNativeWinOcclusion,B") ==
          (Switches{"enable-features=CalculateNativeWinOcclusion", "disable-features=A,B"}));
    CHECK(BrowserSwitches(on, "", "CalculateNativeWinOcclusion") ==
          (Switches{"enable-features=CalculateNativeWinOcclusion", "disable-features="}));
    CHECK(BrowserSwitches({"enable-features=CalculateNativeWinOcclusion", "disable-features=CalculateNativeWinOcclusion,BackForwardCache"}, "", "") ==
          (Switches{"enable-features=CalculateNativeWinOcclusion", "disable-features=BackForwardCache"}));
    CHECK(FeatureProblem(on, "", "", "CalculateNativeWinOcclusion", "").empty());
    CHECK(!FeatureProblem(on, "", "", "", "").empty());
    CHECK(!FeatureProblem(on, "", "", "", "CalculateNativeWinOcclusion").empty());
}

TEST(cefTurningTheTrackerOnIsLeftOnAndFlagged) {
    // Adding a disable would make it both; the smoke test's check says so instead.
    CHECK(BrowserSwitches({}, "CalculateNativeWinOcclusion", "").empty());
    CHECK(!FeatureProblem({}, "", "", "CalculateNativeWinOcclusion", "").empty());
    CHECK(!FeatureProblem({}, "", "", "CalculateNativeWinOcclusion", "CalculateNativeWinOcclusion").empty());
}

TEST(theSmokeCheckNamesTheTrackerAndKeepsCefsOwnFeatures) {
    // By name: nothing in disable-features fails, whatever DefaultDisabledFeatures() says.
    CHECK(FeatureProblem({}, "", "", "", "").find("CalculateNativeWinOcclusion") != std::string::npos);
    // CEF's own features stay: one dropped from either list fails.
    CHECK(FeatureProblem({}, "X", "A,B", "X", "A,B,CalculateNativeWinOcclusion").empty());
    CHECK(!FeatureProblem({}, "", "A,B", "", "A,CalculateNativeWinOcclusion").empty());
    CHECK(!FeatureProblem({}, "X", "", "", "CalculateNativeWinOcclusion").empty());
    // ...but a CEF-disabled one a request turned on is gone from disable-features, as it should be.
    const Switches on = {"enable-features=CalculateNativeWinOcclusion"};
    CHECK(FeatureProblem(on, "", "A,CalculateNativeWinOcclusion", "CalculateNativeWinOcclusion", "A").empty());
    // What BrowserSwitches makes always passes.
    for (const Switches& requested : {Switches{}, on, Switches{"disable-features=BackForwardCache"}}) {
        std::string enable = "X", disable = "A,B<T";
        for (const std::string& entry : BrowserSwitches(requested, enable, disable)) {
            if (entry.starts_with("enable-features=")) enable = entry.substr(16);
            if (entry.starts_with("disable-features=")) disable = entry.substr(17);
        }
        CHECK(FeatureProblem(requested, "X", "A,B<T", enable, disable).empty());
    }
}

TEST(featureNamesDropTrialsParametersAndStars) {
    CHECK(FeatureNames("A,B<Trial.Group,*C:p/v,,D<T:x/y") == (Switches{"A", "B", "C", "D"}));
    CHECK(FeatureNames("").empty());
}

#ifdef _WIN32
TEST(chromiumSwitchesAllowTheTrackerBackOnOnly) {
    using kite::perf::AllowedChromiumSwitch;
    using kite::perf::ParseChromiumSwitches;
    CHECK(AllowedChromiumSwitch("enable-features", "CalculateNativeWinOcclusion"));
    CHECK(AllowedChromiumSwitch("disable-features", "CalculateNativeWinOcclusion"));
    CHECK(!AllowedChromiumSwitch("enable-features", "BackForwardCache"));
    CHECK(!AllowedChromiumSwitch("enable-features", "CalculateNativeWinOcclusion,RemoteDebugging"));
    CHECK(!AllowedChromiumSwitch("enable-features", ""));
    std::wstring refused;
    const auto parsed = ParseChromiumSwitches(L"--enable-features=CalculateNativeWinOcclusion --disable-features=BackForwardCache", refused);
    CHECK(parsed && *parsed == (Switches{"enable-features=CalculateNativeWinOcclusion", "disable-features=BackForwardCache"}));
    // On and off at once is refused, whichever comes first.
    CHECK(!ParseChromiumSwitches(L"--enable-features=CalculateNativeWinOcclusion --disable-features=CalculateNativeWinOcclusion", refused));
    CHECK(refused == L"--disable-features=CalculateNativeWinOcclusion");
    CHECK(!ParseChromiumSwitches(L"--disable-features=BackForwardCache,CalculateNativeWinOcclusion --enable-features=CalculateNativeWinOcclusion", refused));
    CHECK(refused == L"--enable-features=CalculateNativeWinOcclusion");
}
#endif
