#pragma once
// How many pages stay alive: the Mac's LiveTabPolicy (LiveTabPolicy.swift) and PagePool's
// isLinkedToPopup and watchMemoryPressure (PagePool.swift). The shell (shell/Chromium) keeps
// each page's last-shown time and closes what this picks, once the page says it isn't busy.

#include <map>
#include <optional>
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

    // A tab picked to close waits on an asynchronous busy check (media, camera or mic). When it
    // answers, the close still goes ahead only if the tab has the page it had when picked
    // (`samePage`), isn't on screen, and hasn't been shown since (`shownAt` is when it was last
    // shown, then and now).
    static bool StillHibernates(std::optional<Timestamp> pickedShownAt, std::optional<Timestamp> shownAt, bool samePage,
                                bool visible);
};

// The system's memory pressure, as the Mac's DispatchSource memory-pressure levels. Windows'
// low-memory resource notification (shell/MemoryPressure.h) reports Critical while it's
// signalled; it has no earlier warning to wait on.
enum class MemoryPressure { Normal, Warning, Critical };

// The low-memory watch's state machine (shell/MemoryPressure waits on what it says). Windows'
// low and high notifications are level-triggered, so the watch waits for low, reports it, then
// waits for high (recovered) before low again: one report a spell. Two things keep a spell from
// going unreported: a low signal that's over by the time the callback looks is no spell (it
// waits for low again), and when the window finds memory no longer low as it handles a report,
// it says so (Recovered), and the watch goes back to waiting for low rather than for high, so
// memory that hovers between the two levels and then runs low again is reported again.
class MemoryPressureLatch {
public:
    struct Step {
        std::optional<MemoryPressure> report;  // what to post to the window, if anything
        bool waitForLow = true;                // which notification to wait on next
    };
    bool WaitingForLow() const { return waitingForLow_; }
    // The awaited notification was signalled; `lowNow`: whether memory is low as it's checked.
    Step Signalled(bool lowNow);
    // The window found memory no longer low: true when the watch must go back to waiting for low.
    bool Recovered();

private:
    bool waitingForLow_ = true;
};

// Whether `level` closes the background pages: the Mac's source watches [.warning, .critical]
// and both hibernate every page that isn't on screen.
bool DiscardsPages(MemoryPressure level);

// Under memory pressure: every live page but the protected ones (on screen), least recently
// shown first (ties by id). Each is still asked whether it's busy before it closes, and a page
// tied to a popup stays, as the live-tab limit's picks do.
std::vector<std::string> TabsToDiscardUnderPressure(const std::map<std::string, Timestamp>& live,
                                                    const std::set<std::string>& protectedIDs);

// A popup and the tab that opened it talk through window.opener and postMessage (sign-in
// popups), so neither page may close while both tabs exist. `popupOpeners`: popup tab → opener.
bool IsLinkedToPopup(const std::map<std::string, std::string>& popupOpeners, const BrowserState& state,
                     const std::string& tabID);

}  // namespace kite
