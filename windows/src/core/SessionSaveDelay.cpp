// Port of KiteCore SessionSaveDelay.swift; see SessionSaveDelay.h.

#include "core/SessionSaveDelay.h"

#include <algorithm>

namespace kite {

double Seconds(SessionSaveDelay delay) {
    switch (delay) {
    case SessionSaveDelay::Soon: return 1;
    case SessionSaveDelay::PageEvent: return 10;
    }
    return 1;
}

std::string_view RawValue(SessionSaveDelay delay) { return delay == SessionSaveDelay::Soon ? "soon" : "pageEvent"; }

std::optional<SessionSaveDelay> SessionSaveDelayFromRaw(std::string_view raw) {
    if (raw == "soon") return SessionSaveDelay::Soon;
    if (raw == "pageEvent") return SessionSaveDelay::PageEvent;
    return std::nullopt;
}

std::optional<double> Rearm(SessionSaveDelay delay, std::optional<SessionSaveDelay> pending) {
    // A sidebar change always (re)arms, bringing a waiting page save forward; a page event
    // arms only when nothing waits, so a ticking title never pushes a save back.
    if (delay == SessionSaveDelay::Soon || !pending) return Seconds(delay);
    return std::nullopt;
}

std::optional<double> PendingSave::Arm(SessionSaveDelay delay) {
    auto seconds = Rearm(delay, pending);
    if (seconds) pending = delay;
    return seconds;
}

double CappedDebounce::Changed(double now) {
    const double since = pendingSince.value_or(now);
    pendingSince = since;
    return std::max(0.0, std::min(quiet, since + maxWait - now));
}

std::optional<double> SaveSchedule::Changed(SessionSaveDelay delay, double now) {
    auto seconds = pending_.Arm(delay);
    if (seconds) dueAt_ = now + *seconds;
    return seconds;
}

void SaveSchedule::Saved() {
    pending_.Saved();
    dueAt_.reset();
}

SaveReplay ReplaySaves(const std::vector<SaveChange>& changes, std::optional<double> until) {
    SaveSchedule schedule;
    SaveReplay replay;
    auto fireUntil = [&](double time) {
        // The timer fires at its deadline, before a change at or after it.
        if (schedule.DueAt() && *schedule.DueAt() <= time) {
            replay.saves.push_back({*schedule.DueAt(), *schedule.Pending()});
            schedule.Saved();
        }
    };
    for (const SaveChange& change : changes) {
        if (until && change.at > *until) break;
        fireUntil(change.at);
        schedule.Changed(change.delay, change.at);
    }
    if (until) {
        fireUntil(*until);
        replay.pending = schedule.Pending();
        replay.dueAt = schedule.DueAt();
    } else if (schedule.DueAt()) {
        fireUntil(*schedule.DueAt());
    }
    return replay;
}

}  // namespace kite
