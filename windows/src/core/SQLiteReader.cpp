// See SQLiteReader.h. The format: https://www.sqlite.org/fileformat.html

#include "core/SQLiteReader.h"

#include <algorithm>
#include <charconv>
#include <cstring>
#include <functional>
#include <limits>

namespace kite::sqlite {

namespace {

bool EqualsIgnoringCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        unsigned char x = static_cast<unsigned char>(a[i]), y = static_cast<unsigned char>(b[i]);
        if (x >= 'A' && x <= 'Z') x = static_cast<unsigned char>(x + 32);
        if (y >= 'A' && y <= 'Z') y = static_cast<unsigned char>(y + 32);
        if (x != y) return false;
    }
    return true;
}

uint64_t BigEndian(std::string_view bytes, size_t at, size_t width) {
    uint64_t v = 0;
    for (size_t i = 0; i < width; ++i) v = (v << 8) | static_cast<unsigned char>(bytes[at + i]);
    return v;
}

// SQLite's variable-length integer: up to nine bytes, big-endian.
bool Varint(std::string_view bytes, size_t& at, uint64_t& out) {
    out = 0;
    for (int i = 0; i < 9; ++i) {
        if (at >= bytes.size()) return false;
        const unsigned char b = static_cast<unsigned char>(bytes[at++]);
        if (i == 8) {
            out = (out << 8) | b;
            return true;
        }
        out = (out << 7) | (b & 0x7F);
        if (!(b & 0x80)) return true;
    }
    return true;
}

// What the walk hands on for each row: its rowid and record bytes, or no bytes for a record over
// the cap (left unread). False stops the walk.
using CellVisitor = std::function<bool(int64_t rowid, const std::string* record)>;

class Reader {
public:
    explicit Reader(PageSource& source) : source_(source) {}

    bool Open() {
        std::string header;
        if (source_.Size() < 100 || !source_.Read(0, 100, header)) return false;
        if (std::memcmp(header.data(), "SQLite format 3\0", 16) != 0) return false;
        pageSize_ = static_cast<size_t>(BigEndian(header, 16, 2));
        if (pageSize_ == 1) pageSize_ = 65536;
        if (pageSize_ < 512 || pageSize_ > 65536 || (pageSize_ & (pageSize_ - 1)) != 0) return false;
        usable_ = pageSize_ - static_cast<unsigned char>(header[20]);
        if (usable_ < 480) return false;
        // Text in UTF-8 (1), or 0 in a database with nothing in it yet.
        const uint64_t encoding = BigEndian(header, 56, 4);
        if (encoding != 1 && encoding != 0) return false;
        pageCount_ = source_.Size() / pageSize_;
        // One bit a page: 256 KB for a 1 GiB file of 512-byte pages, the smallest there are.
        used_.assign(static_cast<size_t>(pageCount_) + 1, false);
        return pageCount_ > 0;
    }

    // Every row of the table b-tree rooted at `root`, in rowid order, to `visit`. False for a
    // broken file; a visit that returns false ends it early, which isn't one (stopped()).
    bool Rows(uint64_t root, const CellVisitor& visit, size_t maxRecord, const std::atomic<bool>* cancel) {
        visit_ = &visit;
        maxRecord_ = maxRecord;
        cancel_ = cancel;
        stopped_ = false;
        return Walk(root, 0);
    }
    bool Stopped() const { return stopped_; }

private:
    // Page `number` into `out`: one read of the source.
    bool Page(uint64_t number, std::string& out) {
        if (number < 1 || number > pageCount_) return false;
        return source_.Read((number - 1) * pageSize_, pageSize_, out);
    }

    // Each page is read once in the whole read (the schema's walk and the table's, which share
    // this reader), as a b-tree page or an overflow page: a page reached twice (a loop, a child
    // or overflow chain shared by two cells, a table inside the schema's tree) is a broken file.
    bool Use(uint64_t number) {
        if (number < 1 || number > pageCount_ || used_[static_cast<size_t>(number)]) return false;
        used_[static_cast<size_t>(number)] = true;
        return true;
    }

