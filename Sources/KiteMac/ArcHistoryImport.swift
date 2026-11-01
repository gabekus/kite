import Foundation
import KiteCore
import SQLite3

// Arc's browsing history, for "Import from Arc…". Arc keeps it where Chromium
// does: the `urls` table of the profile's "History" database.
// Delete with ArcImportController.swift once Arc has shut down.

enum ArcHistoryImport {
    /// One row per page, newest first, as many as Kite's history keeps. Hidden rows
    /// (subframes and redirects Chromium leaves off its history page) are left out.
    static func read(from file: URL) -> [HistoryEntry] {
        // Arc keeps the database open and locked, so read a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kite-arc-history-\(UUID().uuidString)")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(History.maxEntries)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  History.records(url)
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            entries.append(HistoryEntry(
                url: url,
                title: title,
                lastVisit: History.chromiumDate(sqlite3_column_int64(statement, 3)),
                visitCount: max(1, Int(sqlite3_column_int64(statement, 2)))
            ))
        }
        return entries
    }
}
