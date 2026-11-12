import Foundation
import SQLite3

public struct DBError: Error, LocalizedError, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
    public var errorDescription: String? { message }
    /// True only for a damaged or non-database file, never for busy/permission/disk-full errors.
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system SQLite. Values travel as Int64, Double, String or nil.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let failure = lastError()
            close()
            throw failure
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { close() }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    private func lastError() -> DBError {
        DBError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements without parameters or results.
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    /// Runs a single statement with bound parameters and returns its rows.
    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            let n = Int32(i + 1)
            switch param {
            case nil: sqlite3_bind_null(stmt, n)
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, SQLITE_TRANSIENT)
            default: throw DBError(code: SQLITE_MISUSE, message: "unsupported parameter type")
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            rows.append((0..<sqlite3_column_count(stmt)).map { i -> Any? in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: return sqlite3_column_text(stmt, i).map { String(cString: $0) }
                default: return nil
                }
            })
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
