// Ports KiteMac's ArcHistoryImport.swift and BrowserHistoryImport.chromium; see ArcHistoryImport.h.

#include "core/ArcHistoryImport.h"

#include <algorithm>
#include <chrono>
#include <cmath>

#include "core/Files.h"
#include "core/Unicode.h"

namespace kite::arc_import {

namespace fs = std::filesystem;

namespace {

constexpr const char* kQuitArc = "quit Arc and import again";

// A row kept for now: among the newest `maxEntries` seen so far.
struct Candidate {
    int64_t lastVisit = 0;
    std::optional<std::string> url;  // none: not text
    std::string title;
    int64_t visitCount = 0;
};
// The heap's order: the oldest visit on top, so it's the one a newer row replaces.
bool Newer(const Candidate& a, const Candidate& b) { return a.lastVisit > b.lastVisit; }

std::optional<int64_t> Integer(const sqlite::SqlValue& v) {
    if (auto* i = std::get_if<int64_t>(&v)) return *i;
    // As sqlite3_column_int64 converts a REAL: toward zero, clamped.
    if (auto* d = std::get_if<double>(&v); d && std::isfinite(*d)) {
        if (*d >= 9.2e18) return INT64_MAX;
        if (*d <= -9.2e18) return INT64_MIN;
        return static_cast<int64_t>(*d);
    }
    return std::nullopt;
}

// As the Mac reads a column, String(cString: sqlite3_column_text(...)): the text up to its
// first NUL; none for NULL. Numbers as SQLite writes them out are left to the caller.
std::optional<std::string> TakeText(sqlite::SqlValue& v) {
    std::string* text = std::get_if<std::string>(&v);
    if (!text) {
        if (auto* blob = std::get_if<sqlite::Blob>(&v)) text = &blob->bytes;
        else if (auto* i = std::get_if<int64_t>(&v)) return std::to_string(*i);
        else return std::nullopt;
    }
    std::string out = std::move(*text);
    if (const size_t nul = out.find('\0'); nul != std::string::npos) out.resize(nul);
    return out;
}

// String(cString:) repairs ill-formed UTF-8 with U+FFFD; Kite's files are valid UTF-8 too.
std::string ValidUtf8(std::string text) {
    const std::vector<char32_t> codePoints = unicode::Decode(text);
    std::string repaired = unicode::Encode(std::u32string_view(codePoints.data(), codePoints.size()));
    return repaired == text ? text : repaired;
}

// When a file was last written and how big it is: compared before and after a read.
struct Stamp {
    uint64_t size = 0;
    fs::file_time_type written{};
    bool operator==(const Stamp&) const = default;
};
std::optional<Stamp> StampOf(const fs::path& file) {
    std::error_code error;
    Stamp stamp;
    stamp.size = static_cast<uint64_t>(fs::file_size(file, error));
    if (error) return std::nullopt;
    stamp.written = fs::last_write_time(file, error);
    if (error) return std::nullopt;
    return stamp;
}

// Why Arc may be changing the database now, or empty.
std::string Busy(const fs::path& arcFolder, const fs::path& file) {
    std::error_code error;
    // Chromium holds User Data/lockfile open while it runs, and Windows deletes it as the
    // process ends (FILE_FLAG_DELETE_ON_CLOSE), so it's there exactly while Arc runs.
    if (fs::exists(arcFolder / "User Data" / "lockfile", error) || error) return std::string("Arc is running: ") + kQuitArc;
    fs::path journal = file;
    journal += "-journal";
    if (JournalIsHot(journal)) return std::string("Arc is writing it: ") + kQuitArc;
    // Pages committed to a write-ahead log may be there only: SQLite moves them into the file
    // when the last connection closes. One left behind (Arc ended without closing it) goes when
    // Arc next opens and quits.
    fs::path wal = file;
    wal += "-wal";
    if (fs::exists(wal, error) || error) {
        const auto size = fs::file_size(wal, error);
        if (error || size > 0) return "Arc's latest history is still in History-wal: open Arc, quit it and import again";
    }
    return {};
}

}  // namespace

std::optional<HistoryRead> ReadChromiumHistory(sqlite::PageSource& source, const HistoryReadOptions& options) {
    HistoryRead out;
    std::vector<Candidate> heap;
    std::optional<size_t> url, title, visitCount, lastVisit, hidden;
    sqlite::ScanOptions scanOptions;
    scanOptions.maxRecordBytes = kMaxHistoryRowBytes;
    scanOptions.cancel = options.cancel;
    auto scan = sqlite::ScanTable(
        source, "urls",
        [&](const std::vector<std::string>& columns) {
            sqlite::Table names{columns, {}};
            url = names.Column("url");
            title = names.Column("title");
            visitCount = names.Column("visit_count");
            lastVisit = names.Column("last_visit_time");
            hidden = names.Column("hidden");
            // The Mac's query names all five: without one it doesn't run.
            return url && title && visitCount && lastVisit && hidden;
        },
        [&](std::vector<sqlite::SqlValue>& values) {
            ++out.rows;
            // WHERE hidden = 0 AND last_visit_time > 0.
            const auto shown = Integer(values[*hidden]);
            if (!shown || *shown != 0) {
                ++out.hidden;
                return true;
            }
            const auto visited = Integer(values[*lastVisit]);
            if (!visited || *visited <= 0) {
                ++out.neverVisited;
                return true;
            }
            // ORDER BY last_visit_time DESC LIMIT maxEntries: the newest so far, ties to the row
            // read first. A row that can't make it costs no copy.
            if (options.maxEntries == 0 || (heap.size() == options.maxEntries && *visited <= heap.front().lastVisit)) {
                ++out.beyondCap;
                return true;
            }
            Candidate row{*visited, TakeText(values[*url]), TakeText(values[*title]).value_or(""),
                          Integer(values[*visitCount]).value_or(0)};
            if (heap.size() == options.maxEntries) {
                std::pop_heap(heap.begin(), heap.end(), Newer);
                heap.pop_back();
                ++out.beyondCap;
            }
            heap.push_back(std::move(row));
            std::push_heap(heap.begin(), heap.end(), Newer);
            return true;
        },
        scanOptions);
    if (!scan || scan->stopped) return std::nullopt;
    out.tooLong = scan->oversized;
    out.rows += scan->oversized;
    // Newest first, as the query returns them, and the Mac's filter after its LIMIT: a row whose
    // URL Kite doesn't record still took its place among the newest.
    std::sort_heap(heap.begin(), heap.end(), Newer);
    out.entries.reserve(heap.size());
    for (Candidate& row : heap) {
        std::optional<std::string> address = row.url ? std::optional<std::string>(ValidUtf8(std::move(*row.url))) : std::nullopt;
        if (!address || !History::Records(*address)) {
            ++out.notWebPages;
            continue;
        }
        out.entries.push_back(HistoryEntry{std::move(*address), ValidUtf8(std::move(row.title)), History::ChromiumDate(row.lastVisit),
                                           std::max<int64_t>(1, row.visitCount)});
    }
    return out;
}

fs::path ArcHistoryFile(const fs::path& arcFolder, const std::string& profile) {
    return arcFolder / "User Data" / fs::path(std::u8string(profile.begin(), profile.end())) / "History";
}

bool JournalIsHot(const fs::path& journal) {
    std::error_code error;
    if (!fs::exists(journal, error)) return static_cast<bool>(error);
    if (!fs::is_regular_file(journal, error)) return true;
    const auto size = fs::file_size(journal, error);
    if (error) return true;
    if (size == 0) return false;
    auto head = ReadFilePrefix(journal, 8);
    return !head || sqlite::IsHotJournal(*head);
}

ProfileHistory ReadArcHistory(const fs::path& arcFolder, const std::string& profile, size_t maxFileBytes, const HistoryReadOptions& options) {
    ProfileHistory out;
    const fs::path file = ArcHistoryFile(arcFolder, profile);
    std::error_code error;
    if (!fs::exists(file, error) && !error) return out;
    if (!fs::is_regular_file(file, error)) {
        out.unreadable = true;
        return out;
    }
    if (out.problem = Busy(arcFolder, file); !out.problem.empty()) return out;
    const auto before = StampOf(file);
    if (!before) {
        out.unreadable = true;
        return out;
    }
    if (before->size > maxFileBytes) {
        out.tooLarge = before->size;
        return out;
    }
    sqlite::FilePages pages(file);
    std::string header;
    if (!pages.IsOpen() || !pages.Read(0, 100, header) || !sqlite::HeaderJournal(header)) {
        out.unreadable = true;
        return out;
    }
    auto read = ReadChromiumHistory(pages, options);
    if (options.cancel && options.cancel->load()) return out;
    // Arc started (or wrote) while it was read: what came out may mix two versions.
    if (StampOf(file) != before || !Busy(arcFolder, file).empty()) {
        out.problem = std::string("Arc changed it while Kite read it: ") + kQuitArc;
        return out;
    }
    if (!read) {
        out.unreadable = true;
        return out;
    }
    out.read = std::move(read);
    return out;
}

}  // namespace kite::arc_import
