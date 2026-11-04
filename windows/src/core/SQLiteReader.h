#pragma once
// Reads tables out of an SQLite database file: enough for Import from Arc to read Chromium's
// `keywords` table (Arc's Site Search, in "Web Data") and its `urls` table (Arc's history, in
// "History"), where the Mac uses the system's SQLite. Kite for Windows has no third-party code,
// so this reads the file format (sqlite.org/fileformat.html) itself: the schema on page 1, the
// table's b-tree, records and overflow pages. Read only, and never trusting the file: a page out
// of range, a loop or a record that runs past its page makes it give up rather than read out of
// bounds.
//
// The bytes come from a PageSource: the whole file in memory (ReadTable), or the file on disk a
// page at a time (FilePages, for ScanTable), so a History of hundreds of MB is never read whole.
// Each page is read at most once in a read (the schema's tree and the table's together), and the
// records together never exceed the file, so a crafted file costs no more than its own size; a
// scan holds one page per b-tree level and one record at a time, and leaves out records over its
// cap (and schema rows over kMaxSchemaRecordBytes) without reading them.
//
// Not handled, since Chromium's databases don't need them: WITHOUT ROWID tables, write-ahead log
// frames and UTF-16 text. Chromium keeps a rollback journal, which this never reads: while a
// write is in progress (a hot journal beside the file, IsHotJournal) the file may be half
// written, so callers check for one first and don't read the database then. A database in WAL
// mode (HeaderJournal) may have committed pages only in its -wal file; callers refuse one whose
// -wal isn't empty.

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace kite::sqlite {

struct Blob {
    std::string bytes;
    bool operator==(const Blob&) const = default;
};
// NULL, INTEGER, REAL, TEXT (UTF-8) or BLOB.
using SqlValue = std::variant<std::monostate, int64_t, double, std::string, Blob>;

struct Table {
    std::vector<std::string> columns;           // in the table's order
    std::vector<std::vector<SqlValue>> rows;    // rowid order, each with every column
    // The column's index, by name ignoring ASCII case, as SQL does.
    std::optional<size_t> Column(std::string_view name) const;
};
// The same for a list of column names (ScanTable's).
std::optional<size_t> ColumnIndex(const std::vector<std::string>& columns, std::string_view name);

// The longest schema row (a CREATE statement) read; a longer one is left unread.
inline constexpr size_t kMaxSchemaRecordBytes = size_t{64} << 10;

// Where a database's bytes come from.
class PageSource {
public:
    virtual ~PageSource() = default;
    virtual uint64_t Size() const = 0;
    // `size` bytes at `offset` into `out` (resized to them); false when they can't all be read.
    virtual bool Read(uint64_t offset, size_t size, std::string& out) = 0;
};

// A database in memory.
class MemoryPages final : public PageSource {
public:
    explicit MemoryPages(std::string_view bytes) : bytes_(bytes) {}
    uint64_t Size() const override { return bytes_.size(); }
    bool Read(uint64_t offset, size_t size, std::string& out) override;

private:
    std::string_view bytes_;
};

// A database file, read where it is a page at a time (opened for reading only, sharing it with
// whoever else has it open). Its size is taken once, when it's opened.
class FilePages final : public PageSource {
public:
    explicit FilePages(const std::filesystem::path& file);
    bool IsOpen() const { return open_; }
    uint64_t Size() const override { return size_; }
    bool Read(uint64_t offset, size_t size, std::string& out) override;
    // Bytes read so far (each page once, plus the header), for the benchmarks.
    uint64_t BytesRead() const { return bytesRead_; }

private:
    std::ifstream in_;
    uint64_t size_ = 0;
    uint64_t bytesRead_ = 0;
    bool open_ = false;
};

// The table named `name` (ignoring ASCII case), or nullopt when the bytes aren't a database
// this can read or it has no such table.
std::optional<Table> ReadTable(std::string_view file, std::string_view name);

struct ScanOptions {
    // Rows whose record is longer than this are left out (counted in Scan::oversized) without
    // reading their overflow pages.
    size_t maxRecordBytes = std::numeric_limits<size_t>::max();
    // Checked before each leaf page (the schema's and the table's): set, the scan stops
    // (Scan::stopped; nullopt while the schema is still being read).
    const std::atomic<bool>* cancel = nullptr;
};
struct Scan {
    uint64_t rows = 0;       // rows handed to the visitor
    uint64_t oversized = 0;  // rows over ScanOptions::maxRecordBytes, left out
    bool stopped = false;    // the visitor or the cancel flag ended it early
};
// Every row of table `name` in rowid order, streamed: `columns` gets the column names first
// (false stops before any row), then `row` each row's values in column order, every column
// there (a row written before an ALTER TABLE ADD COLUMN gets the column's DEFAULT; the rowid
// alias, the rowid). `row` may move values out; false from it stops the scan, which isn't a
// failure. Nullopt when the source isn't a database this can read, has no such table, or turns
// out broken part way (rows already handed over stay handed over: a caller that wants all or
// nothing discards them).
std::optional<Scan> ScanTable(PageSource& source, std::string_view name,
                              const std::function<bool(const std::vector<std::string>& columns)>& columns,
                              const std::function<bool(std::vector<SqlValue>& values)>& row, const ScanOptions& options = {});

// The column names a CREATE TABLE statement declares, with each one's DEFAULT (for rows
// written before an ALTER TABLE ADD COLUMN) and which is the rowid's alias (INTEGER PRIMARY
// KEY). Exposed for the tests.
struct ColumnDefinition {
    std::string name;
    SqlValue defaultValue;
    bool rowidAlias = false;
};
std::optional<std::vector<ColumnDefinition>> ParseColumns(std::string_view createTable);

// Whether a rollback journal's bytes are a hot journal: one SQLite began (it starts with the
// journal magic) and hasn't finished. An empty or zeroed journal is a finished one.
bool IsHotJournal(std::string_view journal);

// How the database keeps its journal, from its header's file format versions (bytes 18 and
// 19): a rollback journal (1) or a write-ahead log (2). Nullopt for bytes that aren't an SQLite
// header, or versions SQLite doesn't write.
enum class Journal { Rollback, WriteAheadLog };
std::optional<Journal> HeaderJournal(std::string_view header);

}  // namespace kite::sqlite
