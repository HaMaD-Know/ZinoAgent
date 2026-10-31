import Foundation
import Capacitor
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, dependency-free SQLite bridge over the system SQLite3 library.
/// All access is serialized on one queue; the TypeScript layer owns schema + migrations.
@objc(ZinoDatabasePlugin)
public class ZinoDatabasePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoDatabasePlugin"
    public let jsName = "ZinoDatabase"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "execute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "run", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "query", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "batch", returnType: CAPPluginReturnPromise)
    ]

    private let queue = DispatchQueue(label: "com.zinoagent.database")
    private var db: OpaquePointer?

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    @objc func open(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "zino"
        guard name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            call.reject("Invalid database name", "INVALID_ARGUMENT"); return
        }
        queue.async {
            do {
                if self.db != nil { call.resolve(["path": self.dbRelPath(name)]); return }
                let url = try ZinoPaths.resolve(self.dbRelPath(name))
                try ZinoPaths.ensureParent(url)
                var handle: OpaquePointer?
                let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
                    let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                    if let handle { sqlite3_close_v2(handle) }
                    throw ZinoError("DATABASE_ERROR", "Could not open database: \(msg)")
                }
                self.db = handle
                try self.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
                call.resolve(["path": self.dbRelPath(name)])
            } catch {
                call.zinoReject(error)
            }
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        queue.async {
            if let db = self.db { sqlite3_close_v2(db) }
            self.db = nil
            call.resolve()
        }
    }

    /// Execute one or more statements without parameters (used for migrations).
    @objc func execute(_ call: CAPPluginCall) {
        guard let sql = call.getString("sql") else { call.reject("sql is required", "INVALID_ARGUMENT"); return }
        queue.async {
            do {
                try self.exec(sql)
                call.resolve(["changes": Int(sqlite3_changes(self.db))])
            } catch { call.zinoReject(error) }
        }
    }

    @objc func run(_ call: CAPPluginCall) {
        guard let sql = call.getString("sql") else { call.reject("sql is required", "INVALID_ARGUMENT"); return }
        let values = call.getArray("values") ?? []
        queue.async {
            do {
                let result = try self.runStatement(sql, values)
                call.resolve(result)
            } catch { call.zinoReject(error) }
        }
    }

    @objc func query(_ call: CAPPluginCall) {
        guard let sql = call.getString("sql") else { call.reject("sql is required", "INVALID_ARGUMENT"); return }
        let values = call.getArray("values") ?? []
        queue.async {
            do {
                let rows = try self.queryRows(sql, values)
                call.resolve(["rows": rows])
            } catch { call.zinoReject(error) }
        }
    }

    /// Run several parameterized statements atomically.
    @objc func batch(_ call: CAPPluginCall) {
        guard let statements = call.getArray("statements") as? [JSObject] else {
            call.reject("statements is required", "INVALID_ARGUMENT"); return
        }
        queue.async {
            do {
                try self.exec("BEGIN IMMEDIATE;")
                var changes = 0
                do {
                    for st in statements {
                        guard let sql = st["sql"] as? String else { throw ZinoError("INVALID_ARGUMENT", "Statement missing sql") }
                        let values = (st["values"] as? JSArray) ?? []
                        let r = try self.runStatement(sql, values)
                        changes += (r["changes"] as? Int) ?? 0
                    }
                    try self.exec("COMMIT;")
                } catch {
                    try? self.exec("ROLLBACK;")
                    throw error
                }
                call.resolve(["changes": changes])
            } catch { call.zinoReject(error) }
        }
    }

    // MARK: - Internals (must be called on `queue`)

    private func dbRelPath(_ name: String) -> String { "db/\(name).sqlite" }

    private func requireDB() throws -> OpaquePointer {
        guard let db else { throw ZinoError("DATABASE_NOT_OPEN", "Database is not open.") }
        return db
    }

    private func lastError() -> String {
        guard let db else { return "database not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) throws {
        let db = try requireDB()
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError()
            sqlite3_free(err)
            throw ZinoError("DATABASE_ERROR", msg)
        }
    }

    private func prepare(_ sql: String, _ values: JSArray) throws -> OpaquePointer {
        let db = try requireDB()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ZinoError("DATABASE_ERROR", lastError())
        }
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        if expected != values.count {
            sqlite3_finalize(stmt)
            throw ZinoError("DATABASE_ERROR", "Expected \(expected) parameters, got \(values.count)")
        }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case is NSNull:
                rc = sqlite3_bind_null(stmt, idx)
            case let s as String:
                rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    rc = sqlite3_bind_int64(stmt, idx, n.boolValue ? 1 : 0)
                } else if CFNumberIsFloatType(n) {
                    let d = n.doubleValue
                    if d.rounded() == d && abs(d) < 9.0e15 {
                        rc = sqlite3_bind_int64(stmt, idx, Int64(d))
                    } else {
                        rc = sqlite3_bind_double(stmt, idx, d)
                    }
                } else {
                    rc = sqlite3_bind_int64(stmt, idx, n.int64Value)
                }
            case let i as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(i))
            case let d as Double:
                rc = sqlite3_bind_double(stmt, idx, d)
            case let b as Bool:
                rc = sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            default:
                rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw ZinoError("DATABASE_ERROR", lastError())
            }
        }
        return stmt
    }

    private func runStatement(_ sql: String, _ values: JSArray) throws -> [String: Any] {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw ZinoError("DATABASE_ERROR", lastError()) }
        let db = try requireDB()
        return ["changes": Int(sqlite3_changes(db)), "lastId": Int(sqlite3_last_insert_rowid(db))]
    }

    private func queryRows(_ sql: String, _ values: JSArray) throws -> [[String: Any]] {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        let count = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZinoError("DATABASE_ERROR", lastError()) }
            var row: [String: Any] = [:]
            for c in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT:
                    if let p = sqlite3_column_text(stmt, c) { row[name] = String(cString: p) } else { row[name] = NSNull() }
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 {
                        row[name] = Data(bytes: p, count: n).base64EncodedString()
                    } else { row[name] = "" }
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }
}
