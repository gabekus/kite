#pragma once
// Browsing history on disk, for every profile: the Mac's HistoryStore (KiteMac/HistoryStore.swift),
// with the default profile's store leading to the others'. The default profile's history is
// history.json in the support folder; another profile's is Chromium/<dir>/Kite History.json, so
// deleting the profile deletes it.
//
// Threads. Everything public is for one thread (Kite's UI thread). One worker thread
// (core/BackgroundWorker.h, shared with the session's writer) does every store's disk work, in
// order, as the Mac's "history-writes" queue: it reads each file once Kite knows it's the one
// running (Start; another profile's the first time it's asked for after that), and it encodes and
// writes the snapshots the UI thread hands it. A snapshot is a copy of the History, which costs a
// few hundred pointer copies (History.h: shards shared and copied on write), so saving never
// copies the entries on the UI thread, and never waits on the disk.
//
// Until its file has been read, a store records what happens (visits, titles) and replays it
// over what the file held once it arrives (Adopt, when the worker's wake comes); it saves
// nothing before then, so it can't write over history it hasn't read. A search before then
// sees only this run's visits.
//
// When to save is the Mac's: a change saves 3 s after the last one, and at least every 30 s
// while changes keep coming (CappedDebounce, a page whose title keeps ticking); an import saves
// at once. The shell keeps one timer for all the stores (NextSaveIn, SaveDue). Quitting saves
// everything (SaveNow) and waits for the writes, for a bounded time (Flush): giving up is safe,
// since the atomic write leaves the old file or the new one.

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/BackgroundWorker.h"
#include "core/History.h"
#include "core/SessionSaveDelay.h"

namespace kite {

class HistoryStores;

// One profile's history. Made by HistoryStores; UI thread only.
class HistoryStore {
public:
    HistoryStore(const HistoryStore&) = delete;
    HistoryStore& operator=(const HistoryStore&) = delete;

    const History& Get() const { return history_; }
    const std::filesystem::path& File() const;
    // Whether the file has been read (or found missing or unreadable) and is in Get().
    bool IsLoaded() const { return adopted_; }
    // The file couldn't be read: why (empty when it read, or there was none).
    const std::string& LoadError() const { return loadError_; }

    // Each returns whether the history changed (a save is then waiting). A page history doesn't
    // keep, or a title the entry already has (a page re-setting document.title), changes nothing.
    bool RecordVisit(std::string_view url, std::string_view title, Timestamp at);
    bool UpdateTitle(std::string_view url, std::string_view title);
    std::vector<HistoryEntry> Search(std::string_view query, size_t limit, Timestamp now) const {
        return history_.Search(query, limit, now);
    }
    // Import from Arc (W33a): saved at once. Returns how many pages were new. Before the file has
    // been read the pages are only queued, to merge over it once it is (0 then).
    size_t Merge(std::vector<HistoryEntry> entries);

    struct Slot;  // what the worker shares with this store (HistoryStore.cpp)

private:
    friend class HistoryStores;
    HistoryStore(HistoryStores& owner, std::shared_ptr<Slot> slot);

    void Changed();     // saves after the debounce
    void ChangedNow();  // saves at once
    void Save();        // the Mac's saveNow, for this store
    void Adopt(History loaded, std::string error);

    HistoryStores& owner_;
    std::shared_ptr<Slot> slot_;
    History history_;
    // What happened before the file was read, to replay over it.
    std::vector<std::function<void(History&)>> pending_;
    std::string loadError_;
    bool loadPosted_ = false;
    bool adopted_ = false;
    bool dirty_ = false;
    bool saveWhenLoaded_ = false;
    CappedDebounce debounce_;
    std::optional<double> dueAt_;  // on the steady clock
};

class HistoryStores {
public:
    // CappedDebounce(quiet: 3, maxWait: 30), as the Mac's.
    static constexpr double kQuiet = 3;
    static constexpr double kMaxWait = 30;

    // Reads nothing yet: Start does. `steadyNow` is the clock the saves are timed by (seconds);
    // tests pass their own.
    explicit HistoryStores(std::filesystem::path supportDirectory, std::function<double()> steadyNow = {});
    // Lets the worker finish what it was given (WorkerThread::Stop): call Flush first to save.
    ~HistoryStores();
    HistoryStores(const HistoryStores&) = delete;
    HistoryStores& operator=(const HistoryStores&) = delete;

    // The files may be read now: this Kite is the one running (Chromium started, as the session's
    // launch backup waits for), or it's a capture. Before this a second launch, which hands over
    // to the running Kite, never opens the running Kite's history.
    void Start();
    // `directory`'s history (BrowserState::kDefaultProfile: history.json). Another profile's file
    // is read the first time it's asked for (after Start).
    HistoryStore& ForProfile(const std::string& directory);
    static std::filesystem::path FileFor(const std::filesystem::path& supportDirectory, const std::string& directory);

    // Called on the worker's thread when a file has been read; the shell posts itself a message
    // and calls Adopt on the UI thread. Set it before Start, or call Adopt after setting it.
    void SetWake(std::function<void()> wake);
    // Takes in the files read since the last call. True when a store's history changed (a
    // command bar showing it should look again). Each file that couldn't be read adds
    // "<file>: <why>" to `problems`.
    bool Adopt(std::vector<std::string>* problems = nullptr);

    // The shell's one save timer: seconds until the next store's save is due, none when no save
    // is waiting. Ask again after any change and after SaveDue.
    std::optional<double> NextSaveIn() const;
    // The timer fired: saves the stores whose time has come.
    void SaveDue();
    // Saves every store that changed (closing the window, quitting).
    void SaveNow();
    // Quitting, or Windows ending the session: waits (until `deadline` at most, which the
    // session's writer shares) for the reads and writes under way, saves what's still unsaved (a
    // failed write included), and waits for that. The last error, empty when everything was
    // written; running out of time is an error too.
    std::string Flush(Deadline deadline = Deadline::max());
    // Whether the worker still has a read or write under way, right now.
    bool Writing() const { return thread_.Writing(); }
    // Runs when the destructor has to let a worker go that's still busy (WorkerThread::OnStuck).
    void OnStuck(std::function<void()> stuck) { thread_.OnStuck(std::move(stuck)); }
    // --capture: waits (for `timeout` at most) until every file asked for is read, and takes them
    // in, so the command bar's rows are the ones the history holds. False on a timeout.
    bool WaitForLoads(std::chrono::milliseconds timeout);

    struct Statistics {
        uint64_t loads = 0;
        uint64_t writes = 0;  // that went through
        uint64_t failedWrites = 0;
        uint64_t superseded = 0;  // snapshots dropped for a newer one of the same file
        double lastLoadMicros = 0;
        double lastEncodeMicros = 0;
        double lastWriteMicros = 0;
        size_t lastBytes = 0;
        std::string lastError;
    };
    Statistics Stats() const;

    struct Worker;  // the queue (HistoryStore.cpp)

private:
    friend class HistoryStore;
    double SteadyNow() const { return steadyNow_(); }
    void PostLoad(HistoryStore& store);
    void Write(HistoryStore& store);

    std::filesystem::path support_;
    std::function<double()> steadyNow_;
    std::shared_ptr<Worker> worker_;
    std::map<std::string, std::unique_ptr<HistoryStore>, std::less<>> stores_;
    bool started_ = false;
    WorkerThread thread_;  // last: it stops first
};

}  // namespace kite
