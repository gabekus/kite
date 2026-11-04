// See HistoryStore.h.

#include "core/HistoryStore.h"

#include <algorithm>
#include <deque>
#include <utility>

#include "core/StoreFile.h"

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

double SteadySeconds() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

}  // namespace

// The worker's queue: reads and writes in the order they were asked for. Everything in it, and
// in every Slot, is behind WorkerState::mutex.
struct HistoryStores::Worker : WorkerState {
    Worker() {
        // Room for Failed's message, so it's set without allocating (out of memory, mostly).
        stats.lastError.reserve(128);
    }

    std::deque<std::function<void()>> jobs;
    std::function<void()> loaded;  // the shell's wake
    Statistics stats;

    bool HasWork() const override { return !jobs.empty(); }

    void RunOne(std::unique_lock<std::mutex>& lock) override {
        std::function<void()> job = std::move(jobs.front());
        jobs.pop_front();
        lock.unlock();
        job();
        lock.lock();
    }

    void Failed(const char*) noexcept override { stats.lastError.assign("history: a read or write failed"); }

    void Post(std::function<void()> job) {
        {
            std::lock_guard lock(mutex);
            jobs.push_back(std::move(job));
        }
        wake.notify_one();
    }
};

// One store's, shared with the worker (behind its mutex).
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
};

// MARK: HistoryStore

HistoryStore::HistoryStore(HistoryStores& owner, std::shared_ptr<Slot> slot)
    : owner_(owner), slot_(std::move(slot)), debounce_{HistoryStores::kQuiet, HistoryStores::kMaxWait, std::nullopt} {}

const std::filesystem::path& HistoryStore::File() const { return slot_->file.File(); }

bool HistoryStore::RecordVisit(std::string_view url, std::string_view title, Timestamp at) {
    if (!history_.RecordVisit(url, title, at)) return false;
    // Kept for the replay only before the file is in: afterwards a visit makes nothing more.
    if (!adopted_) pending_.emplace_back([url = std::string(url), title = std::string(title), at](History& h) { h.RecordVisit(url, title, at); });
    Changed();
    return true;
}

bool HistoryStore::UpdateTitle(std::string_view url, std::string_view title) {
    if (!history_.UpdateTitle(url, title)) return false;
    if (!adopted_) pending_.emplace_back([url = std::string(url), title = std::string(title)](History& h) { h.UpdateTitle(url, title); });
    Changed();
    return true;
}

size_t HistoryStore::Merge(std::vector<HistoryEntry> entries) {
    // Not into this run's visits as well before the file is read: 20,000 pages twice on the UI
    // thread, for a search that sees only this run's visits until then anyway.
    if (!adopted_) {
        pending_.emplace_back([entries = std::move(entries)](History& h) { h.Merge(entries); });
        ChangedNow();
        return 0;
    }
    const size_t added = history_.Merge(entries);
    ChangedNow();
    return added;
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
    pending_.shrink_to_fit();
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
    thread_.Start(worker_);
    ForProfile(BrowserState::kDefaultProfile);
}

HistoryStores::~HistoryStores() {
    {
        std::lock_guard lock(worker_->mutex);
        worker_->loaded = nullptr;
    }
    thread_.Stop();
}

std::filesystem::path HistoryStores::FileFor(const std::filesystem::path& supportDirectory, const std::string& directory) {
    if (directory == BrowserState::kDefaultProfile) return supportDirectory / "history.json";
    return supportDirectory / "Chromium" / std::filesystem::path(std::u8string(directory.begin(), directory.end())) / "Kite History.json";
}

void HistoryStores::Start() {
    if (std::exchange(started_, true)) return;
    for (auto& [directory, store] : stores_) PostLoad(*store);
}

HistoryStore& HistoryStores::ForProfile(const std::string& directory) {
    if (auto it = stores_.find(directory); it != stores_.end()) return *it->second;
    auto slot = std::make_shared<HistoryStore::Slot>(FileFor(support_, directory));
    auto& store = *stores_.emplace(directory, std::unique_ptr<HistoryStore>(new HistoryStore(*this, slot))).first->second;
    if (started_) PostLoad(store);
    return store;
}

void HistoryStores::PostLoad(HistoryStore& store) {
    if (std::exchange(store.loadPosted_, true)) return;
    worker_->Post([worker = worker_.get(), slot = store.slot_] {
        const auto start = std::chrono::steady_clock::now();
        std::optional<History> history;
        std::string error;
        bool maySave = true;
        try {
            HistoryFile::LoadResult result = slot->file.Load(HistoryFile::Unreadable::MoveAside);
            maySave = HistoryFile::MaySave(result);
            if (auto* found = std::get_if<History>(&result)) {
                // A file over the cap (written by hand, or by an older Kite) is trimmed here, on
                // the worker, not by the UI thread's first visit.
                found->TrimToCap();
                history = std::move(*found);
            }
            if (auto* failed = std::get_if<HistoryFile::Error>(&result)) error = std::move(failed->message);
        } catch (...) {
            // Out of memory, mostly: the file is still there, unread, so it's never written over.
            history.reset();
            maySave = false;
            error = "history couldn't be read";
        }
        const double micros = MicrosSince(start);
        std::function<void()> wake;
        {
            std::lock_guard lock(worker->mutex);
            slot->loadDone = true;
            slot->maySave = maySave;
            slot->loaded = std::move(history);
            slot->loadError = std::move(error);
            ++worker->stats.loads;
            worker->stats.lastLoadMicros = micros;
            wake = worker->loaded;
        }
        if (wake) wake();
    });
}

void HistoryStores::SetWake(std::function<void()> wake) {
    std::lock_guard lock(worker_->mutex);
    worker_->loaded = std::move(wake);
}

bool HistoryStores::Adopt(std::vector<std::string>* problems) {
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
        if (problems && !error.empty()) problems->push_back(store_file::PathText(store->File()) + ": " + error);
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
            history = std::exchange(slot->next, std::nullopt);
        }
        discard.clear();
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

std::string HistoryStores::Flush(Deadline deadline) {
    const auto timedOut = [] { return std::string("history's writes didn't finish in time"); };
    // The reads and writes under way first, as the Mac's flush waits for its queue.
    if (!thread_.WaitIdle(deadline)) return timedOut();
    Adopt();
    SaveNow();  // a write that failed is tried again
    if (!thread_.WaitIdle(deadline)) return timedOut();
    std::lock_guard lock(worker_->mutex);
    for (const auto& [directory, store] : stores_) {
        if (!store->slot_->lastError.empty()) return store->slot_->lastError;
    }
    return {};
}

bool HistoryStores::WaitForLoads(std::chrono::milliseconds timeout) {
    const bool loaded = thread_.WaitUntil(DeadlineAfter(timeout), [this] {
        return std::all_of(stores_.begin(), stores_.end(), [](const auto& entry) {
            return entry.second->adopted_ || (entry.second->loadPosted_ && entry.second->slot_->loadDone);
        });
    });
    if (loaded) Adopt();
    return loaded;
}

HistoryStores::Statistics HistoryStores::Stats() const {
    std::lock_guard lock(worker_->mutex);
    return worker_->stats;
}

}  // namespace kite
