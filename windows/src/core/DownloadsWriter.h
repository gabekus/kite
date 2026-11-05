#pragma once
// downloads.json off the UI thread, on core/SessionWriter.h's pattern: one worker thread reads
// the file at launch (downloads_file::Load, which moves an unreadable file aside), then writes
// each snapshot the UI thread hands over, atomically (core/StoreFile.h), skipping bytes it last
// wrote. A snapshot still waiting when a newer one comes is dropped. The worker sleeps on a
// condition variable between jobs, so an idle Kite has no wakeups from it.
//
// The Mac's DownloadsModel reads the file on the main thread and writes it there
// (Data.write(options: .atomic)); Windows does neither on its UI thread
// (docs/windows-architecture.md). Every wait is bounded, and giving up is safe: the write is
// atomic. Everything public is for one thread (Kite's UI thread), except Stats.

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include "core/Downloads.h"

namespace kite {

class DownloadsWriter {
public:
    static constexpr std::chrono::milliseconds kStopWait{5000};

    explicit DownloadsWriter(std::filesystem::path file);
    // Writes what's waiting (for kStopWait at most, or not at all after a Flush timed out),
    // then stops the worker; one still writing is let go after OnStuck's handler runs.
    ~DownloadsWriter();
    DownloadsWriter(const DownloadsWriter&) = delete;
    DownloadsWriter& operator=(const DownloadsWriter&) = delete;

    const std::filesystem::path& File() const { return file_; }

    // Reads the file on the worker, before any save, and runs `loaded` there with what it found
    // (none: it couldn't be read or moved aside). Saves are written only once it has, and only
    // when it may be replaced. Once per writer.
    void Load(std::function<void(std::optional<downloads_file::Loaded>)> loaded);
    // Hands `snapshot` to the worker and returns at once.
    void Save(DownloadList snapshot);
    // Waits, for `timeout` at most, until the load and every save handed over are done. The
    // last write's error, empty when it went well; a timeout is an error too.
    std::string Flush(std::chrono::milliseconds timeout = std::chrono::milliseconds::max());
    bool Writing() const;
    void OnStuck(std::function<void()> stuck);

    struct Statistics {
        uint64_t handedOver = 0;
        uint64_t written = 0;
        uint64_t unchanged = 0;
        uint64_t superseded = 0;
        uint64_t refused = 0;  // snapshots not written: the file mustn't be replaced this launch
        bool loaded = false;
        bool canSave = false;
        bool pending = false;
        double loadMicros = 0;
        double lastEncodeMicros = 0;
        double lastWriteMicros = 0;
        size_t lastBytes = 0;
        std::string lastError;
    };
    Statistics Stats() const;

    struct Shared;

private:
    const std::filesystem::path file_;
    std::shared_ptr<Shared> shared_;
    std::function<void()> onStuck_;
    bool flushTimedOut_ = false;
    std::thread worker_;
};

}  // namespace kite
