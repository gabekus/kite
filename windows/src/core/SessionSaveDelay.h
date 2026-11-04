#pragma once
// When the session is written after a change: a port of KiteCore's SessionSaveDelay.swift
// (SessionSaveDelay, PendingSave, CappedDebounce), plus SaveSchedule, the timer the Mac's
// BrowserStore.scheduleSave arms with them. Sidebar changes and navigations save a second
// after the last one. A page's title and favicon change all the time (a page can set
// document.title every second), so they wait longer and don't push back a save that's
// already waiting: a page that never stops ticking still gets saved. Quitting and closing
// the window save at once.

#include <optional>
#include <string_view>
#include <vector>

namespace kite {

enum class SessionSaveDelay {
    Soon,       // a change to the sidebar, the selection, a tab's URL or settings
    PageEvent,  // a title or favicon reported by a page
};

double Seconds(SessionSaveDelay delay);
std::string_view RawValue(SessionSaveDelay delay);  // "soon", "pageEvent", as the Swift cases
std::optional<SessionSaveDelay> SessionSaveDelayFromRaw(std::string_view raw);

// The delay to arm the save timer with for a change of kind `delay`, when a save of kind
// `pending` is already waiting (none: nothing is), or none to leave the waiting save alone.
std::optional<double> Rearm(SessionSaveDelay delay, std::optional<SessionSaveDelay> pending);

// The waiting save of a debounced file (session.json): what kind of change it's for.
struct PendingSave {
    std::optional<SessionSaveDelay> pending;

    // A change of kind `delay`: the seconds to (re)arm the save timer with, or none to leave
    // the waiting save as it is.
    std::optional<double> Arm(SessionSaveDelay delay);
    // The save happened (or was cancelled for an immediate one).
    void Saved() { pending.reset(); }
    bool operator==(const PendingSave&) const = default;
};

// A trailing debounce that still saves at least every `maxWait` seconds while changes keep
// coming (the Mac's history.json while a page's title ticks).
struct CappedDebounce {
    double quiet = 0;
    double maxWait = 0;
    // When the first change not yet saved came in; none when everything is saved.
    std::optional<double> pendingSince;

    // A change at `now` (seconds on any steady clock): how long to arm the save timer for.
    double Changed(double now);
    void Saved() { pendingSince.reset(); }
};

// The session's save timer as BrowserStore drives it: PendingSave's rules with the time the
// waiting save is due, so the shell arms one one-shot timer (no polling) and a headless run
// (kitecore save-schedule, the tests) replays the same decisions.
class SaveSchedule {
public:
    // A change of kind `delay` at `now` (seconds, any steady clock). The seconds to (re)arm
    // the timer with, or none to leave it as it is.
    std::optional<double> Changed(SessionSaveDelay delay, double now);
    // The waiting save's kind and when it's due; none when nothing is waiting.
    std::optional<SessionSaveDelay> Pending() const { return pending_.pending; }
    std::optional<double> DueAt() const { return dueAt_; }
    bool IsDue(double now) const { return dueAt_ && now >= *dueAt_; }
    // The save ran (the timer fired, or the window closed and saved at once).
    void Saved();

private:
    PendingSave pending_;
    std::optional<double> dueAt_;
};

// A headless run of the save timer (kitecore save-schedule, the tests): the saves a run of
// changes makes, each when the shell's one-shot timer would fire, and what's still waiting at
// `until` (none: after the last change, with every waiting save fired).
struct SaveChange {
    double at = 0;
    SessionSaveDelay delay = SessionSaveDelay::Soon;
};
struct ReplayedSave {
    double at = 0;
    SessionSaveDelay kind = SessionSaveDelay::Soon;  // the change the save waited for
};
struct SaveReplay {
    std::vector<ReplayedSave> saves;
    std::optional<SessionSaveDelay> pending;
    std::optional<double> dueAt;
};
// `changes` in time order.
SaveReplay ReplaySaves(const std::vector<SaveChange>& changes, std::optional<double> until = std::nullopt);

}  // namespace kite
