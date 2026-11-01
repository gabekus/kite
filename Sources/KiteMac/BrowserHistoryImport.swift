import Foundation
import KiteCore
import SQLite3

/// Reads another browser's history database for Import from Arc and Import from Another
/// Browser. Each reader returns one row per page, newest first, as many as Kite's history keeps.
enum BrowserHistoryImport {
    enum Failure: Error {
        /// macOS won't let Kite read the file (Safari's folder needs Full Disk Access).
        case noAccess
        case unreadable
    }

    /// A Chromium profile's "History" database (Chrome, Brave, Edge, Vivaldi, Opera, Arc):
    /// the `urls` table. Hidden rows (subframes and redirects Chromium leaves off its history
    /// page) are left out.
    static func chromium(from file: URL) throws -> [HistoryEntry] {
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(History.maxEntries)"
        return try query(file, sql) { statement in
            (sqlite3_column_int64(statement, 2), History.chromiumDate(sqlite3_column_int64(statement, 3)))
        }
    }

    /// Safari's History.db: a page per `history_items` row, its latest visit's time and title
    /// from `history_visits`.
    static func safari(from file: URL) throws -> [HistoryEntry] {
        let sql = """
            SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id ORDER BY v2.visit_time DESC LIMIT 1),
                   i.visit_count, MAX(v.visit_time) AS last
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY last DESC LIMIT \(History.maxEntries)
            """
        return try query(file, sql) { statement in
            (sqlite3_column_int64(statement, 2), History.safariDate(sqlite3_column_double(statement, 3)))
        }
    }

    /// Firefox's places.sqlite: a page per `moz_places` row that has visits in
    /// `moz_historyvisits`, with its latest visit. Hidden pages (redirect sources, subframes) and
    /// embedded, download and framed-link visits are left out, as Firefox's history leaves them.
    static func firefox(from file: URL) throws -> [HistoryEntry] {
        let sql = """
            SELECT p.url, p.title, p.visit_count, MAX(v.visit_date) AS last
            FROM moz_places p JOIN moz_historyvisits v ON v.place_id = p.id
            WHERE p.hidden = 0 AND v.visit_type NOT IN (4, 7, 8)
            GROUP BY p.id ORDER BY last DESC LIMIT \(History.maxEntries)
            """
        return try query(file, sql) { statement in
            (sqlite3_column_int64(statement, 2), History.firefoxDate(sqlite3_column_int64(statement, 3)))
        }
    }

    /// Firefox's bookmarks: every `moz_bookmarks` row with its page's URL from `moz_places`.
    static func firefoxBookmarks(from file: URL) throws -> [BookmarkImport.FirefoxRow] {
        let sql = """
            SELECT b.id, b.parent, b.type, b.position, COALESCE(NULLIF(b.title, ''), p.title), b.guid, p.url
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
            """
        return try withCopy(file) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable }
            defer { sqlite3_finalize(statement) }
            var rows: [BookmarkImport.FirefoxRow] = []
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(BookmarkImport.FirefoxRow(
                    id: sqlite3_column_int64(statement, 0), parent: sqlite3_column_int64(statement, 1),
                    type: Int(sqlite3_column_int(statement, 2)), position: Int(sqlite3_column_int(statement, 3)),
                    title: text(4), guid: text(5) ?? "", url: text(6)
                ))
            }
            return rows
        }
    }

    /// Whether macOS lets Kite read `file`. Reading anything in ~/Library/Safari needs Full Disk Access.
    static func canRead(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        try? handle.close()
        return true
    }

    /// Runs `sql` on a copy: the browser keeps its database open and locked, and Safari's
    /// recent visits are still in the write-ahead log, which is copied along with it.
    private static func query(
        _ file: URL,
        _ sql: String,
        visits: (OpaquePointer?) -> (count: Int64, last: Date)
    ) throws -> [HistoryEntry] {
        try withCopy(file) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable }
            defer { sqlite3_finalize(statement) }

            var entries: [HistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                      History.records(url)
                else { continue }
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let (count, last) = visits(statement)
                entries.append(HistoryEntry(url: url, title: title, lastVisit: last, visitCount: max(1, Int(count))))
            }
            return entries
        }
    }

    /// Opens a copy of the database (with its write-ahead log) and runs `body` on it. Firefox
    /// keeps places.sqlite locked while it runs; the copy can still be read.
    private static func withCopy<T>(_ file: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { throw Failure.unreadable }
        guard canRead(file) else { throw Failure.noAccess }
        let folder = fm.temporaryDirectory.appendingPathComponent("kite-history-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        guard (try? fm.copyItem(at: file, to: copy)) != nil else { throw Failure.noAccess }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure.unreadable
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }
}