    bool Walk(uint64_t number, int depth) {
        if (depth > 64 || !Use(number)) return false;
        // This level's page, kept while its children are read: one page per level.
        std::string page;
        if (!Page(number, page)) return false;
        const size_t header = number == 1 ? 100 : 0;
        if (page.size() < header + 8) return false;
        const unsigned char type = static_cast<unsigned char>(page[header]);
        const size_t cells = static_cast<size_t>(BigEndian(page, header + 3, 2));
        const bool interior = type == 0x05;
        if (!interior && type != 0x0D) return false;
        if (!interior && cancel_ && cancel_->load()) {
            stopped_ = true;
            return true;
        }
        const size_t pointers = header + (interior ? 12 : 8);
        if (pointers + cells * 2 > usable_) return false;
        // Cells sit after the pointer array, each at its own place: checked before any is read,
        // so a pointer repeated many times can't make the same record be read again and again.
        std::vector<size_t> offsets(cells);
        for (size_t i = 0; i < cells; ++i) {
            offsets[i] = static_cast<size_t>(BigEndian(page, pointers + i * 2, 2));
            if (offsets[i] < pointers + cells * 2 || offsets[i] >= usable_) return false;
        }
        {
            std::vector<size_t> sorted = offsets;
            std::sort(sorted.begin(), sorted.end());
            if (std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end()) return false;
        }
        const std::string_view cellBytes = std::string_view(page).substr(0, static_cast<size_t>(usable_));
        for (size_t i = 0; i < cells; ++i) {
            size_t at = offsets[i];
            if (interior) {
                if (at + 4 > usable_) return false;
                if (!Walk(BigEndian(page, at, 4), depth + 1)) return false;
                if (stopped_) return true;
                continue;
            }
            uint64_t payload = 0, rowid = 0;
            if (!Varint(cellBytes, at, payload) || !Varint(cellBytes, at, rowid)) return false;
            if (payload > maxRecord_) {
                // Too long to keep: what's on this page is still checked, the overflow unread.
                if (!Payload(cellBytes, at, payload, nullptr)) return false;
                if (!(*visit_)(static_cast<int64_t>(rowid), nullptr)) stopped_ = true;
            } else {
                if (!Payload(cellBytes, at, payload, &record_)) return false;
                if (!(*visit_)(static_cast<int64_t>(rowid), &record_)) stopped_ = true;
            }
            if (stopped_) return true;
        }
        if (interior) return Walk(BigEndian(page, header + 8, 4), depth + 1);
        return true;
    }

    // A table leaf cell's payload: what's on the page, then the overflow chain. With no `out`,
    // only the part on the page is checked.
    bool Payload(std::string_view page, size_t at, uint64_t size, std::string* out) {
        // Every record together can't be more than the file holds.
        recordBytes_ += size;
        if (size > source_.Size() || recordBytes_ > source_.Size()) return false;
        const uint64_t x = usable_ - 35;
        uint64_t local = size;
        if (size > x) {
            const uint64_t m = ((usable_ - 12) * 32 / 255) - 23;
            const uint64_t k = m + ((size - m) % (usable_ - 4));
            local = k <= x ? k : m;
        }
        if (at + local > page.size()) return false;
        if (local < size && at + local + 4 > page.size()) return false;
        if (!out) return true;
        out->assign(page.substr(at, static_cast<size_t>(local)));
        if (local == size) return true;
        uint64_t next = BigEndian(page, static_cast<size_t>(at + local), 4);
        while (out->size() < size) {
            if (!Use(next) || !Page(next, overflow_)) return false;
            const size_t take = static_cast<size_t>(std::min<uint64_t>(size - out->size(), usable_ - 4));
            out->append(overflow_, 4, take);
            next = BigEndian(overflow_, 0, 4);
        }
        return true;
    }

    PageSource& source_;
    std::vector<bool> used_;
    std::string record_, overflow_;
    const CellVisitor* visit_ = nullptr;
    const std::atomic<bool>* cancel_ = nullptr;
    size_t maxRecord_ = std::numeric_limits<size_t>::max();
    bool stopped_ = false;
    uint64_t recordBytes_ = 0;
    size_t pageSize_ = 0;
    uint64_t usable_ = 0;
    uint64_t pageCount_ = 0;
};

