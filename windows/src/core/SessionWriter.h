#pragma once
// The app's session writer: session.json written as it changes, off the UI thread. The
// counterpart of the Mac's BrowserStore.saveNow and its backup queue (BrowserStore.swift), with
// the file write moved off the UI thread as well (docs/windows-architecture.md: no blocking
// work on the UI thread).
//
// The UI thread hands over a snapshot (a copy of the BrowserState, taken when the save timer
// fires, so many changes cost one copy) and goes on at once. One worker thread encodes it,
// skips the write when the bytes are what it last wrote, writes it atomically
// (core/StoreFile.h) and offers the hourly backup after every save, as the Mac does
// (core/SessionBackups.h). A snapshot still waiting when a newer one comes is dropped: the
// newer one has everything. The worker sleeps on a condition variable between saves, so an
// idle Kite has no wakeups from it.
//
// The copy shares the JSON the model doesn't know (each type's `extra`) with the live session:
// json::Value's arrays and objects are copy-on-write, and nothing changes them in place after
// loading (a change assigns a new value), so the worker reads them while the UI thread goes on.
//
// When to save is the caller's (core/SessionSaveDelay.h's SaveSchedule). Quitting calls Save,
// then Flush once the window is gone. Every wait is bounded: a disk that hangs can't hang Kite,
// and giving up is safe, since the atomic write leaves either the old file or the new one. The
// worker's state is shared with it (not owned by this object), so a worker still writing when
// the writer goes is let go and finishes, or dies with the process, on its own.
//
// The thread itself, its bounded waits and OnStuck, are core/BackgroundWorker.h's, which
// history's store (core/HistoryStore.h) shares.
//
// Everything public is for one thread (Kite's UI thread), except Stats.

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "core/BackgroundWorker.h"
#include "core/Models.h"
#include "core/SessionStore.h"

namespace kite {

class SessionWriter {
public:
    // How long the destructor waits for a write still running before it lets the worker go.
    static constexpr std::chrono::milliseconds kStopWait = WorkerThread::kStopWait;

    // `maySave` false (SessionStore::MaySave said so): nothing is ever written, not even backups.
    // `now`: the clock backups are dated by (Unix seconds); tests pass their own. It runs on the
    // worker, which can outlive this object (see OnStuck), so it must not capture by reference.
    explicit SessionWriter(SessionStore store, bool maySave = true, std::function<double()> now = SessionBackups::Now);
    // Writes what's waiting (for kStopWait at most, or not at all after a Flush timed out), then
    // stops the worker. A worker still writing then is let go, after OnStuck's handler runs.
    ~SessionWriter();
    SessionWriter(const SessionWriter&) = delete;
    SessionWriter& operator=(const SessionWriter&) = delete;

    bool MaySave() const { return maySave_; }

    // Hands `snapshot` to the worker and returns at once.
    void Save(BrowserState snapshot);
    // The session as found at launch, kept as a launch backup (the Mac's init backs up `found`).
    void BackUpLaunch(BrowserState found);
    // Waits, for `timeout` at most, until everything handed over is written. The last write's
    // error, empty when it went well (or nothing was written); a timeout is an error too.
    std::string Flush(std::chrono::milliseconds timeout = std::chrono::milliseconds::max());
    // The same with a deadline shared with another store's wait (logoff, quitting).
    std::string Flush(Deadline deadline);
    // The session didn't change, but the Mac would save it anyway (its auto-archive pass
    // always mutates): the hourly backup of what was last written is offered, on the worker,
    // with nothing copied or written. False when nothing has been written this run (the caller
    // saves instead).
    bool OfferBackup();
    // Whether the worker still has something to write, right now (after a Flush timed out,
    // whether it really is stuck).
    bool Writing() const;
    // Runs when the destructor has to let a worker go that's still writing. The app ends the
    // process from it (without static destruction, which would tear the C library down under
    // the thread); without one the thread is detached.
    void OnStuck(std::function<void()> stuck) { worker_.OnStuck(std::move(stuck)); }

    struct Statistics {
        uint64_t handedOver = 0;  // Save calls
        uint64_t written = 0;     // session.json writes that went through
        uint64_t unchanged = 0;   // snapshots whose bytes matched the last write: no write
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

    struct Shared;  // the worker's state (SessionWriter.cpp)

private:
    const bool maySave_;
    std::shared_ptr<Shared> shared_;
    WorkerThread worker_;
};

}  // namespace kite
