// See HistoryStore.h.

#include "core/HistoryStore.h"

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <exception>
#include <mutex>
#include <utility>

#include "core/StoreFile.h"

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

double SteadySeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

// The worker's queue. Everything in it, and in every Slot, is behind `mutex`.
struct HistoryStores::Worker {
    std::mutex mutex;
    std::condition_variable wake;  // the worker: a job, or stop
    std::condition_variable done;  // Flush and the destructor: the queue ran dry, or the worker ended
    std::deque<std::function<void()>> jobs;
    bool busy = false;
    bool stop = false;
    bool ended = false;
    std::function<void()> loaded;  // the shell's wake
    Statistics stats;

    void Post(std::function<void()> job) {
        {
            std::lock_guard lock(mutex);
            jobs.push_back(std::move(job));
        }
        wake.notify_one();
    }

    // Nothing may throw out of the thread (std::terminate): a job's failure is its own to report.
    void Run() {
        std::unique_lock lock(mutex);
        for (;;) {
            wake.wait(lock, [this] { return stop || !jobs.empty(); });
            if (jobs.empty()) break;  // stopping, with nothing left to do
            std::function<void()> job = std::move(jobs.front());
            jobs.pop_front();
            busy = true;
            lock.unlock();
            try {
                job();
            } catch (...) {  // out of memory, mostly
                std::lock_guard relock(mutex);
                stats.lastError = "history: a read or write failed";
            }
            lock.lock();
            busy = false;
            if (jobs.empty()) done.notify_all();
        }
        ended = true;
        done.notify_all();
    }

    bool Idle() const { return jobs.empty() && !busy; }

    // Until the queue is empty and nothing runs; false when `deadline` came first.
    bool WaitIdle(std::unique_lock<std::mutex>& lock, std::chrono::steady_clock::time_point deadline) {
        const auto idle = [this] { return Idle() || ended; };
        if (deadline == std::chrono::steady_clock::time_point::max()) {
            done.wait(lock, idle);
            return true;
        }
        return done.wait_until(lock, deadline, idle);
    }
};

// One store's, shared with the worker (behind Worker::mutex).
struct HistoryStore::Slot {
    explicit Slot(std::filesystem::path file) : file(std::move(file)) {}
    const HistoryFile file;
    // The read: done, what it found, and whether the file may be written.
    bool loadDone = false;
    std::optional<History> loaded;
    std::string loadError;
    bool maySave = true;
    // The snapshot waiting to be written, and whether a job for it is queued.
    std::optional<History> next;
    std::vector<History> discard;  // snapshots dropped for newer ones, freed by the worker
    bool writeQueued = false;
    bool lastWriteFailed = false;
    std::string lastError;  // the last write's, empty when it went through
    bool forgotten = false;
};

// MARK: HistoryStore

HistoryStore::HistoryStore(HistoryStores& owner, std::shared_ptr<Slot> slot)
    : owner_(owner), slot_(std::move(slot)), debounce_{HistoryStores::kQuiet, HistoryStores::kMaxWait, std::nullopt} {}

const std::filesystem::path& HistoryStore::File() const { return slot_->file.File(); }

template <class Op>
void HistoryStore::Apply(Op op) {
    op(history_);
    if (!adopted_) pending_.emplace_back(std::move(op));
}

void HistoryStore::RecordVisit(std::string_view url, std::string_view title, Timestamp at) {
    // A page Kite doesn't keep changes nothing, so it saves nothing (the Mac's store saves anyway).
    if (!History::Records(url)) return;
    Apply([url = std::string(url), title = std::string(title), at](History& h) { h.RecordVisit(url, title, at); });
    Changed();
}

void HistoryStore::UpdateTitle(std::string_view url, std::string_view title) {
    // Checked first, so a repeat costs one lookup.
    if (!history_.UpdatesTitle(url, title)) return;
    Apply([url = std::string(url), title = std::string(title)](History& h) { h.UpdateTitle(url, title); });
    Changed();
}

size_t HistoryStore::Merge(const std::vector<HistoryEntry>& entries) {
    const size_t added = history_.Merge(entries);
    if (!adopted_) pending_.emplace_back([entries](History& h) { h.Merge(entries); });
    ChangedNow();
    return added;
}

void HistoryStore::RemoveAll() {
    Apply([](History& h) { h.RemoveAll(); });
    ChangedNow();
}

void HistoryStore::Remove(const std::vector<std::string>& urls) {
    Apply([urls](History& h) { h.Remove(urls); });
    ChangedNow();
}

void HistoryStore::RemoveVisits(std::optional<Timestamp> since) {
    Apply([since](History& h) { h.RemoveVisits(since); });
    ChangedNow();
}

void HistoryStore::Changed() {
    dirty_ = true;
    // Before the file is read there's nothing to save over it with; Adopt arms the save.
    if (!adopted_) return;
    const double now = owner_.SteadyNow();
    dueAt_ = now + debounce_.Changed(now);
}

