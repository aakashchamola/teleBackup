import Foundation
import SQLite3

public enum DbValue { case null, int(Int64), text(String), real(Double) }
extension Int64 { var v: DbValue { .int(self) } }
extension Optional where Wrapped == Int64 { var v: DbValue { self.map { .int($0) } ?? .null } }
extension Optional where Wrapped == Int { var v: DbValue { self.map { .int(Int64($0)) } ?? .null } }
extension Optional where Wrapped == String { var v: DbValue { self.map { .text($0) } ?? .null } }
extension String { var v: DbValue { .text(self) } }
extension Int { var v: DbValue { .int(Int64(self)) } }
extension Bool { var v: DbValue { .int(self ? 1 : 0) } }

public struct Row {
    let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func optInt(_ i: Int32) -> Int64? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i) }
    public func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    public func optText(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i) }
    public func bool(_ i: Int32) -> Bool { int(i) != 0 }
}

/// A thin, serialised wrapper over the system SQLite.
public final class Db {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw NSError(domain: "Db", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open the database"])
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=OFF;")
    }
    deinit { sqlite3_close(handle) }

    @discardableResult
    public func exec(_ sql: String, _ args: [DbValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if args.isEmpty {   // may hold several statements
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw err() }
            return Int(sqlite3_changes(handle))
        }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        bind(st!, args)
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { rc = sqlite3_step(st) }
        guard rc == SQLITE_DONE else { throw err() }
        return Int(sqlite3_changes(handle))
    }

    public func insert(_ sql: String, _ args: [DbValue]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try exec(sql, args)
        return sqlite3_last_insert_rowid(handle)
    }

    public func query<T>(_ sql: String, _ args: [DbValue] = [], _ map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        bind(st!, args)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(map(Row(stmt: st!))) } else if rc == SQLITE_DONE { break } else { throw err() }
        }
        return out
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN")
        do { let r = try body(); try exec("COMMIT"); return r } catch { try? exec("ROLLBACK"); throw error }
    }

    private func bind(_ st: OpaquePointer, _ args: [DbValue]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(st, n)
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .real(let v): sqlite3_bind_double(st, n, v)
            case .text(let s): sqlite3_bind_text(st, n, s, -1, transient)
            }
        }
    }
    private func err() -> NSError {
        NSError(domain: "Db", code: Int(sqlite3_errcode(handle)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
}
