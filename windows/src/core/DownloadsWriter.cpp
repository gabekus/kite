// See DownloadsWriter.h.

#include "core/DownloadsWriter.h"

#include <condition_variable>
#include <exception>
#include <mutex>
#include <utility>

#include "core/StoreFile.h"

namespace kite {

namespace {

double MicrosSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

}  // namespace

struct DownloadsWriter::Shared {
    explicit Shared(std::filesystem::path f) : file(std::move(f)) { stats.lastError.reserve(128); }

    const std::filesystem::path file;
    std::mutex mutex;
    std::condition_variable wake;
    std::condition_variable done;
    std::function<void(std::optional<downloads_file::Loaded>)> load;  // the launch's read, once
    std::optional<DownloadList> next;
    bool busy = false;
    bool stop = false;
    bool ended = false;
    Statistics stats;
    std::string lastWritten;  // the worker's own

    // Nothing to do now: a snapshot that waits for a read nobody asked for isn't work.
    bool Idle() const { return !load && !busy && (!next || !stats.loaded); }
    void Run();
    void Write(const DownloadList& list);
};

DownloadsWriter::DownloadsWriter(std::filesystem::path file)
    : file_(std::move(file)), shared_(std::make_shared<Shared>(file_)) {
    worker_ = std::thread([shared = shared_] { shared->Run(); });
}

DownloadsWriter::~DownloadsWriter() {
    if (!worker_.joinable()) return;
    std::unique_lock lock(shared_->mutex);
    shared_->stop = true;
    shared_->wake.notify_one();
    const auto wait = flushTimedOut_ ? std::chrono::milliseconds(0) : kStopWait;
    const bool ended = shared_->done.wait_for(lock, wait, [this] { return shared_->ended || shared_->Idle(); });
    lock.unlock();
    if (ended) {
        worker_.join();
        return;
    }
    if (onStuck_) onStuck_();
    worker_.detach();
}

void DownloadsWriter::OnStuck(std::function<void()> stuck) { onStuck_ = std::move(stuck); }

void DownloadsWriter::Load(std::function<void(std::optional<downloads_file::Loaded>)> loaded) {
    {
        std::lock_guard lock(shared_->mutex);
        if (shared_->stats.loaded || shared_->load) return;
        shared_->load = loaded ? std::move(loaded) : [](std::optional<downloads_file::Loaded>) {};
        shared_->stats.pending = true;
    }
    shared_->wake.notify_one();
}

void DownloadsWriter::Save(DownloadList snapshot) {
    {
        std::lock_guard lock(shared_->mutex);
        ++shared_->stats.handedOver;
        if (shared_->next) ++shared_->stats.superseded;
        shared_->next = std::move(snapshot);
        shared_->stats.pending = true;
    }
    shared_->wake.notify_one();
}

std::string DownloadsWriter::Flush(std::chrono::milliseconds timeout) {
    std::unique_lock lock(shared_->mutex);
    Shared& s = *shared_;
    const auto ready = [&] { return s.Idle() || s.ended; };
    const bool finished = timeout == std::chrono::milliseconds::max() ? (s.done.wait(lock, ready), true) : s.done.wait_for(lock, timeout, ready);
    if (!finished) {
        flushTimedOut_ = true;
        return "downloads.json's write didn't finish within " + std::to_string(timeout.count()) + " ms";
    }
    return s.stats.lastError;
}

bool DownloadsWriter::Writing() const {
    std::lock_guard lock(shared_->mutex);
    return !shared_->Idle() && !shared_->ended;
}

DownloadsWriter::Statistics DownloadsWriter::Stats() const {
    std::lock_guard lock(shared_->mutex);
    return shared_->stats;
}

// Nothing may throw out of the thread: every failure becomes lastError.
void DownloadsWriter::Shared::Run() {
    std::unique_lock lock(mutex);
    for (;;) {
        wake.wait(lock, [this] { return stop || load || next; });
        if (!load && !next) break;
        // The read comes first: a save before it would replace the history it holds.
        auto reading = std::exchange(load, nullptr);
        std::optional<DownloadList> snapshot;
        if (!reading) {
            if (!stats.loaded) {
                // Saves wait for the read; stopping without one leaves the file as it was.
                if (stop) break;
                wake.wait(lock, [this] { return stop || load; });
                continue;
            }
            snapshot = std::exchange(next, std::nullopt);
        }
        busy = true;
        lock.unlock();
        try {
            if (reading) {
                const auto start = std::chrono::steady_clock::now();
                std::optional<downloads_file::Loaded> loaded = downloads_file::Load(file);
                const double micros = MicrosSince(start);
                {
                    std::lock_guard relock(mutex);
                    stats.loaded = true;
                    stats.canSave = loaded && loaded->canSave;
                    stats.loadMicros = micros;
                }
                reading(std::move(loaded));
            }
            if (snapshot) Write(*snapshot);
        } catch (const std::exception& e) {
            std::lock_guard relock(mutex);
            stats.lastError.assign("couldn't save the downloads");
            try {
                stats.lastError.append(": ").append(e.what());
            } catch (...) {
            }
        } catch (...) {
            std::lock_guard relock(mutex);
            stats.lastError.assign("couldn't save the downloads");
        }
        lock.lock();
        busy = false;
        stats.pending = load || next;
        if (!stats.pending) done.notify_all();
    }
    ended = true;
    done.notify_all();
}

void DownloadsWriter::Shared::Write(const DownloadList& list) {
    {
        std::lock_guard lock(mutex);
        if (!stats.canSave) {
            ++stats.refused;
            return;
        }
    }
    const auto encodeStart = std::chrono::steady_clock::now();
    std::string bytes = downloads_file::Encode(list);
    const double encodeMicros = MicrosSince(encodeStart);
    if (!lastWritten.empty() && bytes == lastWritten) {
        std::lock_guard lock(mutex);
        ++stats.unchanged;
        stats.lastEncodeMicros = encodeMicros;
        stats.lastError.clear();
        return;
    }
    const size_t size = bytes.size();
    const auto writeStart = std::chrono::steady_clock::now();
    std::string error = store_file::WriteAtomically(file, bytes);
    const double writeMicros = MicrosSince(writeStart);
    if (error.empty()) lastWritten = std::move(bytes);
    std::lock_guard lock(mutex);
    stats.lastEncodeMicros = encodeMicros;
    stats.lastWriteMicros = writeMicros;
    stats.lastBytes = size;
    stats.lastError.assign(error);
    if (stats.lastError.empty()) ++stats.written;
}

}  // namespace kite
