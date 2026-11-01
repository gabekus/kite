import Foundation
import KiteCore
import SQLite3

/// Recent texts (iMessage and SMS) for VerificationCodeService, read from Messages'
/// own database. macOS lets Kite read it only with Full Disk Access; without it there
/// are simply no texts. Nothing read here is kept or logged.
enum MessagesCodeReader {
    /// ~/Library/Messages/chat.db. Test profiles (KITE_SUPPORT_PATH) never read the real
    /// one: only KITE_TEST_MESSAGES_DB, when it's set.
    static var database: URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil {
            return environment["KITE_TEST_MESSAGES_DB"].map { URL(fileURLWithPath: $0) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    /// Texts received in the last `VerificationCodes.maxAge`, newest first.
    static func recent(now: Date = Date()) -> [VerificationCodes.Message] {
        guard let file = database else { return [] }
        var db: OpaquePointer?
        // Read in place: Messages keeps the database open in WAL mode, and a copy would
        // miss the texts still in the log.
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let sql = """
            SELECT text, attributedBody, date FROM message
            WHERE is_from_me = 0 AND date > ? ORDER BY date DESC LIMIT 50
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, VerificationCodes.messagesTimestamp(now.addingTimeInterval(-VerificationCodes.maxAge)))

        var messages: [VerificationCodes.Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = text(statement) else { continue }
            // Texts have no subject; the whole text stands in for one, so a site named in
            // it ("Solv: your code is…") matches like a mail sender's name does.
            messages.append(.init(subject: text, snippet: "", senderName: "Messages", senderEmail: "",
                                  date: VerificationCodes.messagesDate(sqlite3_column_int64(statement, 2))))
        }
        return messages
    }

    private static func text(_ statement: OpaquePointer?) -> String? {
        if let text = sqlite3_column_text(statement, 0).map({ String(cString: $0) }), !text.isEmpty { return text }
        guard let blob = sqlite3_column_blob(statement, 1) else { return nil }
        let body = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
        return VerificationCodes.messagesText(attributedBody: body)
    }
}
