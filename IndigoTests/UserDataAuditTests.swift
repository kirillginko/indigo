//
//  UserDataAuditTests.swift
//  IndigoTests
//
//  Counts, id digests, invariants and counter writers of a real UserData
//  store: the local half of the Production checkpoint, compared with what
//  `cktool` reads back from CloudKit.
//
//  Opt-in, and never against the live store. Put a *copy* of one at
//  `audit/UserData.store` in the app's Application Support (the test host is
//  the sandboxed app, so it can read nothing else, and xcodebuild passes no
//  environment to it); the report is written to `audit/report.txt` beside it.
//  Opening the copy writes to it.
//

import XCTest
import SwiftData
@testable import Indigo

final class UserDataAuditTests: XCTestCase {
    private var directory: URL { StoreLayout.standard.directory.appendingPathComponent("audit", isDirectory: true) }
    private var store: URL { directory.appendingPathComponent("UserData.store") }

    func testAuditTheStoreCopy() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: store.path), "No copy at \(store.path)")
        let context = ModelContext(try Persistence.makeSplitContainer(userData: store, local: nil))

        func line(_ entity: String, _ ids: [UUID]) -> String {
            let strings = ids.map(\.uuidString)
            return "\(entity): rows \(strings.count), distinct ids \(Set(strings).count), digest \(RowIDs.digest(Array(Set(strings))))"
        }
        let counters = try context.fetch(FetchDescriptor<DigCounter>())
        let violations = UserDataInvariants.violations(in: context)
        var report = [
            line("CrateItem", try context.fetch(FetchDescriptor<CrateItem>()).map(\.id)),
            line("ListeningEvent", try context.fetch(FetchDescriptor<ListeningEvent>()).map(\.id)),
            line("DigVisit", try context.fetch(FetchDescriptor<DigVisit>()).compactMap(\.id)),
            line("DigStep", try context.fetch(FetchDescriptor<DigStep>()).compactMap(\.id)),
            line("DigCounter", counters.compactMap(\.id)),
            "generation: \(SyncGeneration.advertised(in: context).map(String.init) ?? "none")",
            "writers: " + UserDataInvariants.writers(in: context)
                .map { ($0.key == CounterID.base ? "base" : String($0.key.prefix(8))) + " \($0.value)" }.sorted().joined(separator: ", "),
            "invariant violations: \(violations.count)"
        ]
        report += violations.prefix(20).map { "  \($0)" }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text)
        XCTAssertEqual(violations, [])
    }
}
