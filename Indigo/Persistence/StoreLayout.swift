//
//  StoreLayout.swift
//  Indigo
//
//  Which file is which, and what may be done to each.
//
//  There are three. `default.store` is the store the app was built on, holding
//  everything: it is the listener's old data, and nothing here ever deletes it,
//  or asks SwiftData to open it. `UserData.store` is the new home of the crate,
//  the listening log and the dig history, and is not deleted either. `Local.store`
//  holds what can be fetched or rebuilt again, and is the only one that may be
//  thrown away.
//
//  The role comes from the file, not from a flag a caller passes: a path this
//  layout does not know is treated as the listener's data, so a mistake errs
//  toward keeping a file.
//

import Foundation
import SwiftData

nonisolated struct StoreLayout: Equatable, Sendable {
    let directory: URL

    var legacy: URL { directory.appendingPathComponent("default.store") }
    var userData: URL { directory.appendingPathComponent("UserData.store") }
    var local: URL { directory.appendingPathComponent("Local.store") }
    /// Where the state of the move from one store to two is kept. Not inside
    /// either database, so it can be read when neither will open.
    var sidecar: URL { directory.appendingPathComponent("split-state.json") }
    /// What `legacy` is renamed to once the split has proved itself. Never
    /// deleted by anything in this app.
    var archive: URL { directory.appendingPathComponent("pre-split-v5.store") }
    /// Scratch space for the move. Disposable.
    var work: URL { directory.appendingPathComponent("split-work", isDirectory: true) }

    /// The app's own: next to the store SwiftData has always made.
    static var standard: StoreLayout {
        StoreLayout(directory: ModelConfiguration(schema: Persistence.schema).url.deletingLastPathComponent())
    }

    /// A SQLite store is three files, and has to be treated as one.
    func files(of base: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: base.path + $0) }
    }

    func role(of url: URL) -> StoreRole {
        let path = url.standardizedFileURL.path
        for (base, role) in [(local, StoreRole.cache), (legacy, .legacy), (archive, .legacy)] {
            if files(of: base).contains(where: { $0.standardizedFileURL.path == path }) { return role }
        }
        if path.hasPrefix(work.standardizedFileURL.path) { return .cache }
        return .userData
    }
}
