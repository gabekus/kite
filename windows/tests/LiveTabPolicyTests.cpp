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
