import Foundation
import SQLite3

enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    var int64: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }

    var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    var data: Data? {
        switch self {
        case .blob(let v): return v
        case .text(let v): return Data(v.utf8)
        default: return nil
        }
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

/// SQLite's "copy this buffer now" destructor sentinel.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system SQLite C API.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(description: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }

        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = Self.value(statement, column)
            }
            rows.append(row)
        }
        return rows
    }

    private static func value(_ statement: OpaquePointer?, _ column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
