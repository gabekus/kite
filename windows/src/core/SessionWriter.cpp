// See SessionWriter.h.

#include "core/SessionWriter.h"

#include <condition_variable>
#include <exception>
#include <mutex>
#include <optional>
#include <utility>

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

// Waits on `cv` until `done`, for `timeout` at most (max: no limit). False on a timeout.
template <class Done>
bool WaitFor(std::condition_variable& cv, std::unique_lock<std::mutex>& lock, std::chrono::milliseconds timeout, Done done) {
    if (timeout == std::chrono::milliseconds::max()) {
        cv.wait(lock, done);
        return true;
    }
    return cv.wait_for(lock, timeout, done);
}

}  // namespace

struct SessionWriter::Shared {
    Shared(SessionStore s, std::function<double()> n) : store(std::move(s)), now(std::move(n)) {}

    const SessionStore store;
    const std::function<double()> now;

    std::mutex mutex;
    std::condition_variable wake;  // the worker: work or stop
    std::condition_variable done;  // Flush and the destructor: the worker caught up, or ended
    std::optional<BrowserState> next;
    std::optional<BrowserState> launch;
    bool busy = false;
    bool stop = false;
    bool ended = false;
    Statistics stats;

    // The worker's own, outside the lock: the bytes last written, so an unchanged snapshot
    // costs no write, and whether the backups already have them (made, or the newest hourly
    // one holds the same bytes), so an unchanged session isn't offered again.
    std::string lastWritten;
    bool lastWrittenBackedUp = false;

    void Run();
    void Write(const BrowserState& state);
    void BackUpHourly();
};

SessionWriter::SessionWriter(SessionStore store, bool maySave, std::function<double()> now)
    : maySave_(maySave), shared_(std::make_shared<Shared>(std::move(store), std::move(now))) {
    // No thread at all for a run that mustn't save.
    if (maySave_) worker_ = std::thread([shared = shared_] { shared->Run(); });
}

SessionWriter::~SessionWriter() {
    if (!worker_.joinable()) return;
    std::unique_lock lock(shared_->mutex);
    shared_->stop = true;
    shared_->wake.notify_one();
    // Run writes what's waiting before it ends. A write that's still stuck after kStopWait is
    // let go: the thread holds its own reference to the shared state.
    const bool ended = shared_->done.wait_for(lock, kStopWait, [this] { return shared_->ended; });
    lock.unlock();
    if (ended) worker_.join();
    else worker_.detach();
}

void SessionWriter::Save(BrowserState snapshot) {
    if (!maySave_) return;
    {
        std::lock_guard lock(shared_->mutex);
        ++shared_->stats.handedOver;
        if (shared_->next) ++shared_->stats.superseded;
        shared_->next = std::move(snapshot);
        shared_->stats.pending = true;
    }
    shared_->wake.notify_one();
}

void SessionWriter::BackUpLaunch(BrowserState found) {
    if (!maySave_) return;
    {
        std::lock_guard lock(shared_->mutex);
        shared_->launch = std::move(found);
        shared_->stats.pending = true;
    }
    shared_->wake.notify_one();
}

std::string SessionWriter::Flush(std::chrono::milliseconds timeout) {
    std::unique_lock lock(shared_->mutex);
    Shared& s = *shared_;
    if (!WaitFor(s.done, lock, timeout, [&] { return (!s.next && !s.launch && !s.busy) || s.ended; })) {
        return "the session's write didn't finish within " + std::to_string(timeout.count()) + " ms";
    }
    return s.stats.lastError;
}

SessionWriter::Statistics SessionWriter::Stats() const {
    std::lock_guard lock(shared_->mutex);
    return shared_->stats;
}

// Nothing may throw out of the thread: an escaping exception would end the process
// (std::terminate). Every failure becomes lastError instead, and the next save tries again.
void SessionWriter::Shared::Run() {
    std::unique_lock lock(mutex);
    for (;;) {
        wake.wait(lock, [this] { return stop || next || launch; });
        if (!next && !launch) break;  // stopping, with nothing left to write
        // The launch backup first: it's the session as found, before any change.
        std::optional<BrowserState> found = std::exchange(launch, std::nullopt);
        std::optional<BrowserState> snapshot = std::exchange(next, std::nullopt);
        busy = true;
        lock.unlock();
        try {
            if (found) {
                auto made = store.Backups().BackUp(SessionStore::EncodeFile(*found), SessionBackups::Kind::Launch, now());
                std::lock_guard relock(mutex);
                stats.backups += made.made ? 1 : 0;
                stats.lastBackupError = made.error;
            }
            if (snapshot) Write(*snapshot);
        } catch (const std::exception& e) {  // out of memory, mostly
            std::lock_guard relock(mutex);
            stats.lastError = std::string("couldn't save the session: ") + e.what();
        } catch (...) {
            std::lock_guard relock(mutex);
            stats.lastError = "couldn't save the session";
        }
        lock.lock();
        busy = false;
        stats.pending = next || launch;
        if (!stats.pending) done.notify_all();
    }
    ended = true;
    done.notify_all();
}

void SessionWriter::Shared::Write(const BrowserState& state) {
    const auto encodeStart = std::chrono::steady_clock::now();
    std::string bytes = SessionStore::EncodeFile(state);
    const double encodeMicros = MicrosSince(encodeStart);
    if (!lastWritten.empty() && bytes == lastWritten) {
        // The file already holds these bytes (an earlier write that failed left it as it was),
        // so whatever error that write had no longer stands.
        {
            std::lock_guard lock(mutex);
            ++stats.unchanged;
            stats.lastEncodeMicros = encodeMicros;
            stats.lastError.clear();
        }
        BackUpHourly();
        return;
    }
    const size_t size = bytes.size();
    const auto writeStart = std::chrono::steady_clock::now();
    std::string error = store.WriteFile(bytes);
    const double writeMicros = MicrosSince(writeStart);
    if (error.empty()) {
        lastWritten = std::move(bytes);
        lastWrittenBackedUp = false;
    }
    {
        std::lock_guard lock(mutex);
        stats.lastEncodeMicros = encodeMicros;
        stats.lastWriteMicros = writeMicros;
        stats.lastBytes = size;
        stats.lastError = std::move(error);
        if (stats.lastError.empty()) ++stats.written;
    }
    if (!lastWritten.empty()) BackUpHourly();
}

void SessionWriter::Shared::BackUpHourly() {
    // After every save, as the Mac's saveNow; inside the hour this costs nothing (the newest
    // date is kept in memory), and bytes the backups already hold aren't offered again.
    if (lastWrittenBackedUp) return;
    auto backup = store.Backups().BackUp(lastWritten, SessionBackups::Kind::Hourly, now());
    if (backup.made || backup.sameAsNewest) lastWrittenBackedUp = true;
    std::lock_guard lock(mutex);
    stats.backups += backup.made ? 1 : 0;
    stats.lastBackupError = backup.error;
}

}  // namespace kite
