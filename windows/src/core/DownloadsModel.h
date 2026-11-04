#pragma once
// The app's downloads list as the Mac's DownloadsModel (KiteMac/DownloadsModel.swift) keeps it,
// without the shell: what the engine reports goes through its rules here, and each change says
// when downloads.json is next written, so the shell arms one one-shot timer and kitecore and the
// tests replay the same decisions.
//
// Its rules: an incognito session that ended takes no more reports (a late one mustn't bring its
// row back); a finished download is final (a late progress tick or repeat changes nothing);
// incognito downloads are never saved; a download starting or finishing is written 0.2 s later,
// a progress tick 5 s later, and a progress tick never pushes back a save that's already waiting,
// so a download that reports forever still gets saved (saveSoon(after:)).
//
// Windows reads downloads.json on a worker (core/DownloadsWriter.h), so the list read from disk
// can arrive after this launch's first download: Restore joins it under the live ones, and until
// then nothing is saved (a save then would replace the file's history with this launch's alone).
//
// Not ported: the source tab titles kept for Tidy Downloads (Arc Max), which isn't on Windows,
// and WebKit's downloads (Windows has one engine).

#include <optional>
#include <set>
#include <string>

#include "core/Downloads.h"

namespace kite {

// DownloadsModel.saveSoon(after:)'s timer: the seconds to (re)arm it with, or none to leave a
// waiting save alone.
class DownloadsSaveSchedule {
public:
    static constexpr double kSoon = 0.2;      // a download started, finished or left the list
    static constexpr double kProgress = 5.0;  // only its bytes moved

    // A change wanting a save `delay` seconds from `now` (any steady clock).
    std::optional<double> Changed(double delay, double now);
    std::optional<double> DueAt() const { return dueAt_; }
    // The save ran (the timer fired, or Kite is closing and saves at once).
    void Saved() { dueAt_.reset(); }

private:
    std::optional<double> dueAt_;
};

class DownloadsModel {
public:
    const DownloadList& List() const { return list_; }

    // What one report did. `save`: seconds to (re)arm the save timer with, none to leave it.
    struct Outcome {
        bool applied = false;   // false: dropped (an ended incognito session, a finished download)
        bool isNew = false;     // the download's first report (the Mac's didStartDownload)
        bool stateChanged = false;
        DownloadItem item;
        std::optional<double> save;
    };
    // `now`: the steady clock the save timer runs on; `wall`: the item's startedAt when it's new.
    Outcome Apply(const DownloadUpdate& update, double now, Timestamp wall = Now());

    // The list read from downloads.json (on the worker) arrives. `canSave` false: it couldn't be
    // read, or not all of it, and couldn't be kept aside, so nothing is written this launch. The
    // seconds to arm the save timer with, when this launch's downloads are waiting to be saved.
    std::optional<double> Restore(const DownloadList& restored, bool canSave, double now);
    // Whether a save may be handed to the writer: the file has been read and may be replaced.
    bool MaySave() const { return restored_ && canSave_; }
    bool Restored() const { return restored_; }

    // The engine had already let a download go when it was asked to cancel it (it finished in
    // between): it shows as canceled (DownloadsModel.cancel's fallback, which saves nothing).
    void CanceledWithoutEngine(const DownloadItem& item);
    // An incognito window closed: its downloads leave the list, and later reports for it are
    // dropped. Their files stay.
    void EndIncognitoSession(const std::string& context);
    // Hide from the list (the file stays); clear the finished ones; Delete browsing data's
    // download history since a date (none: all); a file moved. Each returns the save delay.
    std::optional<double> Remove(const std::string& id, double now);
    std::optional<double> ClearFinished(double now);
    std::optional<double> RemoveHistory(std::optional<Timestamp> since, double now);
    std::optional<double> Moved(const std::string& id, const std::string& path, double now);

    // The save timer (the shell's one-shot timer follows it).
    DownloadsSaveSchedule& Schedule() { return schedule_; }

private:
    std::optional<double> SaveSoon(double delay, double now);

    DownloadList list_;
    std::set<std::string> endedIncognitoContexts_;
    DownloadsSaveSchedule schedule_;
    bool restored_ = false;
    bool canSave_ = true;
    bool savePending_ = false;  // a change waits for Restore before it can be saved
};

}  // namespace kite
