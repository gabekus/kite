// Port of KiteMac's DownloadsModel.swift (its rules, not its shell); see DownloadsModel.h.

#include "core/DownloadsModel.h"

namespace kite {

std::optional<double> DownloadsSaveSchedule::Changed(double delay, double now) {
    // A save already waiting isn't pushed back by a tick; anything sooner replaces it.
    if (dueAt_ && delay > 1.0) return std::nullopt;
    dueAt_ = now + delay;
    return delay;
}

DownloadsModel::Outcome DownloadsModel::Apply(const DownloadUpdate& update, double now, Timestamp wall) {
    Outcome outcome;
    // Its incognito window has closed: a late update mustn't bring the row back.
    if (update.isIncognito && endedIncognitoContexts_.contains(update.engineContext)) return outcome;
    const DownloadItem* existing = list_.Item(update.engineID, update.engineContext);
    const std::optional<DownloadState> previous = existing ? std::optional(existing->state) : std::nullopt;
    // A finished download is final: a late progress tick would mark it in progress again, and a
    // late repeat would put back a path that's since been renamed.
    if (previous == DownloadState::Complete) return outcome;
    auto [item, isNew] = list_.Apply(update, wall);
    outcome.applied = true;
    outcome.isNew = isNew;
    outcome.stateChanged = previous != update.state;
    outcome.item = std::move(item);
    // Incognito downloads never leave Kite: nothing written to downloads.json.
    if (outcome.item.isIncognito) return outcome;
    // Progress ticks don't need a write each; a download starting or finishing does.
    outcome.save = SaveSoon(outcome.stateChanged ? DownloadsSaveSchedule::kSoon : DownloadsSaveSchedule::kProgress, now);
    return outcome;
}

std::optional<double> DownloadsModel::Restore(const DownloadList& restored, bool canSave, double now) {
    if (restored_) return std::nullopt;
    restored_ = true;
    canSave_ = canSave;
    list_.AdoptRestored(restored);
    if (!savePending_ || !canSave_) return std::nullopt;
    savePending_ = false;
    return SaveSoon(DownloadsSaveSchedule::kSoon, now);
}

void DownloadsModel::CanceledWithoutEngine(const DownloadItem& item) {
    if (!item.engineID || item.state != DownloadState::InProgress) return;
    DownloadUpdate update;
    update.engineID = *item.engineID;
    update.engineContext = item.engineContext.value_or("");
    update.isIncognito = item.isIncognito;
    update.url = item.url;
    update.path = item.path;
    update.state = DownloadState::Canceled;
    update.receivedBytes = item.receivedBytes;
    update.totalBytes = item.totalBytes;
    list_.Apply(update);
}

void DownloadsModel::EndIncognitoSession(const std::string& context) {
    endedIncognitoContexts_.insert(context);
    list_.RemoveIncognito(context);
}

std::optional<double> DownloadsModel::Remove(const std::string& id, double now) {
    list_.Remove(id);
    return SaveSoon(DownloadsSaveSchedule::kSoon, now);
}

std::optional<double> DownloadsModel::ClearFinished(double now) {
    list_.ClearFinished();
    return SaveSoon(DownloadsSaveSchedule::kSoon, now);
}

std::optional<double> DownloadsModel::RemoveHistory(std::optional<Timestamp> since, double now) {
    list_.RemoveHistory(since);
    return SaveSoon(DownloadsSaveSchedule::kSoon, now);
}

std::optional<double> DownloadsModel::Moved(const std::string& id, const std::string& path, double now) {
    if (!list_.SetPath(path, id)) return std::nullopt;
    return SaveSoon(DownloadsSaveSchedule::kSoon, now);
}

std::optional<double> DownloadsModel::SaveSoon(double delay, double now) {
    // Before the file has been read, a save would replace its history: it waits for Restore.
    if (!restored_) {
        savePending_ = true;
        return std::nullopt;
    }
    if (!canSave_) return std::nullopt;
    return schedule_.Changed(delay, now);
}

}  // namespace kite
