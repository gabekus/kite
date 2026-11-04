// Ports of KiteCore's LiveTabPolicyTests (KiteCoreTests.swift), plus PagePool's
// isLinkedToPopup and edge cases the Mac doesn't check.

#include "Check.h"
#include "core/LiveTabPolicy.h"
#include "core/Uuid.h"

using namespace kite;

TEST(evictsLeastRecentlyShownFirst) {
    std::vector<std::string> ids;
    std::map<std::string, Timestamp> live;
    for (int i = 0; i < 5; ++i) {
        ids.push_back(NewUuid());
        live[ids.back()] = i;
    }
    const LiveTabPolicy policy{3};
    CHECK(policy.TabsToEvict(live, {}) == (std::vector<std::string>{ids[0], ids[1]}));
    CHECK(policy.TabsToEvict(live, {ids[0]}) == (std::vector<std::string>{ids[1], ids[2]}));
    CHECK(LiveTabPolicy{5}.TabsToEvict(live, {}).empty());
}

TEST(theLimitIsAtLeastOneAndProtectedTabsCanLeaveItOver) {
    std::map<std::string, Timestamp> live{{"a", 1}, {"b", 2}, {"c", 3}};
    // A limit of 0 keeps one page, as max(maxLiveTabs, 1).
    CHECK(LiveTabPolicy{0}.TabsToEvict(live, {}) == (std::vector<std::string>{"a", "b"}));
    // Over the limit with everything protected: nothing to close.
    CHECK(LiveTabPolicy{1}.TabsToEvict(live, {"a", "b", "c"}).empty());
    // Only the excess goes, even when the oldest are protected.
    CHECK(LiveTabPolicy{2}.TabsToEvict(live, {"a"}) == (std::vector<std::string>{"b"}));
    // Ties go by id.
    CHECK(LiveTabPolicy{1}.TabsToEvict({{"y", 5}, {"x", 5}}, {}) == (std::vector<std::string>{"x"}));
    // The Mac's default.
    CHECK(LiveTabPolicy{}.maxLiveTabs == 6);
}

TEST(aPopupAndItsOpenerAreLinkedWhileBothTabsExist) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const std::string opener = state.OpenTab("https://shop.example");
    const std::string popup = state.OpenTab("https://accounts.example");
    const std::string other = state.OpenTab("https://news.example");
    const std::map<std::string, std::string> openers{{popup, opener}};
    CHECK(IsLinkedToPopup(openers, state, popup));
    CHECK(IsLinkedToPopup(openers, state, opener));
    CHECK(!IsLinkedToPopup(openers, state, other));
    // Once either tab is gone, the other is on its own again.
    state.Close(popup);
    CHECK(!IsLinkedToPopup(openers, state, opener));
}

// LiveTabPolicyTests.hibernationIsDroppedWhenTheTabChangedDuringItsBusyCheck
TEST(hibernationIsDroppedWhenTheTabChangedDuringItsBusyCheck) {
    const Timestamp picked = 10;
    CHECK(LiveTabPolicy::StillHibernates(picked, picked, true, false));
    // Shown again (and maybe hidden again) while the check ran.
    CHECK(!LiveTabPolicy::StillHibernates(picked, Timestamp{11}, true, false));
    CHECK(!LiveTabPolicy::StillHibernates(picked, picked, true, true));
    // Another page under the tab id (made again).
    CHECK(!LiveTabPolicy::StillHibernates(picked, picked, false, false));
    // Already gone.
    CHECK(!LiveTabPolicy::StillHibernates(picked, std::nullopt, true, false));
    CHECK(!LiveTabPolicy::StillHibernates(std::nullopt, std::nullopt, true, false));
}

// PagePool.watchMemoryPressure: warning and critical both hibernate every page not on screen.
TEST(memoryPressureDiscardsEveryPageNotOnScreen) {
    CHECK(!DiscardsPages(MemoryPressure::Normal));
    CHECK(DiscardsPages(MemoryPressure::Warning));
    CHECK(DiscardsPages(MemoryPressure::Critical));
    std::map<std::string, Timestamp> live{{"c", 3}, {"a", 1}, {"b", 2}, {"shown", 0}};
    // Under the live-tab limit, still all but the shown one, oldest first.
    CHECK(TabsToDiscardUnderPressure(live, {"shown"}) == (std::vector<std::string>{"a", "b", "c"}));
    CHECK(LiveTabPolicy{6}.TabsToEvict(live, {"shown"}).empty());
    // Ties by id, so the order doesn't depend on the map's.
    CHECK(TabsToDiscardUnderPressure({{"y", 1}, {"x", 1}}, {}) == (std::vector<std::string>{"x", "y"}));
    CHECK(TabsToDiscardUnderPressure({{"only", 1}}, {"only"}).empty());
    CHECK(TabsToDiscardUnderPressure({}, {}).empty());
}
