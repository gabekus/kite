#pragma once
// Reads one table out of an SQLite database file's bytes: enough for Import from Arc to read
// Chromium's `keywords` table (Arc's Site Search, in "Web Data"), where the Mac uses the
// system's SQLite. Kite for Windows has no third-party code, so this reads the file format
// (sqlite.org/fileformat.html) itself: the schema on page 1, the table's b-tree, records and
// overflow pages. Read only, and never trusting the file: a page out of range, a loop or a
// record that runs past its page makes it give up rather than read out of bounds.
//
// Not handled, since Chromium's databases don't need them: WITHOUT ROWID tables, a write-ahead
// log (Chromium keeps a rollback journal; a transaction in progress isn't seen) and UTF-16 text.

#include <cstdint>
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

// The table named `name` (ignoring ASCII case), or nullopt when the bytes aren't a database
// this can read or it has no such table.
std::optional<Table> ReadTable(std::string_view file, std::string_view name);

// The column names a CREATE TABLE statement declares, with each one's DEFAULT (for rows
// written before an ALTER TABLE ADD COLUMN) and which is the rowid's alias (INTEGER PRIMARY
// KEY). Exposed for the tests.
struct ColumnDefinition {
    std::string name;
    SqlValue defaultValue;
    bool rowidAlias = false;
};
std::optional<std::vector<ColumnDefinition>> ParseColumns(std::string_view createTable);

}  // namespace kite::sqlite