// A record's values, in column order.
std::optional<std::vector<SqlValue>> Record(std::string_view bytes) {
    size_t at = 0;
    uint64_t headerSize = 0;
    if (!Varint(bytes, at, headerSize) || headerSize > bytes.size()) return std::nullopt;
    std::vector<uint64_t> types;
    while (at < headerSize) {
        uint64_t type = 0;
        if (!Varint(bytes, at, type)) return std::nullopt;
        types.push_back(type);
    }
    size_t body = static_cast<size_t>(headerSize);
    std::vector<SqlValue> values;
    for (uint64_t type : types) {
        static constexpr size_t kIntWidths[] = {0, 1, 2, 3, 4, 6, 8};
        if (type == 0) {
            values.emplace_back(std::monostate{});
        } else if (type <= 6) {
            const size_t width = kIntWidths[type];
            if (body + width > bytes.size()) return std::nullopt;
            uint64_t raw = BigEndian(bytes, body, width);
            // Sign-extend from the stored width.
            if (width < 8 && (raw & (uint64_t{1} << (width * 8 - 1)))) raw |= ~uint64_t{0} << (width * 8);
            values.emplace_back(static_cast<int64_t>(raw));
            body += width;
        } else if (type == 7) {
            if (body + 8 > bytes.size()) return std::nullopt;
            const uint64_t raw = BigEndian(bytes, body, 8);
            double d;
            std::memcpy(&d, &raw, sizeof d);
            values.emplace_back(d);
            body += 8;
        } else if (type == 8 || type == 9) {
            values.emplace_back(static_cast<int64_t>(type - 8));
        } else if (type >= 12) {
            const size_t length = static_cast<size_t>((type - (type % 2 ? 13 : 12)) / 2);
            if (length > bytes.size() || body + length > bytes.size()) return std::nullopt;
            std::string data(bytes.substr(body, length));
            if (type % 2) values.emplace_back(std::move(data));
            else values.emplace_back(Blob{std::move(data)});
            body += length;
        } else {
            return std::nullopt;  // 10 and 11 are reserved
        }
    }
    return values;
}

// Tokens of a CREATE TABLE statement: words, quoted names and strings, and punctuation.
struct Token {
    enum class Kind { Word, Name, String, Punct } kind;
    std::string text;
};

std::vector<Token> Tokens(std::string_view sql) {
    std::vector<Token> out;
    size_t i = 0;
    while (i < sql.size()) {
        const char c = sql[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') {
            ++i;
        } else if (c == '-' && i + 1 < sql.size() && sql[i + 1] == '-') {
            while (i < sql.size() && sql[i] != '\n') ++i;
        } else if (c == '/' && i + 1 < sql.size() && sql[i + 1] == '*') {
            const size_t end = sql.find("*/", i + 2);
            i = end == std::string_view::npos ? sql.size() : end + 2;
        } else if (c == '\'' || c == '"' || c == '`' || c == '[') {
            const char close = c == '[' ? ']' : c;
            std::string text;
            size_t j = i + 1;
            while (j < sql.size()) {
                if (sql[j] == close) {
                    // A doubled quote is one quote (not inside [...]).
                    if (close != ']' && j + 1 < sql.size() && sql[j + 1] == close) {
                        text += close;
                        j += 2;
                        continue;
                    }
                    break;
                }
                text += sql[j++];
            }
            out.push_back({c == '\'' ? Token::Kind::String : Token::Kind::Name, std::move(text)});
            i = j + 1;
        } else if (c == '(' || c == ')' || c == ',') {
            out.push_back({Token::Kind::Punct, std::string(1, c)});
            ++i;
        } else {
            size_t j = i;
            while (j < sql.size() && !std::strchr(" \t\n\r\f(),'\"`[", sql[j])) ++j;
            if (j == i) j = i + 1;
            out.push_back({Token::Kind::Word, std::string(sql.substr(i, j - i))});
            i = j;
        }
    }
    return out;
}

bool IsWord(const Token& t, std::string_view word) { return t.kind == Token::Kind::Word && EqualsIgnoringCase(t.text, word); }

