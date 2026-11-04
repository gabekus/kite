// Ports KiteMac's ArcHistoryImport.swift and BrowserHistoryImport.chromium; see ArcHistoryImport.h.

#include "core/ArcHistoryImport.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <unordered_map>

#ifdef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#endif

#include "core/Files.h"
#include "core/Unicode.h"

namespace kite::arc_import {

namespace fs = std::filesystem;

namespace {


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

// A REAL as sqlite3_column_text writes it: "%!.15g", which always has a decimal point.
std::string RealText(double d) {
    if (std::isinf(d)) return d > 0 ? "Inf" : "-Inf";
    char buffer[40];
    std::snprintf(buffer, sizeof buffer, "%.15g", d);
    std::string text = buffer;
    if (text.find_first_of(".n") == std::string::npos) {
        const size_t e = text.find('e');
        text.insert(e == std::string::npos ? text.size() : e, ".0");
    }
    return text;
}

// As the Mac reads a column, String(cString: sqlite3_column_text(...)): the text up to its
// first NUL, numbers as SQLite writes them out; none for NULL.
std::optional<std::string> TakeText(sqlite::SqlValue& v) {
    std::string* text = std::get_if<std::string>(&v);
    if (!text) {
        if (auto* blob = std::get_if<sqlite::Blob>(&v)) text = &blob->bytes;
        else if (auto* i = std::get_if<int64_t>(&v)) return std::to_string(*i);
        else if (auto* d = std::get_if<double>(&v)) return RealText(*d);
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

}  // namespace

bool HasLiveWriter(const fs::path& file) {
#ifdef _WIN32
    // Read access while denying others write access: Windows refuses that (a sharing violation)
    // while another handle has the file open for writing, as SQLite's and Chromium's lockfile's
    // are. Closed at once.
    int fd = -1;
    const errno_t error = _wsopen_s(&fd, file.c_str(), _O_RDONLY | _O_BINARY, _SH_DENYWR, _S_IREAD);
    if (error == 0) {
        _close(fd);
        return false;
    }
    return error == EACCES;
#else
    (void)file;
    return false;
#endif
}

std::string DatabaseBusy(const fs::path& database, const fs::path& lockfile) {
    std::error_code error;
    fs::path journal = database, wal = database;
    journal += "-journal";
    wal += "-wal";
    // Arc has the database (or its journal or log) open for writing, or is running at all (it
    // holds User Data/lockfile open): it may change any moment. A lockfile nobody holds (left by
    // a crash or a power cut) is nothing.
    for (const fs::path& file : {database, journal, wal, lockfile}) {
        if (HasLiveWriter(file)) return "Arc is writing it: quit Arc and import again";
    }
    // Nobody is writing, but the last write didn't finish: a hot journal (the database may be
    // half changed until SQLite rolls it back) or pages committed only to a write-ahead log
    // (moved into the file when the last connection closes). Arc's next open and quit sorts
    // either out.
    bool unfinished = JournalIsHot(journal);
    if (!unfinished && (fs::exists(wal, error) || error)) {
        // One that can't be looked at counts as holding pages.
        const auto size = error ? 0 : fs::file_size(wal, error);
        unfinished = error || size > 0;
    }
    if (unfinished) return "Arc didn't finish its last write: open and quit Arc once, then import again";
    return {};
}


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
            url = sqlite::ColumnIndex(columns, "url");
            title = sqlite::ColumnIndex(columns, "title");
            visitCount = sqlite::ColumnIndex(columns, "visit_count");
            lastVisit = sqlite::ColumnIndex(columns, "last_visit_time");
            hidden = sqlite::ColumnIndex(columns, "hidden");
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
            // Chromium keeps no URL longer than url::kMaxURLChars.
            if (row.url && row.url->size() > kMaxHistoryURLBytes) {
                ++out.tooLong;
                return true;
            }
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
    out.tooLong += scan->oversized;
    out.rows += scan->oversized;
    // Newest first, as the query returns them, and the Mac's filter after its LIMIT: a row whose
    // URL Kite doesn't record still took its place among the newest.
    std::sort_heap(heap.begin(), heap.end(), Newer);
    out.entries.reserve(heap.size());
    // Each URL as the Mac keeps it: URL(string:) percent-encodes what Chromium left as typed
    // (`|`, `{`...), and records(_:) looks at that (History::Normalized). Two rows that come out
    // the same are one page, newest first, with the higher count, as Merge would make them.
    std::unordered_map<std::string, size_t> seen;
    for (Candidate& row : heap) {
        std::optional<std::string> address;
        if (row.url) address = History::Normalized(ValidUtf8(std::move(*row.url)));
        if (!address || !History::Records(*address)) {
            ++out.notWebPages;
            continue;
        }
        const int64_t visits = std::max<int64_t>(1, row.visitCount);
        if (auto [it, fresh] = seen.emplace(*address, out.entries.size()); !fresh) {
            HistoryEntry& page = out.entries[it->second];
            page.visitCount = std::max(page.visitCount, visits);
            ++out.sameURL;
            continue;
        }
        out.entries.push_back(HistoryEntry{std::move(*address), ValidUtf8(std::move(row.title)), History::ChromiumDate(row.lastVisit), visits});
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
    const fs::path lockfile = arcFolder / "User Data" / "lockfile";
    if (out.problem = DatabaseBusy(file, lockfile); !out.problem.empty()) return out;
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
    // The size it has as it's opened (it may have grown since the stamp).
    if (pages.IsOpen() && pages.Size() > maxFileBytes) {
        out.tooLarge = pages.Size();
        return out;
    }
    std::string header;
    if (!pages.IsOpen() || !pages.Read(0, 100, header) || !sqlite::HeaderJournal(header)) {
        out.unreadable = true;
        return out;
    }
    auto read = ReadChromiumHistory(pages, options);
    if (options.cancel && options.cancel->load()) return out;
    if (options.afterRead) options.afterRead();
    // Arc started (or wrote) while it was read: what came out may mix two versions.
    if (StampOf(file) != before || !DatabaseBusy(file, lockfile).empty()) {
        out.problem = "Arc changed it while Kite read it: quit Arc and import again";
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
