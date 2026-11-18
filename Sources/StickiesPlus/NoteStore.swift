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
    /// Whether the note is shown as a sticky window, or only in the library.
    var isOnDesktop: Bool
    var createdAt: Date
    var updatedAt: Date

    var plainText: String {
        content.isEmpty ? "" : (NSAttributedString(rtfd: content, documentAttributes: nil)?.string ?? "")
    }
}

enum TextCategory: String, CaseIterable {
    case todo, idea, shopping, link, note

    var title: String {
        switch self {
        case .todo: return "To-Do"
        case .idea: return "Ideas"
        case .shopping: return "Shopping"
        case .link: return "Links"
        case .note: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .todo: return "checklist"
        case .idea: return "lightbulb"
        case .shopping: return "cart"
        case .link: return "link"
        case .note: return "text.bubble"
        }
    }
}

/// A text you sent yourself, imported from Messages.
struct TextItem: Identifiable, Equatable {
    var id: Int64
    var text: String
    var date: Date
    /// nil until the classifier has sorted it.
    var category: TextCategory?
    var isDone: Bool
}

enum SettingKey {
    static let inboxNoteID = "inbox_note_id"
    static let messagesLastRowID = "messages_last_rowid"
    static let selfHandles = "self_handles"
    static let watchTexts = "watch_texts"
    static let textsBackfilled = "texts_backfilled"
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
        try db.execute("""
            CREATE TABLE IF NOT EXISTS texts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message_rowid INTEGER NOT NULL UNIQUE,
                text TEXT NOT NULL,
                date REAL NOT NULL,
                category TEXT,
                done INTEGER NOT NULL DEFAULT 0
            )
            """)
        let noteColumns = try db.query("PRAGMA table_info(notes)").compactMap { $0["name"]?.string }
        if !noteColumns.contains("on_desktop") {
            try db.execute("ALTER TABLE notes ADD COLUMN on_desktop INTEGER NOT NULL DEFAULT 1")
        }
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
                isOnDesktop: row["on_desktop"]?.int64 != 0,
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    func createNote(frame: NSRect, color: NoteColor, onDesktop: Bool = true) -> Note {
        let now = Date()
        try? db.execute(
            "INSERT INTO notes (content, color, x, y, w, h, on_desktop, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.blob(Data()), .text(color.rawValue),
             .real(frame.minX), .real(frame.minY), .real(frame.width), .real(frame.height),
             .integer(onDesktop ? 1 : 0), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        return Note(id: db.lastInsertRowID, content: Data(), color: color, frame: frame,
                    isFloating: false, isTranslucent: false, isCollapsed: false, isOnDesktop: onDesktop,
                    createdAt: now, updatedAt: now)
    }

    func save(_ note: Note) {
        try? db.execute(
            """
            UPDATE notes SET content = ?, color = ?, x = ?, y = ?, w = ?, h = ?,
                floating = ?, translucent = ?, collapsed = ?, on_desktop = ?, updated_at = ?
            WHERE id = ?
            """,
            [.blob(note.content), .text(note.color.rawValue),
             .real(note.frame.minX), .real(note.frame.minY), .real(note.frame.width), .real(note.frame.height),
             .integer(note.isFloating ? 1 : 0), .integer(note.isTranslucent ? 1 : 0),
             .integer(note.isCollapsed ? 1 : 0), .integer(note.isOnDesktop ? 1 : 0),
             .real(note.updatedAt.timeIntervalSince1970), .integer(note.id)])
    }

    // MARK: Texts to self

    /// Saves an imported text; returns false if it was already saved.
    @discardableResult
    func insertText(_ text: SelfText) -> Bool {
        try? db.execute(
            "INSERT OR IGNORE INTO texts (message_rowid, text, date) VALUES (?, ?, ?)",
            [.integer(text.rowID), .text(text.text), .real(text.date.timeIntervalSince1970)])
        return ((try? db.query("SELECT changes() AS n").first?["n"]?.int64) ?? 0) > 0
    }

    func allTexts() -> [TextItem] {
        let rows = (try? db.query("SELECT * FROM texts ORDER BY date DESC")) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64 else { return nil }
            return TextItem(
                id: id,
                text: row["text"]?.string ?? "",
                date: Date(timeIntervalSince1970: row["date"]?.double ?? 0),
                category: row["category"]?.string.flatMap(TextCategory.init(rawValue:)),
                isDone: row["done"]?.int64 == 1)
        }
    }

    func setCategory(_ category: TextCategory, forText id: Int64) {
        try? db.execute("UPDATE texts SET category = ? WHERE id = ?", [.text(category.rawValue), .integer(id)])
    }

    func setDone(_ done: Bool, forText id: Int64) {
        try? db.execute("UPDATE texts SET done = ? WHERE id = ?", [.integer(done ? 1 : 0), .integer(id)])
    }

    func deleteText(id: Int64) {
        try? db.execute("DELETE FROM texts WHERE id = ?", [.integer(id)])
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
