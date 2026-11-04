// See SessionWriter.h.

#include "core/SessionWriter.h"

#include <chrono>
#include <utility>

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

}  // namespace

SessionWriter::SessionWriter(SessionStore store, bool maySave, std::function<double()> now)
    : store_(std::move(store)), maySave_(maySave), now_(std::move(now)) {
    // No thread at all for a run that mustn't save.
    if (maySave_) worker_ = std::thread([this] { Run(); });
}

SessionWriter::~SessionWriter() {
    if (!worker_.joinable()) return;
    {
        std::lock_guard lock(mutex_);
        stop_ = true;
    }
    wake_.notify_one();
    worker_.join();  // Run writes what's waiting before it returns
}

void SessionWriter::Save(BrowserState snapshot) {
    if (!maySave_) return;
    {
        std::lock_guard lock(mutex_);
        ++stats_.handedOver;
        if (next_) ++stats_.superseded;
        next_ = std::move(snapshot);
        stats_.pending = true;
    }
    wake_.notify_one();
}

void SessionWriter::BackUpLaunch(BrowserState found) {
    if (!maySave_) return;
    {
        std::lock_guard lock(mutex_);
        launch_ = std::move(found);
        stats_.pending = true;
    }
    wake_.notify_one();
}

std::string SessionWriter::Flush() {
    std::unique_lock lock(mutex_);
    done_.wait(lock, [this] { return !next_ && !launch_ && !busy_; });
    return stats_.lastError;
}

SessionWriter::Statistics SessionWriter::Stats() const {
    std::lock_guard lock(mutex_);
    return stats_;
}

void SessionWriter::Run() {
    std::unique_lock lock(mutex_);
    for (;;) {
        wake_.wait(lock, [this] { return stop_ || next_ || launch_; });
        if (!next_ && !launch_) break;  // stopping, with nothing left to write
        // The launch backup first: it's the session as found, before any change.
        std::optional<BrowserState> launch = std::exchange(launch_, std::nullopt);
        std::optional<BrowserState> next = std::exchange(next_, std::nullopt);
        busy_ = true;
        lock.unlock();
        if (launch) {
            auto made = store_.Backups().BackUp(SessionStore::EncodeFile(*launch), SessionBackups::Kind::Launch, now_());
            std::lock_guard relock(mutex_);
            stats_.backups += made.made ? 1 : 0;
            stats_.lastBackupError = made.error;
        }
        if (next) Write(*next);
        lock.lock();
        busy_ = false;
        stats_.pending = next_ || launch_;
        if (!stats_.pending) done_.notify_all();
    }
    done_.notify_all();
}

void SessionWriter::Write(const BrowserState& state) {
    const auto encodeStart = std::chrono::steady_clock::now();
    std::string bytes = SessionStore::EncodeFile(state);
    const double encodeMicros = MicrosSince(encodeStart);
    if (bytes == lastWritten_) {
        std::lock_guard lock(mutex_);
        ++stats_.unchanged;
        stats_.lastEncodeMicros = encodeMicros;
        return;
    }
    const size_t size = bytes.size();
    const auto writeStart = std::chrono::steady_clock::now();
    std::string error = store_.WriteFile(bytes);
    const double writeMicros = MicrosSince(writeStart);
    SessionBackups::BackUpResult backup;
    if (error.empty()) {
        lastWritten_ = std::move(bytes);
        // At most one an hour (the Mac's backupQueue after each save); inside the hour this
        // costs nothing, the newest date being kept in memory.
        backup = store_.Backups().BackUp(lastWritten_, SessionBackups::Kind::Hourly, now_());
    }
    std::lock_guard lock(mutex_);
    stats_.lastEncodeMicros = encodeMicros;
    stats_.lastWriteMicros = writeMicros;
    stats_.lastBytes = size;
    stats_.lastError = std::move(error);
    if (stats_.lastError.empty()) {
        ++stats_.written;
        stats_.backups += backup.made ? 1 : 0;
        stats_.lastBackupError = backup.error;
    }
}

}  // namespace kite
