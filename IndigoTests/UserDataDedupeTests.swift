//
//  UserDataDedupeTests.swift
//  IndigoTests
//
//  Step 5. Two devices that each make a row for the same thing have to agree,
//  without talking, on which row stays and what it holds. That is a property of
//  the merge, so it is tested as one: over every ordering and grouping of the
//  rows, and over a few hundred rows made up at random.
//

import XCTest
import SwiftData
@testable import Indigo

final class UserDataDedupeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserDataDedupeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ name: String = "dedupe.store") throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(
                schema: Persistence.schema, url: directory.appendingPathComponent(name), cloudKitDatabase: .none))
        return (container, ModelContext(container))
    }

    // MARK: Values made up at random, the same ones every run

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
        mutating func uuid() -> UUID { UUID(uuid: (
            UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255),
            UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255),
            UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255),
            UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255), UInt8(next() & 255))) }
        mutating func date() -> Date { Date(timeIntervalSince1970: Double(1_000 + next() % 6)) } // few, so ties happen
    }

    private func visit(_ g: inout Generator) -> VisitValue {
        VisitValue(
            id: g.next() % 9 == 0 ? nil : g.uuid(), nodeID: "artist:x", kindRaw: g.pick(["artist", "label"]),
            title: g.pick(["A", "B", "C"]), subtitle: g.pick([nil, "s", "t"]),
            visits: Int(g.next() % 7), firstVisitedAt: g.date(), lastVisitedAt: g.date(),
            mbid: g.pick([nil, "m1", "m2"]), discogsID: g.pick([nil, 1, 2]),
            providerID: g.pick([nil, "p", "q"]),
            handle: g.pick([nil, "h"]))
    }

    private func step(_ g: inout Generator) -> StepValue {
        StepValue(id: g.next() % 9 == 0 ? nil : g.uuid(), identity: "a→b", fromNodeID: "a", toNodeID: "b",
                  count: Int(g.next() % 7), lastAt: g.date())
    }

    private func crate(_ g: inout Generator) -> CrateValue {
        CrateValue(
            id: g.uuid(), addedAt: g.date(), providerID: "nts", showID: "nts.episode.a/b",
            showTitle: g.pick([nil, "", "Show", "Other"]), artworkURLString: g.pick([nil, "", "https://a", "https://b"]),
            playbackURLString: g.pick([nil, "https://p"]), embedProviderRaw: g.pick([nil, "mixcloud"]),
            genreTagsRaw: g.pick(["", "ambient", "techno\nhouse"]), isLiveStream: g.next() % 2 == 0)
    }

    /// Copies of one event: one id, fields that may disagree.
    private func eventCopy(_ g: inout Generator) -> EventValue {
        EventValue(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!, at: g.date(),
            actionRaw: g.pick(["played", "skipped"]), nodeID: g.pick(["artist:a", "artist:b"]),
            nodeKindRaw: "artist", nodeKey: g.pick(["a", "b"]), title: g.pick(["A", "B", ""]),
            subtitle: g.pick([nil, "s"]), mbid: g.pick([nil, "m1", "m2"]), discogsID: g.pick([nil, 1, 2]),
            providerID: g.pick([nil, "p"]),
            sourceShowID: g.pick([nil, "x"]), seconds: Double(g.next() % 5), completion: Double(g.next() % 3) / 2,
            tags: g.pick([[], ["a"], ["a", "b"]]))
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[T]] in
            var rest = values
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    // MARK: Properties

    private func check<V: Equatable>(
        _ make: (inout Generator) -> V, _ merge: ([V]) -> V?, file: StaticString = #filePath, line: UInt = #line
    ) {
        var g = Generator(state: 20_261_001)
        for _ in 0..<300 {
            let rows = (0..<3).map { _ in make(&g) }
            let reference = merge(rows)

            // Any order of the rows gives the same result.
            for ordering in permutations(rows) {
                XCTAssertEqual(merge(ordering), reference, "order", file: file, line: line)
            }
            // Any grouping gives the same result: (A B) C == A (B C) == (A C) B.
            let ab = merge([rows[0], rows[1]])!
            let bc = merge([rows[1], rows[2]])!
            let ac = merge([rows[0], rows[2]])!
            XCTAssertEqual(merge([ab, rows[2]]), reference, "(A B) C", file: file, line: line)
            XCTAssertEqual(merge([rows[0], bc]), reference, "A (B C)", file: file, line: line)
            XCTAssertEqual(merge([ac, rows[1]]), reference, "(A C) B", file: file, line: line)
            // A merged result, merged on its own, is itself.
            XCTAssertEqual(merge([reference!]), reference, "alone", file: file, line: line)
        }
    }

    func testMergingVisitsIsIndependentOfOrderAndGrouping() { check(visit, VisitValue.merged) }
    func testMergingStepsIsIndependentOfOrderAndGrouping() { check(step, StepValue.merged) }
    func testMergingCrateRowsIsIndependentOfOrderAndGrouping() { check(crate, CrateValue.merged) }
    func testMergingCopiesOfOneEventIsIndependentOfOrderAndGrouping() { check(eventCopy, EventValue.merged) }

    func testIdenticalCopiesOfAnEventAreThatEvent() {
        let event = EventValue(
            id: UUID(), at: Date(timeIntervalSince1970: 5), actionRaw: "played", nodeID: "artist:a",
            nodeKey: "a", title: "A", seconds: 90, completion: 0.5, tags: ["ambient"])
        XCTAssertEqual(EventValue.merged([event, event, event]), event, "a copy is not counted twice")
    }

    // MARK: What a merge holds

    func testAVisitMergeSumsSpansAndKeepsTheLatestDescription() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let a = VisitValue(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, nodeID: "artist:x",
                           title: "Old", visits: 3, firstVisitedAt: early, lastVisitedAt: early, mbid: "m")
        let b = VisitValue(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, nodeID: "artist:x",
                           title: "New", visits: 4, firstVisitedAt: late, lastVisitedAt: late)

        let merged = VisitValue.merged([a, b])!

        XCTAssertEqual(merged.visits, 7)
        XCTAssertEqual(merged.firstVisitedAt, early)
        XCTAssertEqual(merged.lastVisitedAt, late)
        XCTAssertEqual(merged.title, "New", "described by the row seen last")
        XCTAssertEqual(merged.mbid, "m", "an identifier only one row had is kept")
        XCTAssertEqual(merged.id, b.id, "the lowest id stays; no id is made")
    }

    func testACrateMergeKeepsTheEarliestRowAndFillsWhatItLacked() {
        let first = CrateValue(id: UUID(), addedAt: Date(timeIntervalSince1970: 1), providerID: "nts",
                               showID: "s", showTitle: "Show")
        let second = CrateValue(id: UUID(), addedAt: Date(timeIntervalSince1970: 2), providerID: "nts",
                                showID: "s", showTitle: "Show", artworkURLString: "https://art",
                                playbackURLString: "https://play", genreTagsRaw: "ambient")

        let merged = CrateValue.merged([second, first])!

        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.showTitle, "Show")
        XCTAssertEqual(merged.artworkURLString, "https://art")
        XCTAssertEqual(merged.playbackURLString, "https://play")
        XCTAssertEqual(merged.genreTagsRaw, "ambient")
        XCTAssertEqual(merged.addedAt, first.addedAt)
    }

    func testTheCounterRuleIsASumAndLivesInOnePlace() {
        XCTAssertEqual(CounterPolicy.combine([3, 4, 0]), 7)
    }

    // MARK: A store

    private func broadcast(_ context: ModelContext, show: String, added: TimeInterval,
                           artwork: String? = nil, genres: [String] = []) -> CrateItem {
        let item = CrateItem(
            providerID: "nts", showID: show, showTitle: "Show", showSubtitle: nil,
            artworkURL: artwork.flatMap(URL.init(string:)), playbackURL: nil, embedProvider: nil,
            isLiveStream: false, genres: genres)
        item.addedAt = Date(timeIntervalSince1970: added)
        context.insert(item)
        return item
    }

    func testTwoCrateRowsForOneShowBecomeOneKeepingTheEarliestAndItsId() throws {
        let (_, context) = try open()
        let late = broadcast(context, show: "nts.episode.a/b", added: 200, artwork: "https://art", genres: ["ambient"])
        let early = broadcast(context, show: "nts.episode.a/b", added: 100)
        _ = broadcast(context, show: "nts.episode.c/d", added: 150)
        try context.save()
        let keptID = early.id

        let report = UserDataDedupe(context: context).all()

        XCTAssertEqual(report.crateMerged, 1)
        let rows = try context.fetch(FetchDescriptor<CrateItem>())
        XCTAssertEqual(rows.count, 2)
        let survivor = try XCTUnwrap(rows.first { $0.showID == "nts.episode.a/b" })
        XCTAssertEqual(survivor.id, keptID)
        XCTAssertEqual(survivor.artworkURLString, "https://art")
        XCTAssertEqual(survivor.genreTags, ["ambient"])
        XCTAssertTrue(UserDataDedupe(context: context).all().isEmpty, "a second pass changes nothing")
        _ = late
    }

    func testALookupFindsTheRowAMergeWouldKeepBeforeOneRuns() throws {
        for insertEarliestFirst in [true, false] {
            let (_, context) = try open("order-\(insertEarliestFirst).store")
            let rows = insertEarliestFirst
                ? [broadcast(context, show: "s", added: 100), broadcast(context, show: "s", added: 200)]
                : [broadcast(context, show: "s", added: 200), broadcast(context, show: "s", added: 100)]
            try context.save()
            let crate = CrateService(context: context)

            XCTAssertEqual(crate.item(forBroadcast: "s", providerID: "nts")?.addedAt,
                           Date(timeIntervalSince1970: 100))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 2, "reading merges nothing")
            _ = rows
        }
    }

    func testRemovingFromTheCrateRemovesEveryCopy() throws {
        let (_, context) = try open()
        _ = broadcast(context, show: "s", added: 100)
        let other = broadcast(context, show: "s", added: 200)
        _ = broadcast(context, show: "t", added: 300)
        try context.save()
        let crate = CrateService(context: context)

        crate.remove(other)

        XCTAssertNil(crate.item(forBroadcast: "s", providerID: "nts"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 1)
    }

    func testARepairThatMovesAShowOntoOneAlreadyKeptMergesThem() throws {
        let (_, context) = try open()
        _ = broadcast(context, show: "nts.episode.moxie/ep1", added: 100)
        let live = broadcast(context, show: "nts.1", added: 200, artwork: "https://art")
        live.isLiveStream = true
        try context.save()
        let crate = CrateService(context: context)

        crate.migrateLegacyNTSBroadcast(live, ref: NTSEpisodeRef(show: "moxie", episode: "ep1"), media: nil)

        let rows = try context.fetch(FetchDescriptor<CrateItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.showID, "nts.episode.moxie/ep1")
        XCTAssertEqual(rows.first?.artworkURLString, "https://art", "what the repaired copy had is kept")
    }

    // MARK: Ids

    func testRowsFromBeforeIdsExistedGetOneOnceAndKeepIt() throws {
        let url = directory.appendingPathComponent("v3.store")
        let v3 = Schema(IndigoSchemaV3.models)
        try autoreleasepool {
            let container = try ModelContainer(for: v3, configurations: ModelConfiguration(schema: v3, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(IndigoSchemaV3.DigVisit(kind: "artist", key: "a", title: "A", visits: 2))
            context.insert(IndigoSchemaV3.DigVisit(kind: "artist", key: "b", title: "B", visits: 1))
            context.insert(IndigoSchemaV3.DigStep(from: "artist:a", to: "artist:b", count: 3))
            try context.save()
        }
        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DigVisit>()).allSatisfy { $0.id == nil })

        XCTAssertEqual(UserDataDedupe(context: context).assignIDs(), 3)

        let ids = try context.fetch(FetchDescriptor<DigVisit>()).compactMap(\.id)
            + (try context.fetch(FetchDescriptor<DigStep>()).compactMap(\.id))
        XCTAssertEqual(Set(ids).count, 3, "each its own")
        XCTAssertEqual(UserDataDedupe(context: context).assignIDs(), 0, "once")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).compactMap(\.id).sorted { $0.uuidString < $1.uuidString },
                       ids.filter { id in try! context.fetch(FetchDescriptor<DigVisit>()).contains { $0.id == id } }
                           .sorted { $0.uuidString < $1.uuidString })
    }

    func testNewRowsAreBornWithAnId() {
        XCTAssertNotNil(DigVisit(node: .artist("Skee Mask")).id)
        XCTAssertNotNil(DigStep(from: "a", to: "b").id)
    }

    // MARK: Visits and steps, now that nothing refuses a second row

    private func visitRow(_ context: ModelContext, _ node: MusicNode, visits: Int, last: TimeInterval, id: String) -> DigVisit {
        let row = DigVisit(node: node)
        row.id = UUID(uuidString: id)
        row.visits = visits
        row.firstVisitedAt = Date(timeIntervalSince1970: last - 50)
        row.lastVisitedAt = Date(timeIntervalSince1970: last)
        context.insert(row)
        return row
    }

    func testTwoDevicesVisitsToOneNodeBecomeOneRowThatKeepsTheLowestId() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        _ = visitRow(context, node, visits: 3, last: 200, id: "00000000-0000-0000-0000-00000000000B")
        _ = visitRow(context, node, visits: 4, last: 300, id: "00000000-0000-0000-0000-00000000000A")
        _ = visitRow(context, .artist("Actress"), visits: 1, last: 100, id: "00000000-0000-0000-0000-00000000000C")
        try context.save()

        let report = UserDataDedupe(context: context).all()

        XCTAssertEqual(report.visitsMerged, 1)
        let rows = try context.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == "artist:skee mask" }))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.visits, 7)
        XCTAssertEqual(rows.first?.id, UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        XCTAssertTrue(UserDataDedupe(context: context).all().isEmpty)
    }

    func testStepsForOnePathAreSummed() throws {
        let (_, context) = try open()
        for (count, id) in [(2, "00000000-0000-0000-0000-000000000002"), (5, "00000000-0000-0000-0000-000000000001")] {
            let step = DigStep(from: "artist:a", to: "artist:b")
            step.id = UUID(uuidString: id); step.count = count
            context.insert(step)
        }
        try context.save()

        XCTAssertEqual(UserDataDedupe(context: context).all().stepsMerged, 1)
        let rows = try context.fetch(FetchDescriptor<DigStep>())
        XCTAssertEqual(rows.map(\.count), [7])
        XCTAssertEqual(rows.first?.id, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    func testARowWithNoIdIsGivenOneBeforeItIsComparedNotAfter() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        let withID = visitRow(context, node, visits: 1, last: 100, id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        let without = DigVisit(node: node)
        without.id = nil
        without.visits = 1
        context.insert(without)
        try context.save()

        UserDataDedupe(context: context).all()

        let rows = try context.fetch(FetchDescriptor<DigVisit>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows.first?.id)
        XCTAssertEqual(rows.first?.visits, 2)
        _ = withID
    }

    func testOpeningANodeThatHasTwoRowsCountsOnTheOneThatStays() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        _ = visitRow(context, node, visits: 3, last: 200, id: "00000000-0000-0000-0000-00000000000B")
        _ = visitRow(context, node, visits: 4, last: 300, id: "00000000-0000-0000-0000-00000000000A")
        let a = MusicNode.artist("Actress")
        for (count, id) in [(1, "00000000-0000-0000-0000-000000000002"), (2, "00000000-0000-0000-0000-000000000001")] {
            let step = DigStep(from: a.id, to: node.id)
            step.id = UUID(uuidString: id); step.count = count
            context.insert(step)
        }
        try context.save()

        DigHistory(context: context, writable: true).record(node, from: a)

        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        XCTAssertEqual(visits.map(\.visits), [8], "3 + 4, and this one")
        let steps = try context.fetch(FetchDescriptor<DigStep>())
        XCTAssertEqual(steps.map(\.count), [4], "1 + 2, and this one")
    }

    func testALookupBeforeAMergeAnswersWithTheRowTheMergeKeeps() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        _ = visitRow(context, node, visits: 3, last: 200, id: "00000000-0000-0000-0000-00000000000B")
        _ = visitRow(context, node, visits: 4, last: 300, id: "00000000-0000-0000-0000-00000000000A")
        try context.save()

        XCTAssertEqual(DigHistory(context: context).visit(for: node)?.id,
                       UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigVisit>()), 2, "reading merges nothing")
    }

    func testAListOfRecentVisitsHasOneRowPerNode() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        _ = visitRow(context, node, visits: 3, last: 200, id: "00000000-0000-0000-0000-00000000000B")
        _ = visitRow(context, node, visits: 4, last: 300, id: "00000000-0000-0000-0000-00000000000A")
        _ = visitRow(context, .artist("Actress"), visits: 1, last: 100, id: "00000000-0000-0000-0000-00000000000C")
        try context.save()

        let recent = DigHistory(context: context).recent(limit: 5)

        XCTAssertEqual(recent.map(\.nodeID), ["artist:skee mask", "artist:actress"])
    }

    // MARK: A row that arrives without its date

    func testARowWithNoDateNeverBeatsARowThatHasOne() {
        let real = CrateValue(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                              addedAt: Date(timeIntervalSince1970: 500), providerID: "nts", showID: "s",
                              showTitle: "Show")
        let undated = CrateValue(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 addedAt: .distantPast, providerID: "nts", showID: "s",
                                 artworkURLString: "https://art")

        for rows in [[real, undated], [undated, real]] {
            let merged = CrateValue.merged(rows)!
            XCTAssertEqual(merged.id, real.id, "the row with a date is the one kept")
            XCTAssertEqual(merged.addedAt, Date(timeIntervalSince1970: 500))
            XCTAssertEqual(merged.artworkURLString, "https://art", "and it still takes what the other had")
        }
        XCTAssertEqual(CrateValue.merged([undated])!.addedAt, .distantPast, "alone, it is still undated")
    }

    func testAnEmptyVisitIsNeutralToAMerge() {
        let real = VisitValue(id: UUID(), nodeID: "artist:x", title: "X", visits: 4,
                              firstVisitedAt: Date(timeIntervalSince1970: 10),
                              lastVisitedAt: Date(timeIntervalSince1970: 20))
        let empty = VisitValue(id: UUID(), nodeID: "artist:x", visits: 0,
                               firstVisitedAt: .distantFuture, lastVisitedAt: .distantPast)

        let merged = VisitValue.merged([real, empty])!

        XCTAssertEqual(merged.visits, 4)
        XCTAssertEqual(merged.firstVisitedAt, real.firstVisitedAt)
        XCTAssertEqual(merged.lastVisitedAt, real.lastVisitedAt)
        XCTAssertEqual(merged.title, "X")
    }

    func testARowThatArrivedWithNoVisitsIsNotSomewhereTheListenerWas() throws {
        let (_, context) = try open()
        let empty = DigVisit(node: .artist("Nowhere"))
        empty.visits = 0
        context.insert(empty)
        let real = DigVisit(node: .artist("Skee Mask"))
        real.visits = 2
        real.lastVisitedAt = Date(timeIntervalSince1970: 100)
        context.insert(real)
        try context.save()

        XCTAssertEqual(DigHistory(context: context).recent(limit: 5).map(\.nodeID), ["artist:skee mask"])
    }

    // MARK: An event is whole or it is not there

    func testCopiesOfAnEventResolveToOneOfTheCopiesNeverToAMixture() {
        let id = UUID()
        let a = EventValue(id: id, at: Date(timeIntervalSince1970: 5), nodeID: "artist:a", nodeKey: "a",
                           title: "x", seconds: 10, completion: 0.2, tags: ["t"])
        let b = EventValue(id: id, at: Date(timeIntervalSince1970: 5), nodeID: "artist:a", nodeKey: "a",
                           title: "a", seconds: 20, completion: 0.9, tags: ["u"])

        let merged = EventValue.merged([a, b])

        XCTAssertTrue(merged == a || merged == b, "an event that existed")
        XCTAssertEqual(EventValue.merged([b, a]), merged)
    }

    // MARK: Two physical rows with one id, once nothing refuses the second

    func testTwoCrateRowsWithOneIdAreTwoRowsUntilFolded() throws {
        let (_, context) = try open()
        let id = UUID()
        let enriched = broadcast(context, show: "nts.episode.a/b", added: 100, artwork: "https://art", genres: ["ambient"])
        let bare = broadcast(context, show: "nts.episode.a/b", added: 100)
        enriched.id = id
        bare.id = id
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 2, "nothing refuses the second")

        let report = UserDataDedupe(context: context).all()

        XCTAssertEqual(report.crateMerged, 1)
        let rows = try context.fetch(FetchDescriptor<CrateItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.artworkURLString, "https://art")
        XCTAssertEqual(rows.first?.genreTags, ["ambient"])
        XCTAssertTrue(UserDataDedupe(context: context).all().isEmpty)
    }

    func testTwoListeningEventsWithOneIdAreOneEventAndItsSecondsAreCountedOnce() throws {
        let (_, context) = try open()
        let id = UUID()
        let node = MusicNode.artist("Skee Mask")
        for _ in 0..<2 {
            let event = ListeningEvent(node: node, action: .played, seconds: 90)
            event.id = id
            context.insert(event)
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningEvent>()), 2)

        let report = UserDataDedupe(context: context).all()

        XCTAssertEqual(report.eventsMerged, 1)
        let rows = try context.fetch(FetchDescriptor<ListeningEvent>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.seconds, 90, "heard once, not twice")
        XCTAssertTrue(UserDataDedupe(context: context).all().isEmpty)
    }

    func testListeningEventsWithDifferentIdsAreAlwaysDifferentEvents() throws {
        let (_, context) = try open()
        let node = MusicNode.artist("Skee Mask")
        let at = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<3 { context.insert(ListeningEvent(node: node, action: .played, at: at, seconds: 90)) }
        try context.save()

        XCTAssertTrue(UserDataDedupe(context: context).all().isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningEvent>()), 3,
                       "identical in every field, and still three listens")
    }
}
