//
//  SQLiteFiles.swift
//  Indigo
//
//  The few things done to a database as a file rather than through SwiftData:
//  taking a consistent copy of one, counting rows, and emptying tables.
//
//  They exist so that the listener's old store is only ever *read as bytes*. A
//  copy of its three files is made, and everything after that happens to the
//  copy: SwiftData is never asked to open the original, with this schema or any
//  other, because opening a store with a schema that leaves something out drops
//  what it left out.
//

import Foundation
import SQLite3

nonisolated enum SQLiteFiles {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A compact, consistent copy of the store at `source`, written to
    /// `destination`.
    ///
    /// The three files are copied byte for byte into a scratch directory first,
    /// so the original is not opened by SQLite either -- a database in WAL mode
    /// is changed by being read, since closing it checkpoints the log -- and the
    /// copy is then checkpointed and written out with `VACUUM INTO`.
    static func snapshot(of source: URL, to destination: URL, scratch: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let name = source.lastPathComponent
        let copy = scratch.appendingPathComponent("copy-\(name)")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            let to = URL(fileURLWithPath: copy.path + suffix)
            try? fileManager.removeItem(at: to)
            if fileManager.fileExists(atPath: from.path) { try fileManager.copyItem(at: from, to: to) }
        }
        defer {
            for suffix in ["", "-wal", "-shm"] { try? fileManager.removeItem(at: URL(fileURLWithPath: copy.path + suffix)) }
        }
        try? fileManager.removeItem(at: destination)

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Failure(description: "cannot open the copy of \(name)")
        }
        defer { sqlite3_close(db) }
        try run(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        try run(db, "VACUUM INTO '\(destination.path.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// Writes any log still pending into the main file and removes the sidecar
    /// files, so that the store can be moved as one file.
    static func checkpoint(_ url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Failure(description: "cannot open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        try run(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        try run(db, "PRAGMA journal_mode=DELETE")
    }

    /// Rows in a table, or nil if there is no such table.
    static func count(_ table: String, in url: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : nil
    }

    /// Empties tables in a store that is not open. Used on the copy the cache
    /// is built from, to drop rows of the listener's own that it inherited and
    /// must not keep.
    static func empty(_ tables: [String], in url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Failure(description: "cannot open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        for table in tables { try run(db, "DELETE FROM \(table)") }
        try run(db, "VACUUM")
    }

    private static func run(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw Failure(description: "\(sql): \(text)")
        }
    }
}
