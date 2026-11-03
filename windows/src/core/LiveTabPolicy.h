#pragma once
// How many pages stay alive: the Mac's LiveTabPolicy (LiveTabPolicy.swift) and PagePool's
// isLinkedToPopup (PagePool.swift). The shell (shell/Chromium) keeps each page's last-shown
// time and closes what this picks, once the page says it isn't busy.

#include <map>
#include <set>
#include <string>
#include <vector>

#include "core/Models.h"

namespace kite {

struct LiveTabPolicy {
    size_t maxLiveTabs = 6;

    // `live`: the tabs that have a page, with when each was last shown. `protectedIDs`: the
    // ones that must stay (the shown tab). Returns the pages over the limit to close, least
    // recently shown first (ties by id, so the pick doesn't depend on the map's order).
    std::vector<std::string> TabsToEvict(const std::map<std::string, Timestamp>& live,
                                         const std::set<std::string>& protectedIDs) const;
};

// A popup and the tab that opened it talk through window.opener and postMessage (sign-in
// popups), so neither page may close while both tabs exist. `popupOpeners`: popup tab → opener.
bool IsLinkedToPopup(const std::map<std::string, std::string>& popupOpeners, const BrowserState& state,
                     const std::string& tabID);

}  // namespace kite
