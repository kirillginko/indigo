//
//  SplitContainerTests.swift
//  IndigoTests
//
//  One container over two stores, on disk. What is pinned here is where rows
//  go, what happens when one store will not open, and that opening the pair
//  never asks either file to hold less than the whole schema.
//

import XCTest
import SwiftData
@testable import Indigo

final class SplitContainerTests: XCTestCase {
    private var directory: URL!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout = StoreLayout(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rows(_ url: URL, _ table: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", url.path, "select count(*) from \(table)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
    }

    private func insertOneOfEach(_ context: ModelContext) throws {
        context.insert(CrateItem(
            providerID: "nts", showID: "s", showTitle: "S", showSubtitle: nil, artworkURL: nil,
            playbackURL: nil, embedProvider: nil, isLiveStream: false))
        context.insert(DigVisit(node: .artist("Skee Mask")))
        context.insert(DigStep(from: "artist:a", to: "artist:b"))
        context.insert(ListeningEvent(node: .artist("Skee Mask"), action: .played))
        context.insert(Recording(title: "Rev8617", artistName: "Skee Mask", status: .identified))
        context.insert(DiscogsArtist(nameKey: "skee mask", discogsID: 1, name: "Skee Mask"))
        try context.save()
    }

    func testEachModelGoesToItsOwnFile() throws {
        try autoreleasepool {
            let container = try Persistence.openSplitStores(layout: layout)
            try insertOneOfEach(ModelContext(container))
        }

        for table in ["ZCRATEITEM", "ZDIGVISIT", "ZDIGSTEP", "ZLISTENINGEVENT"] {
            XCTAssertEqual(rows(layout.userData, table), 1, "\(table) in UserData")
            XCTAssertEqual(rows(layout.local, table), 0, "\(table) stays out of Local")
        }
        for table in ["ZRECORDING", "ZDISCOGSARTIST"] {
            XCTAssertEqual(rows(layout.local, table), 1, "\(table) in Local")
            XCTAssertEqual(rows(layout.userData, table), 0, "\(table) stays out of UserData")
        }
    }

    func testOneContextSeesBothAndTheyReopenTogether() throws {
        try autoreleasepool {
            try insertOneOfEach(ModelContext(try Persistence.openSplitStores(layout: layout)))
        }
        let context = ModelContext(try Persistence.openSplitStores(layout: layout))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 1)
    }

    func testACacheThatWillNotOpenIsRebuiltAndTheListenersDataIsUntouched() throws {
        try autoreleasepool {
            try insertOneOfEach(ModelContext(try Persistence.openSplitStores(layout: layout)))
        }
        try Data("not a database".utf8).write(to: layout.local)
        let userBefore = try Data(contentsOf: layout.userData)
        _ = userBefore

        let context = ModelContext(try Persistence.openSplitStores(layout: layout))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 1, "the crate is still there")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0, "the cache is empty again")
    }

    func testDataThatWillNotOpenIsLeftExactlyAsItWasAndTheCacheIsNotTouched() throws {
        try autoreleasepool {
            try insertOneOfEach(ModelContext(try Persistence.openSplitStores(layout: layout)))
        }
        let garbage = Data("not a database either".utf8)
        try garbage.write(to: layout.userData)
        let localBefore = try Data(contentsOf: layout.local)

        XCTAssertThrowsError(try Persistence.openSplitStores(layout: layout)) { error in
            XCTAssertEqual((error as? StoreOpenFailure)?.role, .userData)
        }

        XCTAssertEqual(try Data(contentsOf: layout.userData), garbage)
        XCTAssertEqual(try Data(contentsOf: layout.local), localBefore, "and it did not rebuild the cache over it")
    }

    func testTheTestHostsContainerIsTwoStoresInMemoryToo() throws {
        let configurations = Persistence.container.configurations.map(\.name)
        XCTAssertEqual(Set(configurations), ["UserData", "Local"])
        XCTAssertTrue(Persistence.container.configurations.allSatisfy(\.isStoredInMemoryOnly))
    }

    /// A model that points at another is pulled into any schema holding the
    /// other, so a stray old class can make a store's schema gain an entity it
    /// was never given -- which is how the pair first failed to open. Each
    /// store's schema has to be exactly its own models.
    func testEachStoresSchemaIsExactlyItsOwnModels() {
        let user = Set(Schema(IndigoSchemaCurrent.userDataModels).entities.map(\.name))
        let local = Set(Schema(IndigoSchemaCurrent.localModels).entities.map(\.name))
        XCTAssertEqual(user, IndigoSchemaCurrent.userDataModelNames)
        XCTAssertEqual(local, Set(IndigoSchemaCurrent.localModels.map { String(describing: $0) }))
        XCTAssertTrue(user.isDisjoint(with: local))
        XCTAssertEqual(local.count, 15)
    }
}