void HistoryStore::ChangedNow() {
    dirty_ = true;
    if (!adopted_) {
        saveWhenLoaded_ = true;
        return;
    }
    Save();
}

void HistoryStore::Save() {
    dueAt_.reset();
    debounce_.Saved();
    if (!adopted_) return;
    owner_.Write(*this);
}

void HistoryStore::Adopt(History loaded, std::string error) {
    history_ = std::move(loaded);
    for (auto& op : pending_) op(history_);
    pending_.clear();
    loadError_ = std::move(error);
    adopted_ = true;
    if (!dirty_) return;
    if (std::exchange(saveWhenLoaded_, false)) {
        Save();
    } else {
        const double now = owner_.SteadyNow();
        dueAt_ = now + debounce_.Changed(now);
    }
}

// MARK: HistoryStores

HistoryStores::HistoryStores(std::filesystem::path supportDirectory, std::function<double()> steadyNow)
    : support_(std::move(supportDirectory)),
      steadyNow_(steadyNow ? std::move(steadyNow) : std::function<double()>(SteadySeconds)),
      worker_(std::make_shared<Worker>()) {
    thread_ = std::thread([worker = worker_] { worker->Run(); });
    // The default profile's history is read as Kite starts, while the window and Chromium start.
    ForProfile(BrowserState::kDefaultProfile);
}

HistoryStores::~HistoryStores() {
    std::unique_lock lock(worker_->mutex);
    worker_->stop = true;
    worker_->loaded = nullptr;
    worker_->wake.notify_one();
    // The worker does what's queued before it ends. After a Flush that timed out it isn't waited
    // for again (the caller has waited its bound). One with nothing left counts as done: told to
    // stop, it ends at once, so the join can't hang.
    const auto wait = flushTimedOut_ ? std::chrono::milliseconds(0) : kStopWait;
    const bool ended = worker_->done.wait_for(lock, wait, [this] { return worker_->ended || worker_->Idle(); });
    lock.unlock();
    if (ended) {
        thread_.join();
        return;
    }
    // Still busy: the thread holds its own reference to the queue and the slots, so it may go
    // on, but the process mustn't tear down its library under it.
    if (onStuck_) onStuck_();
    thread_.detach();
}

bool HistoryStores::Writing() const {
    std::lock_guard lock(worker_->mutex);
    return !worker_->Idle() && !worker_->ended;
}

bool HistoryStores::WaitForLoads(std::chrono::milliseconds timeout) {
    {
        std::unique_lock lock(worker_->mutex);
        const auto loaded = [this] {
            for (const auto& [directory, store] : stores_) {
                if (!store->adopted_ && !store->slot_->loadDone) return false;
            }
            return true;
        };
        if (!worker_->done.wait_for(lock, timeout, [&] { return loaded() || worker_->ended; })) return false;
    }
    Adopt();
    return true;
}

std::filesystem::path HistoryStores::FileFor(const std::filesystem::path& supportDirectory, const std::string& directory) {
    if (directory == BrowserState::kDefaultProfile) return supportDirectory / "history.json";
    return supportDirectory / "Chromium" / std::filesystem::path(std::u8string(directory.begin(), directory.end())) / "Kite History.json";
}

HistoryStore& HistoryStores::ForProfile(const std::string& directory) {
    if (auto it = stores_.find(directory); it != stores_.end()) return *it->second;
    auto slot = std::make_shared<HistoryStore::Slot>(FileFor(support_, directory));
    auto& store = *stores_.emplace(directory, std::unique_ptr<HistoryStore>(new HistoryStore(*this, slot))).first->second;
    worker_->Post([worker = worker_.get(), slot] {
        const auto start = std::chrono::steady_clock::now();
        HistoryFile::LoadResult result = slot->file.Load(HistoryFile::Unreadable::MoveAside);
        const double micros = MicrosSince(start);
        std::function<void()> wake;
        {
            std::lock_guard lock(worker->mutex);
            slot->loadDone = true;
            slot->maySave = HistoryFile::MaySave(result);
            if (auto* history = std::get_if<History>(&result)) slot->loaded = std::move(*history);
            if (auto* error = std::get_if<HistoryFile::Error>(&result)) slot->loadError = error->message;
            ++worker->stats.loads;
            worker->stats.lastLoadMicros = micros;
            wake = worker->loaded;
        }
        if (wake) wake();
    });
    return store;
}

void HistoryStores::ForgetProfile(const std::string& directory) {
    if (directory == BrowserState::kDefaultProfile) return;
    auto it = stores_.find(directory);
    if (it == stores_.end()) return;
    {
        std::lock_guard lock(worker_->mutex);
        HistoryStore::Slot& slot = *it->second->slot_;
        slot.forgotten = true;
        if (slot.next) slot.discard.push_back(std::move(*std::exchange(slot.next, std::nullopt)));
    }
    stores_.erase(it);
}

