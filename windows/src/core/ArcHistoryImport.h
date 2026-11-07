#pragma once
// Arc's browsing history, for Import from Arc: a port of KiteMac's ArcHistoryImport.swift and
// the Chromium reader it uses, BrowserHistoryImport.chromium. Arc keeps history where Chromium
// does, in each profile's "History" database (User Data/<profile>/History), and the Mac reads its
// `urls` table, one row per page:
//
//   SELECT url, title, visit_count, last_visit_time FROM urls
//   WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT 20000
//
// keeping each row whose URL Kite records (History::Records, of the URL as the Mac's
// URL(string:) reads it: History::Normalized), with its title ("" for none), its visit count (at
// least 1) and its last visit (History::ChromiumDate). The visits table isn't
// read: urls already has each page's count and last visit, which is all Kite's history keeps.
//
// The Mac runs that query with the system's SQLite on a copy of the file. Kite for Windows reads
// the file where it is, with its own reader (core/SQLiteReader.h) a page at a time: a History of
// hundreds of MB is never in memory or copied, and the newest 20,000 rows are kept as they
// stream past (a heap), so memory stays at those rows and a few pages. Since it isn't a copy,
// it's read only when Arc can't be changing it (DatabaseBusy): nothing has History, its journal,
// its log or Chromium's User Data/lockfile open for writing (a probe that opens each for reading
// while denying writers, closed at once), no write was left half done (a hot History-journal),
// nothing committed waits in a write-ahead log (a History-wal that isn't empty), and the file is
// the same size and age, with no writer, after the read as before. Otherwise the profile's
// history is left out with the reason. The Mac reads a copy, which SQLite rolls back or replays;
// once Arc has shut down for good (2026-12-22) a hot journal or a WAL can't be cleared by
// opening Arc, and reading through them (an in-memory rollback, WAL frames) is the follow-up.
// Delete with ArcImportController.h once Arc's data is gone.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "core/History.h"
#include "core/SQLiteReader.h"

namespace kite::arc_import {

// What a Chromium History database's urls table gave: the pages, newest first (at most
// `maxEntries`), and how many rows were left out and why. Every row is counted once.
struct HistoryRead {
    std::vector<HistoryEntry> entries;
    uint64_t rows = 0;          // every row of urls
    uint64_t hidden = 0;        // hidden: subframes and redirects Chromium leaves off its history page
    uint64_t neverVisited = 0;  // no last visit (last_visit_time 0, or not a number)
    uint64_t beyondCap = 0;     // visited before the newest `maxEntries` rows, as the Mac's LIMIT
    uint64_t notWebPages = 0;   // among those, a URL Kite doesn't record (not http or https, or unreadable)
    uint64_t tooLong = 0;       // a row over kMaxHistoryRowBytes (left unread), or a URL over kMaxHistoryURLBytes
    uint64_t sameURL = 0;       // among those, a URL another newer row has once both are Normalized
};

// Chromium keeps a URL to 2 MB (url::kMaxURLChars) and a title far shorter; a row past this
// isn't one Chromium wrote, and is left out without being read.
inline constexpr size_t kMaxHistoryRowBytes = size_t{4} << 20;
// url::kMaxURLChars: Chromium keeps no longer URL.
inline constexpr size_t kMaxHistoryURLBytes = size_t{2} << 20;

struct HistoryReadOptions {
    size_t maxEntries = History::kMaxEntries;
    const std::atomic<bool>* cancel = nullptr;  // checked before each leaf page
    // Tests only: runs after ReadArcHistory's read, before its checks that nothing changed.
    std::function<void()> afterRead;
};

// The urls table of the database in `source`. Nullopt when it isn't a History database (no urls
// table with those columns), turns out broken, or the read was cancelled.
std::optional<HistoryRead> ReadChromiumHistory(sqlite::PageSource& source, const HistoryReadOptions& options = {});

// An Arc profile's browsing history; `profile` is its folder ("Default", "Profile 1"...). The
// Mac's ArcImportController.historyFile(profile:in:).
std::filesystem::path ArcHistoryFile(const std::filesystem::path& arcFolder, const std::string& profile);

// When a file was last written and how big it is: compared before and after a read of one of
// Arc's databases (History, Cookies), so a write in between is caught.
struct FileStamp {
    uint64_t size = 0;
    std::filesystem::file_time_type written{};
    bool operator==(const FileStamp&) const = default;
};
std::optional<FileStamp> StampOf(const std::filesystem::path& file);

// Whether something has `file` open for writing (a sharing violation on a read that denies
// writers); any failure but the file not being there counts as one. Windows only: elsewhere, false.
bool HasLiveWriter(const std::filesystem::path& file);

// Why Arc may be changing the SQLite `database` now, or empty: a live writer of it, its journal,
// its log or `lockfile` ("Arc is writing it: quit Arc and import again"), else a hot journal or a
// write-ahead log that isn't empty ("Arc didn't finish its last write: open and quit Arc once,
// then import again"). History and Web Data both.
std::string DatabaseBusy(const std::filesystem::path& database, const std::filesystem::path& lockfile);

// Whether SQLite is in the middle of writing the database `journal` sits beside: a hot journal
// (sqlite::IsHotJournal, its first 8 bytes). One that's there but can't be read counts as hot,
// so a half-written database is never trusted.
bool JournalIsHot(const std::filesystem::path& journal);

// One Arc profile's history, read from Arc's folder with the checks above. `read` none and
// `problem` empty: there's no History file (or the read was cancelled). `problem` says why one
// that's there didn't come over, in the words Import from Arc's confirmation uses.
struct ProfileHistory {
    std::optional<HistoryRead> read;
    std::string problem;
    std::optional<uint64_t> tooLarge;  // the file's size, when it's past maxFileBytes (problem empty)
    bool unreadable = false;           // there, but not a database Kite can read (problem empty)
};
ProfileHistory ReadArcHistory(const std::filesystem::path& arcFolder, const std::string& profile, size_t maxFileBytes,
                              const HistoryReadOptions& options = {});

}  // namespace kite::arc_import
