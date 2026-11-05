#include "core/LiveTabPolicy.h"

#include <algorithm>

namespace kite {

std::vector<std::string> LiveTabPolicy::TabsToEvict(const std::map<std::string, Timestamp>& live,
                                                    const std::set<std::string>& protectedIDs) const {
    const size_t limit = std::max<size_t>(maxLiveTabs, 1);
    if (live.size() <= limit) return {};
    const size_t excess = live.size() - limit;
    std::vector<std::pair<Timestamp, std::string>> candidates;
    for (const auto& [id, shown] : live) {
        if (!protectedIDs.contains(id)) candidates.emplace_back(shown, id);
    }
    std::sort(candidates.begin(), candidates.end());
    std::vector<std::string> evict;
    for (size_t i = 0; i < candidates.size() && i < excess; ++i) evict.push_back(std::move(candidates[i].second));
    return evict;
}

bool LiveTabPolicy::StillHibernates(std::optional<Timestamp> pickedShownAt, std::optional<Timestamp> shownAt, bool samePage,
                                    bool visible) {
    if (!samePage || visible || !pickedShownAt) return false;
    return shownAt == pickedShownAt;
}

MemoryPressureLatch::Step MemoryPressureLatch::Signalled(bool lowNow) {
    if (waitingForLow_) {
        // Low, unless it's already over: then no spell, and low is waited for again.
        if (!lowNow) return Step{std::nullopt, true};
        waitingForLow_ = false;
        return Step{MemoryPressure::Critical, false};
    }
    waitingForLow_ = true;
    return Step{MemoryPressure::Normal, true};
}

bool MemoryPressureLatch::Recovered() {
    if (waitingForLow_) return false;
    waitingForLow_ = true;
    return true;
}

bool DiscardsPages(MemoryPressure level) { return level == MemoryPressure::Warning || level == MemoryPressure::Critical; }

std::vector<std::string> TabsToDiscardUnderPressure(const std::map<std::string, Timestamp>& live,
                                                    const std::set<std::string>& protectedIDs) {
    std::vector<std::pair<Timestamp, std::string>> candidates;
    for (const auto& [id, shown] : live) {
        if (!protectedIDs.contains(id)) candidates.emplace_back(shown, id);
    }
    std::sort(candidates.begin(), candidates.end());
    std::vector<std::string> out;
    out.reserve(candidates.size());
    for (auto& candidate : candidates) out.push_back(std::move(candidate.second));
    return out;
}

bool IsLinkedToPopup(const std::map<std::string, std::string>& popupOpeners, const BrowserState& state,
                     const std::string& tabID) {
    return std::any_of(popupOpeners.begin(), popupOpeners.end(), [&](const auto& entry) {
        const auto& [popup, opener] = entry;
        return (popup == tabID || opener == tabID) && state.FindTabByID(popup) && state.FindTabByID(opener);
    });
}

}  // namespace kite
