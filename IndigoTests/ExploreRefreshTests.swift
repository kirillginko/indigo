//
//  ExploreRefreshTests.swift
//  IndigoTests
//
//  When EXPLORE's kept answer is worked out again. It used to be keyed on the
//  crate's in-process revision, which another device's import never moved and
//  every launch reset -- so a phone went on offering what it offered before the
//  Mac crated something.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreRefreshTests: XCTestCase {
    /// One moment for every read, so no test straddles midnight UTC.
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var directory: URL!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // On disk: these are predicates and sorts, and an in-memory store runs
        // them as Swift.
        container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil; container = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func crate(_ id: String, added: TimeInterval) {
        let item = CrateItem(
            providerID: "nts", showID: id, showTitle: "Show", showSubtitle: nil, artworkURL: nil,
            playbackURL: nil, embedProvider: nil, isLiveStream: false)
        item.addedAt = Date(timeIntervalSince1970: added)
        context.insert(item)
    }

    // MARK: The inputs

    /// The digest of the listener's rows, as the stamp holds it.
    private func personal() -> String {
        CanonicalDigest.of(PersonalInputs.read(context: context, asOf: ExplorePeriod.asOf(ExplorePeriod.containing(Self.now))))
    }

    func testTheInputsMoveWhenTheCrateGainsOrLosesARecord() throws {
        crate("a", added: 100)
        try context.save()
        let before = personal()

        crate("b", added: 50)
        try context.save()
        XCTAssertNotEqual(personal(), before, "an older record still changes the crate")

        for item in try context.fetch(FetchDescriptor<CrateItem>()) where item.showID == "b" { context.delete(item) }
        try context.save()
        XCTAssertEqual(personal(), before)
    }

    func testTheInputsMoveWithTheListeningLog() throws {
        let before = personal()
        context.insert(ListeningEvent(node: .artist("Laurel Halo"), action: .played, at: Self.now, seconds: 300, completion: 1, tags: [], source: nil))
        try context.save()
        XCTAssertNotEqual(personal(), before)
    }

    /// A visit merged in from the other device changes how often somewhere
    /// was returned to, and so where the walk starts, without adding a row.
    func testTheInputsMoveWhenAHauntIsReturnedTo() throws {
        let visit = DigVisit(node: .label("Smalltown Supersound"))
        visit.visits = 2
        context.insert(visit)
        try context.save()
        let before = personal()

        visit.visits = 5
        try context.save()
        XCTAssertNotEqual(personal(), before)
    }

    /// An edit that moves no count and no date -- the other device filling in
    /// a crated record's tags -- is a change too. Counting rows could not see
    /// it; the digest is of what the rows say.
    func testTheInputsMoveWhenACratedRecordIsEdited() throws {
        crate("a", added: 100)
        try context.save()
        let before = personal()

        let item = try XCTUnwrap(context.fetch(FetchDescriptor<CrateItem>()).first)
        item.genreTagsRaw = "dub"
        try context.save()
        XCTAssertNotEqual(personal(), before)
    }

    /// The cache is written to all session long. None of it is an input.
    func testTheInputsIgnoreTheCache() throws {
        crate("a", added: 100)
        try context.save()
        let before = personal()

        context.insert(ExploreOffersRecord(payload: Data(), crateRevision: 0))
        context.insert(DiscogsArtist(nameKey: "someone", discogsID: 9, name: "Someone"))
        try context.save()
        XCTAssertEqual(personal(), before)
    }

    /// Kept beside the answer, so a launch can tell whether the answer it
    /// redraws is still the one it would work out.
    func testAKeptAnswerCarriesItsStamps() throws {
        let stamp = ExploreStamp(format: 1, period: 20_000, personal: "p", shared: "s", deviceLocal: "d")
        let core = ExploreStamp(format: 1, period: 20_000, personal: "p", shared: "c", deviceLocal: "d")
        ExploreOffersStore(context: context).save(ExploreOffers(), stamp: stamp, core: core)

        let kept = try XCTUnwrap(ExploreOffersStore(context: context).load())
        XCTAssertEqual(kept.stamp, stamp)
        XCTAssertEqual(kept.core, core)
    }

    /// An answer kept before the stamps were has none, and is worked out
    /// again rather than trusted.
    func testAnAnswerKeptWithoutStampsIsStillRead() throws {
        let payload = try JSONEncoder().encode(ExploreOffers())
        context.insert(ExploreOffersRecord(payload: payload, crateRevision: 4))
        try context.save()

        let kept = try XCTUnwrap(ExploreOffersStore(context: context).load())
        XCTAssertNil(kept.stamp)
    }

    // MARK: The imports

    func testAnImportOfTheCrateMovesBothRevisions() {
        let imports = UserDataImports()
        imports.note(["CrateItem"])
        imports.apply()
        XCTAssertEqual(imports.crateRevision, 1)
        XCTAssertEqual(imports.exploreRevision, 1)
    }

    func testAnImportOfTheLogMovesOnlyExplore() {
        let imports = UserDataImports()
        imports.note(["ListeningEvent"])
        imports.note(["DigCounter"])
        imports.apply()
        XCTAssertEqual(imports.crateRevision, 0)
        XCTAssertEqual(imports.exploreRevision, 1, "two passes, one bump")
    }

    /// The engine never reads the steps between pages.
    func testAnImportOfStepsAloneMovesNothing() {
        let imports = UserDataImports()
        imports.note(["DigStep"])
        imports.apply()
        XCTAssertEqual(imports.crateRevision, 0)
        XCTAssertEqual(imports.exploreRevision, 0)
    }

    /// A first import arrives in hundreds of passes. They are one bump, once
    /// they have gone quiet.
    func testPassesInQuickSuccessionAreOneBump() async throws {
        let imports = UserDataImports()
        for _ in 0..<20 { imports.note(["CrateItem"]) }
        XCTAssertEqual(imports.exploreRevision, 0, "nothing until the passes stop")
        try await Task.sleep(for: UserDataImports.quiet + .milliseconds(500))
        XCTAssertEqual(imports.exploreRevision, 1)
        XCTAssertEqual(imports.crateRevision, 1)
    }
}
