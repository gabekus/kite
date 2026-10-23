import Foundation
import KiteCore
import SQLite3

// Arc's Site Search shortcuts, for "Import from Arc…". Arc keeps them where
// Chromium does: the `keywords` table of the profile's "Web Data" database.
// Delete with ArcImportController.swift once Arc has shut down.

enum ArcSiteSearchImport {
    static var webDataFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data/Default/Web Data")
    }

    /// The shortcuts the user added or turned on, oldest first. Chromium's built-in
    /// engines (Google, Bing…) are left out; Kite has its own default engine setting.
    static func read(from file: URL = webDataFile) -> [SiteSearch] {
        // Arc keeps the database open and locked, so read a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kite-arc-webdata-\(UUID().uuidString)")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // `is_active` (1 = on, 2 = off) only exists in newer Chromium; without it,
        // keep shortcuts the user made (not auto-added from sites they visited).
        let hasIsActive = columns(db, "keywords").contains("is_active")
        let filter = hasIsActive ? "(is_active = 1 OR safe_for_autoreplace = 0)" : "safe_for_autoreplace = 0"
        let sql = "SELECT short_name, keyword, url FROM keywords WHERE prepopulate_id = 0 AND \(filter) ORDER BY date_created"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var sites: [SiteSearch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = text(statement, 0), let shortcut = text(statement, 1), let url = text(statement, 2),
                  let site = SiteSearch(chromiumName: name, keyword: shortcut, url: url)
            else { continue }
            sites.append(site)
        }
        return sites
    }

    private static func columns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
