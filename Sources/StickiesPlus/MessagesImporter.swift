import Foundation

struct SelfText {
    let rowID: Int64
    let text: String
    let date: Date
}

/// Reads texts you've sent to yourself from the Messages database (read-only).
struct MessagesImporter {
    /// Seconds between the Unix epoch and Apple's 2001 reference date.
    private static let appleEpochOffset: TimeInterval = 978_307_200
    private static let nanosecondsPerSecond: Double = 1_000_000_000
    /// Messages' chat style for one-on-one conversations.
    private static let oneOnOneChatStyle: Int64 = 45
    /// Sent and received copies of the same self-text land within this window.
    private static let duplicateWindow: TimeInterval = 120

    let chatDBPath: String
    /// Extra phone numbers / emails the user told us are theirs.
    let extraHandles: [String]

    /// Highest message row id right now; used as the import high-water mark.
    func latestRowID() throws -> Int64 {
        let db = try SQLiteDatabase(path: chatDBPath, readOnly: true)
        return try db.query("SELECT MAX(ROWID) AS max FROM message").first?["max"]?.int64 ?? 0
    }

    func selfTexts(afterRowID lowerBound: Int64, upToRowID upperBound: Int64, since: Date? = nil) throws -> [SelfText] {
        let db = try SQLiteDatabase(path: chatDBPath, readOnly: true)
        let chatIDs = try selfChatIDs(db)
        guard !chatIDs.isEmpty else { return [] }

        var sql = """
            SELECT m.ROWID AS rowid, m.text AS text, m.attributedBody AS body, m.date AS date
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id IN (\(chatIDs.map(String.init).joined(separator: ",")))
              AND m.ROWID > ? AND m.ROWID <= ?
              AND COALESCE(m.associated_message_type, 0) = 0
              AND COALESCE(m.item_type, 0) = 0
            """
        var params: [SQLValue] = [.integer(lowerBound), .integer(upperBound)]
        if let since {
            sql += " AND m.date > ?"
            params.append(.integer(Int64((since.timeIntervalSince1970 - Self.appleEpochOffset) * Self.nanosecondsPerSecond)))
        }
        sql += " ORDER BY m.ROWID"

        var results: [SelfText] = []
        for row in try db.query(sql, params) {
            guard let rowID = row["rowid"]?.int64 else { continue }
            let raw = row["text"]?.string ?? row["body"]?.data.flatMap(AttributedBodyDecoder.text(from:)) ?? ""
            let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "")  // attachment placeholder
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let date = Self.date(fromAppleTimestamp: row["date"]?.int64 ?? 0)
            let isDuplicate = results.contains {
                $0.text == text && abs($0.date.timeIntervalSince(date)) < Self.duplicateWindow
            }
            if !isDuplicate { results.append(SelfText(rowID: rowID, text: text, date: date)) }
        }
        return results
    }

    /// One-on-one chats whose other participant is one of your own handles.
    private func selfChatIDs(_ db: SQLiteDatabase) throws -> [Int64] {
        var handles = Set(extraHandles.map(Self.normalize))
        let callerIDs = (try? db.query("""
            SELECT DISTINCT destination_caller_id AS handle FROM message
            WHERE is_from_me = 1 AND destination_caller_id IS NOT NULL AND destination_caller_id != ''
            """)) ?? []
        let accountLogins = (try? db.query("SELECT DISTINCT account_login AS handle FROM chat WHERE account_login IS NOT NULL")) ?? []
        for row in callerIDs + accountLogins {
            if let handle = row["handle"]?.string { handles.insert(Self.normalize(handle)) }
        }
        handles.remove("")

        return try db.query("SELECT ROWID AS id, chat_identifier AS identifier, style FROM chat").compactMap { row in
            guard let id = row["id"]?.int64, let identifier = row["identifier"]?.string,
                  handles.contains(Self.normalize(identifier)) else { return nil }
            if let style = row["style"]?.int64, style != Self.oneOnOneChatStyle { return nil }
            return id
        }
    }

    /// Compares emails case-insensitively and phone numbers by their last 10 digits.
    static func normalize(_ handle: String) -> String {
        var value = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if let colon = value.firstIndex(of: ":"), value.distance(from: value.startIndex, to: colon) == 1 {
            value = String(value[value.index(after: colon)...])  // strip "e:" / "p:" account prefixes
        }
        if value.contains("@") { return value }
        return String(value.filter(\.isNumber).suffix(10))
    }

    private static func date(fromAppleTimestamp value: Int64) -> Date {
        // Newer databases store nanoseconds; very old ones store seconds.
        let seconds = value > 100_000_000_000 ? Double(value) / nanosecondsPerSecond : Double(value)
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }
}

/// Pulls the plain string out of Messages' `attributedBody` blob (an NSArchiver typedstream).
/// Parsed by hand because unarchiving untrusted data can raise uncatchable exceptions.
enum AttributedBodyDecoder {
    private static let classMarker = Data("NSString".utf8)
    private static let stringStart: UInt8 = 0x2B  // '+'
    private static let twoByteLength: UInt8 = 0x81
    private static let fourByteLength: UInt8 = 0x82

    static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = data.range(of: classMarker) else { return nil }
        var i = marker.upperBound - data.startIndex
        while i < bytes.count, bytes[i] != stringStart { i += 1 }
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i])
        i += 1
        if bytes[i - 1] == twoByteLength {
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        } else if bytes[i - 1] == fourByteLength {
            guard i + 4 <= bytes.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }
            i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }
}
