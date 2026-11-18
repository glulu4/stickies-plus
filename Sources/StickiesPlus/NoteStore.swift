import AppKit

enum NoteColor: String, CaseIterable {
    case yellow, blue, green, pink, purple, gray

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.96, blue: 0.62, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.68, green: 0.85, blue: 1.00, alpha: 1)
        case .green: return NSColor(srgbRed: 0.70, green: 0.95, blue: 0.68, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.85, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.85, green: 0.78, blue: 1.00, alpha: 1)
        case .gray: return NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        }
    }
}

struct Note {
    var id: Int64
    /// Note body as RTFD so text styling and images survive.
    var content: Data
    var color: NoteColor
    /// Expanded frame; collapsed notes keep this so they can reopen to the same size.
    var frame: NSRect
    var isFloating: Bool
    var isTranslucent: Bool
    var isCollapsed: Bool
    var createdAt: Date
    var updatedAt: Date
}

enum SettingKey {
    static let inboxNoteID = "inbox_note_id"
    static let messagesLastRowID = "messages_last_rowid"
    static let selfHandles = "self_handles"
    static let watchTexts = "watch_texts"
}

/// Persists notes and app settings in the app's own SQLite file.
final class NoteStore {
    private let db: SQLiteDatabase

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("notes.sqlite").path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content BLOB NOT NULL,
                color TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
                floating INTEGER NOT NULL DEFAULT 0,
                translucent INTEGER NOT NULL DEFAULT 0,
                collapsed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    func allNotes() -> [Note] {
        let rows = (try? db.query("SELECT * FROM notes ORDER BY id")) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64 else { return nil }
            return Note(
                id: id,
                content: row["content"]?.data ?? Data(),
                color: NoteColor(rawValue: row["color"]?.string ?? "") ?? .yellow,
                frame: NSRect(
                    x: row["x"]?.double ?? 0, y: row["y"]?.double ?? 0,
                    width: row["w"]?.double ?? 250, height: row["h"]?.double ?? 250),
                isFloating: row["floating"]?.int64 == 1,
                isTranslucent: row["translucent"]?.int64 == 1,
                isCollapsed: row["collapsed"]?.int64 == 1,
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    func createNote(frame: NSRect, color: NoteColor) -> Note {
        let now = Date()
        try? db.execute(
            "INSERT INTO notes (content, color, x, y, w, h, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.blob(Data()), .text(color.rawValue),
             .real(frame.minX), .real(frame.minY), .real(frame.width), .real(frame.height),
             .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        return Note(id: db.lastInsertRowID, content: Data(), color: color, frame: frame,
                    isFloating: false, isTranslucent: false, isCollapsed: false,
                    createdAt: now, updatedAt: now)
    }

    func save(_ note: Note) {
        try? db.execute(
            """
            UPDATE notes SET content = ?, color = ?, x = ?, y = ?, w = ?, h = ?,
                floating = ?, translucent = ?, collapsed = ?, updated_at = ?
            WHERE id = ?
            """,
            [.blob(note.content), .text(note.color.rawValue),
             .real(note.frame.minX), .real(note.frame.minY), .real(note.frame.width), .real(note.frame.height),
             .integer(note.isFloating ? 1 : 0), .integer(note.isTranslucent ? 1 : 0),
             .integer(note.isCollapsed ? 1 : 0), .real(note.updatedAt.timeIntervalSince1970),
             .integer(note.id)])
    }

    func deleteNote(id: Int64) {
        try? db.execute("DELETE FROM notes WHERE id = ?", [.integer(id)])
    }

    func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?["value"]?.string
    }

    func setSetting(_ key: String, _ value: String?) {
        if let value {
            try? db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try? db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }
}
