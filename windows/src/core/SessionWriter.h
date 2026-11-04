#pragma once
// The app's session writer: session.json written as it changes, off the UI thread. The
// counterpart of the Mac's BrowserStore.saveNow and its backup queue (BrowserStore.swift), with
// the file write moved off the UI thread as well (docs/windows-architecture.md: no blocking
// work on the UI thread).
//
// The UI thread hands over a snapshot (a copy of the BrowserState, taken when the save timer
// fires, so many changes cost one copy) and goes on at once. One worker thread encodes it,
// skips it when the bytes are what it last wrote, writes it atomically (core/StoreFile.h) and
// keeps the hourly backup (core/SessionBackups.h). A snapshot still waiting when a newer one
// comes is dropped: the newer one has everything. The worker sleeps on a condition variable
// between saves, so an idle Kite has no wakeups from it.
//
// The copy shares the JSON the model doesn't know (each type's `extra`) with the live session:
// json::Value's arrays and objects are copy-on-write, and nothing changes them in place after
// loading (a change assigns a new value), so the worker reads them while the UI thread goes on.
//
// When to save is the caller's (core/SessionSaveDelay.h's SaveSchedule); quitting calls Save
// and then Flush, which waits for the write, so nothing handed over is lost.
//
// Everything public is for one thread (Kite's UI thread), except Statistics.

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "core/Models.h"
#include "core/SessionStore.h"

namespace kite {

class SessionWriter {
public:
    // `maySave` false (SessionStore::MaySave said so): nothing is ever written, not even backups.
    // `now`: the clock backups are dated by (Unix seconds); tests pass their own.
    explicit SessionWriter(SessionStore store, bool maySave = true, std::function<double()> now = SessionBackups::Now);
    // Writes what's waiting, then stops the worker.
    ~SessionWriter();
    SessionWriter(const SessionWriter&) = delete;
    SessionWriter& operator=(const SessionWriter&) = delete;

    const SessionStore& Store() const { return store_; }
    bool MaySave() const { return maySave_; }

    // Hands `snapshot` to the worker and returns at once.
    void Save(BrowserState snapshot);
    // The session as found at launch, kept as a launch backup (the Mac's init backs up `found`).
    void BackUpLaunch(BrowserState found);
    // Waits until everything handed over is written. The last write's error, empty when it
    // went well (or nothing was written).
    std::string Flush();

    struct Statistics {
        uint64_t handedOver = 0;  // Save calls
        uint64_t written = 0;     // session.json writes that went through
        uint64_t unchanged = 0;   // snapshots whose bytes matched the last write: no disk access
        uint64_t superseded = 0;  // snapshots dropped for a newer one before the worker got to them
        uint64_t backups = 0;     // backups made (launch and hourly)
        bool pending = false;     // a snapshot waiting or being written
        double lastEncodeMicros = 0;
        double lastWriteMicros = 0;  // the atomic write, flushed to the disk
        size_t lastBytes = 0;
        std::string lastError;
        std::string lastBackupError;
    };
    Statistics Stats() const;

private:
    void Run();
    void Write(const BrowserState& state);

    const SessionStore store_;
    const bool maySave_;
    const std::function<double()> now_;

    mutable std::mutex mutex_;
    std::condition_variable wake_;  // the worker: work or stop
    std::condition_variable done_;  // Flush: the worker caught up
    std::optional<BrowserState> next_;
    std::optional<BrowserState> launch_;
    bool busy_ = false;
    bool stop_ = false;
    Statistics stats_;
    // The bytes last written (worker only), so an unchanged snapshot costs no write.
    std::string lastWritten_;
    std::thread worker_;  // last: started once the rest exists
};

}  // namespace kite