SqlValue Literal(const std::vector<Token>& def, size_t at) {
    if (at >= def.size()) return std::monostate{};
    const Token& t = def[at];
    if (t.kind == Token::Kind::String) return t.text;
    if (t.kind != Token::Kind::Word) return std::monostate{};
    std::string text = t.text;
    // A sign comes as its own word only when spaced ("- 1"); "-1" is one word.
    if ((text == "-" || text == "+") && at + 1 < def.size() && def[at + 1].kind == Token::Kind::Word) text += def[at + 1].text;
    if (EqualsIgnoringCase(text, "TRUE")) return int64_t{1};
    if (EqualsIgnoringCase(text, "FALSE")) return int64_t{0};
    const char* begin = text.data() + (text[0] == '+' ? 1 : 0);
    const char* end = text.data() + text.size();
    int64_t n = 0;
    if (auto [p, error] = std::from_chars(begin, end, n); error == std::errc() && p == end) return n;
    double d = 0;
    if (auto [p, error] = std::from_chars(begin, end, d); error == std::errc() && p == end) return d;
    return std::monostate{};
}

}  // namespace

std::optional<size_t> Table::Column(std::string_view name) const { return ColumnIndex(columns, name); }

std::optional<size_t> ColumnIndex(const std::vector<std::string>& columns, std::string_view name) {
    for (size_t i = 0; i < columns.size(); ++i) {
        if (EqualsIgnoringCase(columns[i], name)) return i;
    }
    return std::nullopt;
}

std::optional<std::vector<ColumnDefinition>> ParseColumns(std::string_view createTable) {
    const std::vector<Token> tokens = Tokens(createTable);
    size_t at = 0;
    while (at < tokens.size() && !(tokens[at].kind == Token::Kind::Punct && tokens[at].text == "(")) ++at;
    if (at == tokens.size()) return std::nullopt;
    ++at;
    std::vector<ColumnDefinition> columns;
    std::vector<Token> def;
    int depth = 0;
    auto finish = [&] {
        if (def.empty()) return;
        const Token& first = def.front();
        const bool constraint = first.kind == Token::Kind::Word &&
                                (IsWord(first, "CONSTRAINT") || IsWord(first, "PRIMARY") || IsWord(first, "UNIQUE") ||
                                 IsWord(first, "CHECK") || IsWord(first, "FOREIGN"));
        if (!constraint && (first.kind == Token::Kind::Word || first.kind == Token::Kind::Name || first.kind == Token::Kind::String)) {
            ColumnDefinition column{first.text, std::monostate{}, false};
            bool integer = def.size() > 1 && IsWord(def[1], "INTEGER");
            for (size_t i = 1; i < def.size(); ++i) {
                if (IsWord(def[i], "DEFAULT")) column.defaultValue = Literal(def, i + 1);
                if (IsWord(def[i], "PRIMARY") && i + 1 < def.size() && IsWord(def[i + 1], "KEY") && integer) {
                    column.rowidAlias = !(i + 2 < def.size() && IsWord(def[i + 2], "DESC"));
                }
            }
            columns.push_back(std::move(column));
        }
        def.clear();
    };
    for (; at < tokens.size(); ++at) {
        const Token& t = tokens[at];
        if (t.kind == Token::Kind::Punct) {
            if (t.text == "(") ++depth;
            else if (t.text == ")") {
                if (depth == 0) {
                    finish();
                    return columns;
                }
                --depth;
            } else if (t.text == "," && depth == 0) {
                finish();
                continue;
            }
        }
        def.push_back(t);
    }
    return std::nullopt;
}

bool IsHotJournal(std::string_view journal) {
    static constexpr unsigned char kMagic[] = {0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7};
    return journal.size() >= sizeof kMagic && std::memcmp(journal.data(), kMagic, sizeof kMagic) == 0;
}

bool MemoryPages::Read(uint64_t offset, size_t size, std::string& out) {
    if (offset > bytes_.size() || size > bytes_.size() - offset) return false;
    out.assign(bytes_.substr(static_cast<size_t>(offset), size));
    return true;
}

FilePages::FilePages(const std::filesystem::path& file) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(file, error)) return;
    const auto size = std::filesystem::file_size(file, error);
    if (error) return;
    in_.open(file, std::ios::binary);
    if (!in_) return;
    size_ = static_cast<uint64_t>(size);
    open_ = true;
}

