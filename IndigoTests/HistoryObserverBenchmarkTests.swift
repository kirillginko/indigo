//
//  HistoryObserverBenchmarkTests.swift
//  IndigoTests
//
//  One history-observer pass with no saved position, over copies of real
//  stores: the pass a new UserData store makes at launch beside a cache with a
//  long history of its own. On 2026-10-03 that pass held the main thread for
//  41 seconds (36.5 of them reading the cache's 38,569 transactions); it now
//  reads no history and takes about a second.
//
//  Opt-in. Put consistent copies at `audit/history-bench/UserData.store` and
//  `Local.store` in the app's Application Support; the timings go to
//  `audit/history-bench/report.txt`. Opening the copies writes to them.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class HistoryObserverBenchmarkTests: XCTestCase {
    private var directory: URL { StoreLayout.standard.directory.appendingPathComponent("audit/history-bench", isDirectory: true) }

    func testAPassWithNoPositionOverRealStores() throws {
        let userData = directory.appendingPathComponent("UserData.store")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: userData.path), "No copies at \(directory.path)")
        let container = try Persistence.makeSplitContainer(userData: userData, local: directory.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        context.author = "bench"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HistoryObserverBenchmark-\(UUID().uuidString)"))
        var observer = HistoryObserver(context: context, defaults: defaults, ownAuthor: "bench")
        var seen = HistoryObserver.Pass()
        observer.onPass = { seen = $0 }

        let started = Date()
        let report = observer.process()
        let first = Date().timeIntervalSince(started)
        let again = Date()
        _ = observer.process()
        let second = Date().timeIntervalSince(again)

        let text = """
        first pass: \(Int(first * 1000))ms, transactions \(seen.transactions), foreign \(seen.foreign), named \(seen.named), merged \(report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged + report.countersMerged)
        second pass: \(Int(second * 1000))ms

        """
        try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text)
    }
}
