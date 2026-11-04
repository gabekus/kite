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
// it's read only when Arc can't be changing it: Arc isn't running (Chromium's User Data/lockfile,
// which exists exactly while it runs), no write is half done (a hot History-journal), nothing
// committed waits in a write-ahead log (a History-wal that isn't empty), and the file is the
// same size and age after the read as before. Otherwise the profile's history is left out with
// the reason ("quit Arc and import again"). Delete with ArcImportController.h once Arc has shut down.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
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
    uint64_t tooLong = 0;       // a row over kMaxHistoryRowBytes, left unread
    uint64_t sameURL = 0;       // among those, a URL another newer row has once both are Normalized
};

// Chromium keeps a URL to 2 MB (url::kMaxURLChars) and a title far shorter; a row past this
// isn't one Chromium wrote, and is left out without being read.
inline constexpr size_t kMaxHistoryRowBytes = size_t{4} << 20;

struct HistoryReadOptions {
    size_t maxEntries = History::kMaxEntries;
    const std::atomic<bool>* cancel = nullptr;  // checked between pages
};

// The urls table of the database in `source`. Nullopt when it isn't a History database (no urls
// table with those columns), turns out broken, or the read was cancelled.
std::optional<HistoryRead> ReadChromiumHistory(sqlite::PageSource& source, const HistoryReadOptions& options = {});

// An Arc profile's browsing history; `profile` is its folder ("Default", "Profile 1"...). The
// Mac's ArcImportController.historyFile(profile:in:).
std::filesystem::path ArcHistoryFile(const std::filesystem::path& arcFolder, const std::string& profile);

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
