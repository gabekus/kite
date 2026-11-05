// See SessionWriter.h.

#include "core/SessionWriter.h"

#include <optional>
#include <utility>

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

}  // namespace

struct SessionWriter::Shared : WorkerState {
    Shared(SessionStore s, std::function<double()> n) : store(std::move(s)), now(std::move(n)) {
        // Room for the fixed failure message, so the catch in Run sets it without allocating.
        stats.lastError.reserve(128);
    }

    const SessionStore store;
    const std::function<double()> now;

    std::optional<BrowserState> next;
    std::optional<BrowserState> launch;
    bool offer = false;  // OfferBackup: the hourly backup of what was last written
    Statistics stats;

    // The worker's own, outside the lock: the bytes last written, so an unchanged snapshot
    // costs no write, and whether the backups already have them (made, or the newest hourly
    // one holds the same bytes), so an unchanged session isn't offered again.
    std::string lastWritten;
    bool lastWrittenBackedUp = false;

    bool HasWork() const override { return next || launch || offer; }
    void RunOne(std::unique_lock<std::mutex>& lock) override;
    void Failed(const char* what) noexcept override;
    void Write(const BrowserState& state);
    void BackUpHourly();
};

SessionWriter::SessionWriter(SessionStore store, bool maySave, std::function<double()> now)
    : maySave_(maySave), shared_(std::make_shared<Shared>(std::move(store), std::move(now))) {
    // No thread at all for a run that mustn't save.
    if (maySave_) worker_.Start(shared_);
}

// The worker writes what's waiting before it ends (WorkerThread::Stop, kStopWait at most, or not
// at all after a Flush timed out); one still writing then goes to OnStuck's handler.
SessionWriter::~SessionWriter() { worker_.Stop(); }

bool SessionWriter::OfferBackup() {
    if (!maySave_) return false;
    {
        std::lock_guard lock(shared_->mutex);
        if (shared_->stats.written == 0 && shared_->stats.unchanged == 0) return false;
        shared_->offer = true;
    }
    shared_->wake.notify_one();
    return true;
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

std::string SessionWriter::Flush(std::chrono::milliseconds timeout) { return Flush(DeadlineAfter(timeout)); }

std::string SessionWriter::Flush(Deadline deadline) {
    if (!worker_.WaitIdle(deadline)) return "the session's write didn't finish in time";
    std::lock_guard lock(shared_->mutex);
    return shared_->stats.lastError;
}

bool SessionWriter::Writing() const { return maySave_ && worker_.Writing(); }

SessionWriter::Statistics SessionWriter::Stats() const {
    std::lock_guard lock(shared_->mutex);
    return shared_->stats;
}

// One pass: the launch backup, the newest snapshot and an offered backup, all that's waiting.
void SessionWriter::Shared::RunOne(std::unique_lock<std::mutex>& lock) {
    // The launch backup first: it's the session as found, before any change.
    std::optional<BrowserState> found = std::exchange(launch, std::nullopt);
    std::optional<BrowserState> snapshot = std::exchange(next, std::nullopt);
    // A save offers the backup anyway.
    const bool offered = std::exchange(offer, false) && !snapshot;
    lock.unlock();
    if (found) {
        auto made = store.Backups().BackUp(SessionStore::EncodeFile(*found), SessionBackups::Kind::Launch, now());
        std::lock_guard relock(mutex);
        stats.backups += made.made ? 1 : 0;
        stats.lastBackupError = made.error;
    }
    if (snapshot) Write(*snapshot);
    if (offered && !lastWritten.empty()) BackUpHourly();
    lock.lock();
    stats.pending = HasWork();
}

// Every failure becomes lastError, and the next save tries again.
void SessionWriter::Shared::Failed(const char* what) noexcept {
    // The fixed message fits the room reserved for it; what() is added if it can be.
    stats.lastError.assign("couldn't save the session");
    if (what) {
        try {
            stats.lastError.append(": ").append(what);
        } catch (...) {
        }
    }
    stats.pending = HasWork();
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
        stats.lastError.assign(error);  // into its reserved room (see Run's catch)
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
