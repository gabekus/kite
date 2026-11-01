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