void HistoryStores::SetWake(std::function<void()> wake) {
    std::lock_guard lock(worker_->mutex);
    worker_->loaded = std::move(wake);
}

bool HistoryStores::Adopt() {
    bool changed = false;
    for (auto& [directory, store] : stores_) {
        if (store->adopted_) continue;
        std::optional<History> loaded;
        std::string error;
        {
            std::lock_guard lock(worker_->mutex);
            if (!store->slot_->loadDone) continue;
            loaded = std::exchange(store->slot_->loaded, std::nullopt);
            error = store->slot_->loadError;
        }
        store->Adopt(loaded ? std::move(*loaded) : History(), std::move(error));
        changed = true;
    }
    return changed;
}

std::optional<double> HistoryStores::NextSaveIn() const {
    std::optional<double> due;
    for (const auto& [directory, store] : stores_) {
        if (store->dueAt_ && (!due || *store->dueAt_ < *due)) due = store->dueAt_;
    }
    if (!due) return std::nullopt;
    return std::max(0.0, *due - SteadyNow());
}

void HistoryStores::SaveDue() {
    // A millisecond's grace: the shell's timer rounds to whole milliseconds.
    const double now = SteadyNow() + 0.001;
    for (auto& [directory, store] : stores_) {
        if (store->dueAt_ && *store->dueAt_ <= now) store->Save();
    }
}

void HistoryStores::SaveNow() {
    for (auto& [directory, store] : stores_) store->Save();
}

void HistoryStores::Write(HistoryStore& store) {
    auto& slot = store.slot_;
    bool retry = false;
    {
        std::lock_guard lock(worker_->mutex);
        retry = slot->lastWriteFailed;
        // A file that's there but couldn't be read is never written over.
        if (!slot->maySave) return;
    }
    if (!store.dirty_ && !retry) return;
    store.dirty_ = false;
    History snapshot = store.history_;  // shares the shards: no entry is copied here
    bool post = false;
    {
        std::lock_guard lock(worker_->mutex);
        // A snapshot the worker hasn't taken yet is dropped for this one, and let go on the
        // worker's thread: it may be the last owner of shards visits have unshared since.
        if (std::optional<History> older = std::exchange(slot->next, std::move(snapshot))) {
            ++worker_->stats.superseded;
            slot->discard.push_back(std::move(*older));
        }
        post = !std::exchange(slot->writeQueued, true);
    }
    if (!post) return;
    worker_->Post([worker = worker_.get(), slot] {
        std::optional<History> history;
        std::vector<History> discard;
        {
            std::lock_guard lock(worker->mutex);
            discard = std::move(slot->discard);
            slot->discard.clear();
            slot->writeQueued = false;
            if (slot->forgotten) return;
            history = std::exchange(slot->next, std::nullopt);
        }
        if (!history) return;
        const auto encodeStart = std::chrono::steady_clock::now();
        const std::string bytes = history->EncodeFile();
        const double encodeMicros = MicrosSince(encodeStart);
        history.reset();  // the shards go back to the UI thread's alone
        const auto writeStart = std::chrono::steady_clock::now();
        std::string error = slot->file.Write(bytes);
        const double writeMicros = MicrosSince(writeStart);
        std::lock_guard lock(worker->mutex);
        slot->lastWriteFailed = !error.empty();
        slot->lastError = error.empty() ? std::string() : "couldn't save " + store_file::PathText(slot->file.File()) + ": " + error;
        worker->stats.lastEncodeMicros = encodeMicros;
        worker->stats.lastWriteMicros = writeMicros;
        worker->stats.lastBytes = bytes.size();
        if (error.empty()) {
            ++worker->stats.writes;
        } else {
            ++worker->stats.failedWrites;
            worker->stats.lastError = slot->lastError;
        }
    });
}

std::string HistoryStores::Flush(std::chrono::milliseconds timeout) {
    const auto deadline = timeout == std::chrono::milliseconds::max() ? std::chrono::steady_clock::time_point::max()
                                                                       : std::chrono::steady_clock::now() + timeout;
    const auto timedOut = [&] {
        flushTimedOut_ = true;
        return "history's writes didn't finish within " + std::to_string(timeout.count()) + " ms";
    };
    // The reads and writes under way first, as the Mac's flush waits for its queue.
    {
        std::unique_lock lock(worker_->mutex);
        if (!worker_->WaitIdle(lock, deadline)) return timedOut();
    }
    Adopt();
    SaveNow();  // a write that failed is tried again
    std::unique_lock lock(worker_->mutex);
    if (!worker_->WaitIdle(lock, deadline)) return timedOut();
    for (const auto& [directory, store] : stores_) {
        if (!store->slot_->lastError.empty()) return store->slot_->lastError;
    }
    return {};
}

HistoryStores::Statistics HistoryStores::Stats() const {
    std::lock_guard lock(worker_->mutex);
    return worker_->stats;
}

}  // namespace kite
