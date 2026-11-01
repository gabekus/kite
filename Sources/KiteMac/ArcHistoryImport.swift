import Foundation
import KiteCore

// Arc's browsing history, for "Import from Arc…". Arc keeps it where Chromium
// does: the `urls` table of the profile's "History" database.
// Delete with ArcImportController.swift once Arc has shut down.

enum ArcHistoryImport {
    static func read(from file: URL) -> [HistoryEntry] {
        (try? BrowserHistoryImport.chromium(from: file)) ?? []
    }
}
