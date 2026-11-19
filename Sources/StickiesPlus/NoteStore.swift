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
    /// Optional label. Only titled stickies receive texts.
    var title: String?
    /// Set while the note sits in Window → Recently Closed; nil for open stickies.
    var closedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var plainText: String {
        content.isEmpty ? "" : (NSAttributedString(rtfd: content, documentAttributes: nil)?.string ?? "")
    }

    /// The title, or the first line of text for untitled notes.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        let line = plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Note" : line
    }
}

/// A text-to-self waiting to be filed onto a sticky.
struct PendingText {
    let id: Int64
    let text: String
    let date: Date
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
        try db.execute("""
            CREATE TABLE IF NOT EXISTS texts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message_rowid INTEGER NOT NULL UNIQUE,
                text TEXT NOT NULL,
                date REAL NOT NULL
            )
            """)
        try migrate()
    }

    private func migrate() throws {
        let noteColumns = try db.query("PRAGMA table_info(notes)").compactMap { $0["name"]?.string }
        if !noteColumns.contains("deleted_at") {
            try db.execute("ALTER TABLE notes ADD COLUMN deleted_at REAL")  // closed-at timestamp
        }
        if !noteColumns.contains("title") {
            try db.execute("ALTER TABLE notes ADD COLUMN title TEXT")
        }
        if noteColumns.contains("on_desktop") {
            // Notes that only lived in the old library window become Recently Closed.
            try db.execute("UPDATE notes SET deleted_at = ?, on_desktop = 1 WHERE on_desktop = 0 AND deleted_at IS NULL",
                           [.real(Date().timeIntervalSince1970)])
        }
        let textColumns = try db.query("PRAGMA table_info(texts)").compactMap { $0["name"]?.string }
        if !textColumns.contains("routed") {
            // Existing texts count as already handled, so they aren't re-filed.
            try db.execute("ALTER TABLE texts ADD COLUMN routed INTEGER NOT NULL DEFAULT 1")
        }
        if !textColumns.contains("note_id") {
            try db.execute("ALTER TABLE texts ADD COLUMN note_id INTEGER")
        }
    }

    // MARK: Notes

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
                title: row["title"]?.string,
                closedAt: row["deleted_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    func closedNotes() -> [Note] {
        allNotes().filter { $0.closedAt != nil }.sorted { $0.closedAt! > $1.closedAt! }
    }

    func createNote(frame: NSRect, color: NoteColor, title: String? = nil) -> Note {
        let now = Date()
        try? db.execute(
            "INSERT INTO notes (content, color, x, y, w, h, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.blob(Data()), .text(color.rawValue),
             .real(frame.minX), .real(frame.minY), .real(frame.width), .real(frame.height),
             title.map(SQLValue.text) ?? .null,
             .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        return Note(id: db.lastInsertRowID, content: Data(), color: color, frame: frame,
                    isFloating: false, isTranslucent: false, isCollapsed: false, title: title,
                    closedAt: nil, createdAt: now, updatedAt: now)
    }

    func save(_ note: Note) {
        try? db.execute(
            """
            UPDATE notes SET content = ?, color = ?, x = ?, y = ?, w = ?, h = ?,
                floating = ?, translucent = ?, collapsed = ?, title = ?, updated_at = ?
            WHERE id = ?
            """,
            [.blob(note.content), .text(note.color.rawValue),
             .real(note.frame.minX), .real(note.frame.minY), .real(note.frame.width), .real(note.frame.height),
             .integer(note.isFloating ? 1 : 0), .integer(note.isTranslucent ? 1 : 0),
             .integer(note.isCollapsed ? 1 : 0), note.title.map(SQLValue.text) ?? .null,
             .real(note.updatedAt.timeIntervalSince1970), .integer(note.id)])
    }

    /// Permanently removes a note.
    func deleteNote(id: Int64) {
        try? db.execute("DELETE FROM notes WHERE id = ?", [.integer(id)])
    }

    /// Moves a note to Recently Closed.
    func closeNote(id: Int64) {
        try? db.execute("UPDATE notes SET deleted_at = ? WHERE id = ?",
                        [.real(Date().timeIntervalSince1970), .integer(id)])
    }

    func reopenNote(id: Int64) {
        try? db.execute("UPDATE notes SET deleted_at = NULL WHERE id = ?", [.integer(id)])
    }

    /// Permanently removes notes that have been closed longer than `age`.
    func purgeClosedNotes(olderThan age: TimeInterval) {
        try? db.execute("DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                        [.real(Date().timeIntervalSince1970 - age)])
    }

    // MARK: Texts to self

    /// Saves an imported text for routing; ignores texts already saved.
    func insertText(_ text: SelfText) {
        try? db.execute(
            "INSERT OR IGNORE INTO texts (message_rowid, text, date, routed) VALUES (?, ?, ?, 0)",
            [.integer(text.rowID), .text(text.text), .real(text.date.timeIntervalSince1970)])
    }

    func pendingTexts() -> [PendingText] {
        let rows = (try? db.query("SELECT id, text, date FROM texts WHERE routed = 0 ORDER BY date")) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64, let text = row["text"]?.string else { return nil }
            return PendingText(id: id, text: text, date: Date(timeIntervalSince1970: row["date"]?.double ?? 0))
        }
    }

    func markRouted(textID: Int64, noteID: Int64, filedText: String) {
        try? db.execute("UPDATE texts SET routed = 1, note_id = ?, text = ? WHERE id = ?",
                        [.integer(noteID), .text(filedText), .integer(textID)])
    }

    /// Texts filed onto a note, for the hover timestamps.
    func routedTexts(noteID: Int64) -> [(text: String, date: Date)] {
        let rows = (try? db.query("SELECT text, date FROM texts WHERE note_id = ?", [.integer(noteID)])) ?? []
        return rows.compactMap { row in
            guard let text = row["text"]?.string else { return nil }
            return (text, Date(timeIntervalSince1970: row["date"]?.double ?? 0))
        }
    }

    // MARK: Settings

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