bool FilePages::Read(uint64_t offset, size_t size, std::string& out) {
    if (!open_ || offset > size_ || size > size_ - offset) return false;
    out.resize(size);
    in_.clear();
    in_.seekg(static_cast<std::streamoff>(offset));
    in_.read(out.data(), static_cast<std::streamsize>(size));
    // A file cut short since it was opened reads short: that's a read that failed.
    if (static_cast<size_t>(in_.gcount()) != size) return false;
    bytesRead_ += size;
    return true;
}

std::optional<Scan> ScanTable(PageSource& source, std::string_view name,
                              const std::function<bool(const std::vector<std::string>& columns)>& columns,
                              const std::function<bool(std::vector<SqlValue>& values)>& row, const ScanOptions& options) {
    Reader reader(source);
    if (!reader.Open()) return std::nullopt;
    // The schema (sqlite_schema: type, name, tbl_name, rootpage, sql) is small: page 1's tree.
    std::optional<uint64_t> root;
    std::string sql;
    const CellVisitor schema = [&](int64_t, const std::string* bytes) {
        if (!bytes) return true;
        auto values = Record(*bytes);
        if (!values || values->size() < 5) return true;
        auto* type = std::get_if<std::string>(&(*values)[0]);
        auto* tableName = std::get_if<std::string>(&(*values)[1]);
        auto* page = std::get_if<int64_t>(&(*values)[3]);
        auto* text = std::get_if<std::string>(&(*values)[4]);
        if (type && *type == "table" && tableName && EqualsIgnoringCase(*tableName, name) && page && *page > 0 && text) {
            root = static_cast<uint64_t>(*page);
            sql = std::move(*text);
            return false;
        }
        return true;
    };
    // A schema row is a CREATE statement: one past kMaxSchemaRecordBytes isn't one Chromium wrote,
    // and is left unread (so a crafted 1 GiB overflow chain there costs nothing).
    if (!reader.Rows(1, schema, kMaxSchemaRecordBytes, options.cancel)) return std::nullopt;
    if (reader.Stopped() && !root) return std::nullopt;  // cancelled
    if (!root) return std::nullopt;
    auto definitions = ParseColumns(sql);
    if (!definitions || definitions->empty()) return std::nullopt;
    std::vector<std::string> names;
    for (const ColumnDefinition& d : *definitions) names.push_back(d.name);
    Scan scan;
    if (!columns(names)) {
        scan.stopped = true;
        return scan;
    }

    bool broken = false;
    const CellVisitor cells = [&](int64_t rowid, const std::string* bytes) {
        if (!bytes) {
            ++scan.oversized;
            return true;
        }
        auto values = Record(*bytes);
        if (!values || values->size() > definitions->size()) {
            broken = true;
            return false;
        }
        // A row written before ALTER TABLE ADD COLUMN has fewer values: the rest take their DEFAULT.
        for (size_t i = values->size(); i < definitions->size(); ++i) values->push_back((*definitions)[i].defaultValue);
        for (size_t i = 0; i < definitions->size(); ++i) {
            if ((*definitions)[i].rowidAlias && std::holds_alternative<std::monostate>((*values)[i])) (*values)[i] = rowid;
        }
        ++scan.rows;
        return row(*values);
    };
    if (!reader.Rows(*root, cells, options.maxRecordBytes, options.cancel) || broken) return std::nullopt;
    scan.stopped = reader.Stopped();
    return scan;
}

std::optional<Table> ReadTable(std::string_view file, std::string_view name) {
    MemoryPages source(file);
    Table table;
    auto scan = ScanTable(
        source, name,
        [&](const std::vector<std::string>& columns) {
            table.columns = columns;
            return true;
        },
        [&](std::vector<SqlValue>& values) {
            table.rows.push_back(std::move(values));
            return true;
        });
    if (!scan) return std::nullopt;
    return table;
}

std::optional<Journal> HeaderJournal(std::string_view header) {
    if (header.size() < 20 || std::memcmp(header.data(), "SQLite format 3\0", 16) != 0) return std::nullopt;
    const unsigned char write = static_cast<unsigned char>(header[18]), read = static_cast<unsigned char>(header[19]);
    if (write == 1 && read == 1) return Journal::Rollback;
    if (write == 2 && read == 2) return Journal::WriteAheadLog;
    return std::nullopt;
}

}  // namespace kite::sqlite
