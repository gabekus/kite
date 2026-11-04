#pragma once
// Browsing history on disk, for every profile: the Mac's HistoryStore (KiteMac/HistoryStore.swift),
// with the default profile's store leading to the others'. The default profile's history is
// history.json in the support folder; another profile's is Chromium/<dir>/Kite History.json, so
// deleting the profile deletes it.
//
// Threads. Everything public is for one thread (Kite's UI thread). One worker thread does every
// store's disk work, in order, as the Mac's "history-writes" queue: it reads each file (the
// default profile's as Kite starts, another's the first time it's asked for), and it encodes and
// writes the snapshots the UI thread hands it. A snapshot is a copy of the History, which costs
// a few hundred pointer copies (History.h: shards shared and copied on write), so saving never
// copies the entries on the UI thread, and never waits on the disk. The worker sleeps on a
// condition variable between jobs: an idle Kite has no wakeups from it.
//
// Until its file has been read, a store records what happens (visits, titles) and replays it
// over what the file held once it arrives (Adopt, when the worker's wake comes); it saves
// nothing before then, so it can't write over history it hasn't read. A search before then
// sees only this run's visits.
//
// When to save is the Mac's: a change saves 3 s after the last one, and at least every 30 s
// while changes keep coming (CappedDebounce, a page whose title keeps ticking); removing,
// clearing and importing save at once. The shell keeps one timer for all the stores (NextSaveIn,
// SaveDue). Quitting saves everything (SaveNow) and waits for the writes, for a bounded time
// (Flush): giving up is safe, since the atomic write leaves the old file or the new one.

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

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

    void RecordVisit(std::string_view url, std::string_view title, Timestamp at);
    // A title the entry already has (a page re-setting document.title) changes nothing and saves nothing.
    void UpdateTitle(std::string_view url, std::string_view title);
    std::vector<HistoryEntry> Search(std::string_view query, size_t limit, Timestamp now) const {
        return history_.Search(query, limit, now);
    }
    // Import from Arc. Returns how many pages were new (to what's loaded: wait for IsLoaded).
    size_t Merge(const std::vector<HistoryEntry>& entries);
    void RemoveAll();
    void Remove(const std::vector<std::string>& urls);
    // Delete browsing data's history: pages visited at or after `since` (none: all).
    void RemoveVisits(std::optional<Timestamp> since);

    struct Slot;  // what the worker shares with this store (HistoryStore.cpp)

private:
    friend class HistoryStores;
    HistoryStore(HistoryStores& owner, std::shared_ptr<Slot> slot);

    // A change to the history: `op` runs now, and again over the file's history once it's read.
    template <class Op>
    void Apply(Op op);
    void Changed();     // saves after the debounce
    void ChangedNow();  // saves at once (removing, clearing, importing)
    void Save();        // the Mac's saveNow, for this store
    void Adopt(History loaded, std::string error);

    HistoryStores& owner_;
    std::shared_ptr<Slot> slot_;
    History history_;
    std::vector<std::function<void(History&)>> pending_;
    std::string loadError_;
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
    // How long the destructor waits for the worker before it lets it go.
    static constexpr std::chrono::milliseconds kStopWait{5000};

    // `steadyNow`: the clock the saves are timed by (seconds); tests pass their own.
    explicit HistoryStores(std::filesystem::path supportDirectory, std::function<double()> steadyNow = {});
    // Lets the worker finish what it was given (for kStopWait at most, or not at all after a
    // Flush timed out): call Flush first to save. A worker still busy then is let go, after
    // OnStuck's handler runs, as core/SessionWriter.h's.
    ~HistoryStores();
    HistoryStores(const HistoryStores&) = delete;
    HistoryStores& operator=(const HistoryStores&) = delete;

    // `directory`'s history (BrowserState::kDefaultProfile: history.json). Reading another
    // profile's file starts the first time it's asked for.
    HistoryStore& ForProfile(const std::string& directory);
    // A deleted profile's history: dropped unsaved, since its folder is going.
    void ForgetProfile(const std::string& directory);
    static std::filesystem::path FileFor(const std::filesystem::path& supportDirectory, const std::string& directory);

    // Called on the worker's thread when a file has been read; the shell posts itself a message
    // and calls Adopt on the UI thread. Set it before anything else runs, or call Adopt after.
    void SetWake(std::function<void()> wake);
    // Takes in the files read since the last call. True when a store's history changed (a
    // command bar showing it should look again).
    bool Adopt();

    // The shell's one save timer: seconds until the next store's save is due, none when no save
    // is waiting. Ask again after any change and after SaveDue.
    std::optional<double> NextSaveIn() const;
    // The timer fired: saves the stores whose time has come.
    void SaveDue();
    // Saves every store that changed (closing the window, quitting).
    void SaveNow();
    // Quitting: waits (for `timeout` at most) for the reads and writes under way, saves what's
    // still unsaved (a failed write included), and waits for that. The last error, empty when
    // everything was written; a timeout is an error too.
    std::string Flush(std::chrono::milliseconds timeout = std::chrono::milliseconds::max());
    // Whether the worker still has a read or write under way, right now (after a Flush timed
    // out, whether it really is stuck).
    bool Writing() const;
    // Runs when the destructor has to let a worker go that's still busy: the app ends the process
    // from it, so the library isn't torn down under the thread. Without one it's detached.
    void OnStuck(std::function<void()> stuck) { onStuck_ = std::move(stuck); }
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

    struct Worker;  // the thread and its queue (HistoryStore.cpp)

private:
    friend class HistoryStore;
    double SteadyNow() const { return steadyNow_(); }
    void Write(HistoryStore& store);

    std::filesystem::path support_;
    std::function<double()> steadyNow_;
    std::shared_ptr<Worker> worker_;
    std::thread thread_;
    std::map<std::string, std::unique_ptr<HistoryStore>, std::less<>> stores_;
    std::function<void()> onStuck_;
    bool flushTimedOut_ = false;
};

}  // namespace kite
