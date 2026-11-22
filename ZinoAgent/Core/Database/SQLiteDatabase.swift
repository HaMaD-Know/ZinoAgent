import Foundation
import SQLite3

public enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteRow: Sendable {
    private let values: [String: SQLiteValue]

    public init(values: [String: SQLiteValue]) {
        self.values = values
    }

    public func string(_ column: String) -> String? {
        if case let .text(v) = values[column] { return v }
        return nil
    }

    public func int(_ column: String) -> Int? {
        if case let .integer(v) = values[column] { return Int(v) }
        return nil
    }

    public func int64(_ column: String) -> Int64? {
        if case let .integer(v) = values[column] { return v }
        return nil
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case let .real(v): return v
        case let .integer(v): return Double(v)
        default: return nil
        }
    }

    public func bool(_ column: String) -> Bool {
        (int64(column) ?? 0) != 0
    }

    public func data(_ column: String) -> Data? {
        if case let .blob(v) = values[column] { return v }
        return nil
    }

    public func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }
}

/// Thread-safe native SQLite3 driver with WAL journaling, foreign keys, parameterized statements, and transactions.
public final class SQLiteDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zinoagent.sqlite", qos: .userInitiated)
    private var db: OpaquePointer?
    public let path: String

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed (\(rc))"
            if let handle { sqlite3_close(handle) }
            throw ZinoError(.databaseFailure, "Failed to open database: \(msg)")
        }
        self.db = handle
        try execute("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try queue.sync {
            try executeLocked(sql, bindings: bindings)
        }
    }

    public func executeScript(_ sql: String) throws {
        try queue.sync {
            guard let db else { throw ZinoError(.databaseFailure, "Database is closed.") }
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(errMsg)
                throw ZinoError(.databaseFailure, "SQLite script error: \(message)")
            }
        }
    }

    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try queue.sync {
            try queryLocked(sql, bindings: bindings)
        }
    }

    public func transaction<T>(_ work: () throws -> T) throws -> T {
        try queue.sync {
            try executeLocked("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let result = try work()
                try executeLocked("COMMIT;")
                return result
            } catch {
                try? executeLocked("ROLLBACK;")
                throw error
            }
        }
    }

    /// Execute inside an already-acquired transaction closure without re-entering the serial queue.
    public func executeInTransaction(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try executeLocked(sql, bindings: bindings)
    }

    public func queryInTransaction(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try queryLocked(sql, bindings: bindings)
    }

    private func executeLocked(_ sql: String, bindings: [SQLiteValue] = []) throws {
        guard let db else { throw ZinoError(.databaseFailure, "Database is closed.") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ZinoError(.databaseFailure, "SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt, db: db)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw ZinoError(.databaseFailure, "SQLite step error (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func queryLocked(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let db else { throw ZinoError(.databaseFailure, "Database is closed.") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ZinoError(.databaseFailure, "SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt, db: db)

        var rows: [SQLiteRow] = []
        let columnCount = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var dict: [String: SQLiteValue] = [:]
                dict.reserveCapacity(Int(columnCount))
                for idx in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(stmt, idx))
                    switch sqlite3_column_type(stmt, idx) {
                    case SQLITE_NULL:
                        dict[name] = .null
                    case SQLITE_INTEGER:
                        dict[name] = .integer(sqlite3_column_int64(stmt, idx))
                    case SQLITE_FLOAT:
                        dict[name] = .real(sqlite3_column_double(stmt, idx))
                    case SQLITE_TEXT:
                        if let ptr = sqlite3_column_text(stmt, idx) {
                            dict[name] = .text(String(cString: ptr))
                        } else {
                            dict[name] = .text("")
                        }
                    case SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(stmt, idx))
                        if length > 0, let bytes = sqlite3_column_blob(stmt, idx) {
                            dict[name] = .blob(Data(bytes: bytes, count: length))
                        } else {
                            dict[name] = .blob(Data())
                        }
                    default:
                        dict[name] = .null
                    }
                }
                rows.append(SQLiteRow(values: dict))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw ZinoError(.databaseFailure, "SQLite query error (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return rows
    }

    private func bind(_ values: [SQLiteValue], to stmt: OpaquePointer, db: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case let .integer(v):
                rc = sqlite3_bind_int64(stmt, idx, v)
            case let .real(v):
                rc = sqlite3_bind_double(stmt, idx, v)
            case let .text(v):
                rc = sqlite3_bind_text(stmt, idx, v, -1, Self.sqliteTransient)
            case let .blob(data):
                rc = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(data.count), Self.sqliteTransient)
                }
            }
            guard rc == SQLITE_OK else {
                throw ZinoError(.databaseFailure, "SQLite bind error at index \(idx): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }
}
