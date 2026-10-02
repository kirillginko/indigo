//
//  DigCounterTests.swift
//  IndigoTests
//
//  Counts that two devices cannot lose. The case that failed against CloudKit:
//  one counter row, raised three times on each of two devices at once, settled
//  at 5 and not 8. Here two stores on disk stand in for the two devices, and a
//  delivery copies one's rows into the other the way an import does: by id,
//  overwriting what is there, in whatever order. Every order must end at 8.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class DigCounterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigCounterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The id is a contract

    func testCounterIDsArePinned() {
        XCTAssertEqual(CounterID.make(kind: .visit, key: "artist:skee mask", deviceID: "base").uuidString,
                       "B2A2B435-72AE-8A5C-BD69-1877B357D4FF")
        XCTAssertEqual(CounterID.make(kind: .step, key: "artist:a→artist:b",
                                      deviceID: "5F1C2D3E-0000-4000-8000-000000000001").uuidString,
                       "421FECC8-B3C4-80E9-899F-B9F5520B975B")
        XCTAssertEqual(CounterID.make(kind: .generation, key: "counters", deviceID: "base").uuidString,
                       "96F3AF30-E627-8818-87DB-D42CBE780DEA")
        XCTAssertEqual(CounterID.make(kind: .visit, key: "recording:boards of canada\u{1F}aquarius",
                                      deviceID: "device-A").uuidString,
                       "827586D4-BF77-81E0-B90C-AE65EC70E438")
    }

    func testTheSeparatorKeepsKeysFromRunningTogether() {
        XCTAssertNotEqual(CounterID.make(kind: .visit, key: "artist:ab", deviceID: "c"),
                          CounterID.make(kind: .visit, key: "artist:a", deviceID: "bc"))
    }

    // MARK: - The rules, without a store

    func testCopiesTakeTheLargestAndDevicesAdd() {
        let t = Date(timeIntervalSince1970: 1_000)
        let rows = [
            CounterValue(deviceID: "base", count: 2, firstAt: t, lastAt: t),
            CounterValue(deviceID: "A", count: 3, firstAt: t.addingTimeInterval(5), lastAt: t.addingTimeInterval(9)),
            CounterValue(deviceID: "A", count: 2, firstAt: t.addingTimeInterval(5), lastAt: t.addingTimeInterval(7)),
            CounterValue(deviceID: "B", count: 3, firstAt: t.addingTimeInterval(1), lastAt: t.addingTimeInterval(8))
        ]
        let total = CounterValue.total(rows)!
        XCTAssertEqual(total.count, 8)
        XCTAssertEqual(total.firstAt, t)
        XCTAssertEqual(total.lastAt, t.addingTimeInterval(9))
    }

    /// Any order, any grouping, any repetition: one answer.
    func testTheTotalDoesNotDependOnOrderGroupingOrRepetition() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<300 {
            let devices = ["base", "A", "B", "C"]
            let rows = (0..<Int.random(in: 1...12, using: &rng)).map { _ in
                CounterValue(deviceID: devices.randomElement(using: &rng)!, count: Int.random(in: 0...20, using: &rng),
                             firstAt: Date(timeIntervalSince1970: Double(Int.random(in: 0...100, using: &rng))),
                             lastAt: Date(timeIntervalSince1970: Double(Int.random(in: 100...200, using: &rng))))
            }
            let expected = CounterValue.total(rows)!
            let shuffled = rows.shuffled(using: &rng)
            XCTAssertEqual(CounterValue.total(shuffled)!.count, expected.count)
            // Repeating every row changes nothing: a repeat is a copy.
            XCTAssertEqual(CounterValue.total(rows + shuffled)!.count, expected.count)
            // Merging in two halves first, then together.
            let cut = Int.random(in: 0...shuffled.count, using: &rng)
            let left = Dictionary(grouping: shuffled[..<cut], by: \.deviceID).values.compactMap { CounterValue.mergedCopies(Array($0)) }
            let right = Dictionary(grouping: shuffled[cut...], by: \.deviceID).values.compactMap { CounterValue.mergedCopies(Array($0)) }
            XCTAssertEqual(CounterValue.total(left + right)!.count, expected.count)
            XCTAssertEqual(CounterValue.total(left + right)!.lastAt, expected.lastAt)
        }
    }

    // MARK: - Two devices

    /// A device: a store on disk, a context for its own writes, one for what
    /// arrives from elsewhere, and the observer that folds the arrivals in.
    @MainActor
    private final class Device {
        let name: String
        let container: ModelContainer
        let local: ModelContext
        let remote: ModelContext
        let defaults: UserDefaults

        init(_ name: String, in directory: URL) throws {
            self.name = name
            container = try Persistence.makeSplitContainer(
                userData: directory.appendingPathComponent("\(name)-UserData.store"), local: nil)
            local = ModelContext(container); local.author = "local"
            remote = ModelContext(container); remote.author = "import"
            defaults = UserDefaults(suiteName: "DigCounterTests-\(name)-\(UUID().uuidString)")!
        }

        var dig: DigHistory { DigHistory(context: local, writable: true, deviceID: name) }

        @discardableResult
        func observe() -> UserDataDedupe.Report {
            HistoryObserver(context: local, defaults: defaults, ownAuthor: "local").process()
        }

        func visits(_ node: MusicNode) -> [DigVisit] {
            let id = node.id
            return (try? local.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == id }))) ?? []
        }
    }

    private enum Part { case counters, parents }

    /// Copies `parts` of what `from` holds into `to`, by id, overwriting --
    /// what an import does -- and lets `to`'s observer look.
    private func deliver(_ parts: [Part], from: Device, to: Device) throws {
        for part in parts {
            switch part {
            case .counters:
                for row in try from.local.fetch(FetchDescriptor<DigCounter>()) {
                    let id = row.id
                    if let there = try to.remote.fetch(FetchDescriptor<DigCounter>(predicate: #Predicate { $0.id == id })).first {
                        there.count = row.count; there.firstAt = row.firstAt; there.lastAt = row.lastAt
                    } else {
                        let copy = DigCounter(kind: row.kind!, key: row.key, deviceID: row.deviceID)
                        copy.count = row.count; copy.firstAt = row.firstAt; copy.lastAt = row.lastAt
                        to.remote.insert(copy)
                    }
                }
            case .parents:
                for row in try from.local.fetch(FetchDescriptor<DigVisit>()) {
                    let value = VisitValue(row), id = row.id
                    if let there = try to.remote.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.id == id })).first {
                        value.apply(to: there)
                    } else {
                        to.remote.insert(DigVisit(restoring: value))
                    }
                }
                for row in try from.local.fetch(FetchDescriptor<DigStep>()) {
                    let value = StepValue(row), id = row.id
                    if let there = try to.remote.fetch(FetchDescriptor<DigStep>(predicate: #Predicate { $0.id == id })).first {
                        value.apply(to: there)
                    } else {
                        to.remote.insert(DigStep(restoring: value))
                    }
                }
            }
            try to.remote.save()
            to.observe()
            to.observe()   // and again: a second look must change nothing
        }
    }

    private func settled(_ a: Device, _ b: Device, _ node: MusicNode, _ origin: MusicNode) throws -> (Int, Int) {
        let visitA = try XCTUnwrap(a.visits(node).first), visitB = try XCTUnwrap(b.visits(node).first)
        XCTAssertEqual(a.visits(node).count, 1); XCTAssertEqual(b.visits(node).count, 1)
        XCTAssertEqual(UserDataInvariants.violations(in: a.local), [])
        XCTAssertEqual(UserDataInvariants.violations(in: b.local), [])
        let stepA = try XCTUnwrap(a.dig.steps().first { $0.toNodeID == node.id })
        let stepB = try XCTUnwrap(b.dig.steps().first { $0.toNodeID == node.id })
        XCTAssertEqual(stepA.count, stepB.count)
        XCTAssertEqual(visitA.lastVisitedAt, visitB.lastVisitedAt)
        return (visitA.visits, visitB.visits)
    }

    /// Both start from one synced counter at 2, raise it 3 times each, then
    /// learn of each other -- A sees the components before the row, B the row
    /// before the components -- and both say 8.
    func testThreeAndThreeIsEightWhicheverArrivesFirst() throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        let node = MusicNode.artist("Skee Mask"), origin = MusicNode.artist("Objekt")
        a.dig.record(node, from: origin); a.dig.record(node, from: origin)
        try deliver([.counters, .parents], from: a, to: b)
        XCTAssertEqual(b.visits(node).first?.visits, 2)

        for _ in 0..<3 { a.dig.record(node, from: origin); b.dig.record(node, from: origin) }

        try deliver([.counters, .parents], from: a, to: b)
        try deliver([.parents, .counters], from: b, to: a)
        // And everything once more, the other way round, as late copies would.
        try deliver([.parents, .counters], from: a, to: b)
        try deliver([.counters, .parents], from: b, to: a)

        let (onA, onB) = try settled(a, b, node, origin)
        XCTAssertEqual(onA, 8)
        XCTAssertEqual(onB, 8)
        XCTAssertEqual(a.dig.steps().first { $0.toNodeID == node.id }?.count, 8)
    }

    /// A parent row that arrives last, carrying the other device's older
    /// projection, is put right again rather than believed.
    func testALateParentDoesNotUndoTheComponents() throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        let node = MusicNode.artist("Actress"), origin = MusicNode.artist("Burial")
        a.dig.record(node, from: origin)
        try deliver([.counters, .parents], from: a, to: b)
        for _ in 0..<3 { b.dig.record(node, from: origin) }
        try deliver([.counters], from: b, to: a)
        XCTAssertEqual(a.visits(node).first?.visits, 4)
        // A's stale row (it said 1 before it heard from B) reaches B last.
        let stale = VisitValue(a.visits(node).first!)
        var older = stale; older.visits = 1
        older.apply(to: try XCTUnwrap(b.remote.fetch(FetchDescriptor<DigVisit>()).first { $0.nodeID == node.id }))
        try b.remote.save()
        b.observe()
        XCTAssertEqual(b.visits(node).first?.visits, 4)
    }

    /// Both devices open something neither had: two rows for one node, each
    /// with its own component. One row, counting both.
    func testANewKeyOnBothDevicesIsOneRowCountingBoth() throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        let node = MusicNode.label("Ilian Tape"), origin = MusicNode.artist("Skee Mask")
        a.dig.record(node, from: origin)
        b.dig.record(node, from: origin)
        try deliver([.parents, .counters], from: a, to: b)
        try deliver([.counters, .parents], from: b, to: a)
        try deliver([.counters, .parents], from: a, to: b)
        let (onA, onB) = try settled(a, b, node, origin)
        XCTAssertEqual(onA, 2)
        XCTAssertEqual(onB, 2)
    }

    // MARK: - Moving a store's counts into components

    private func v6Store(_ layout: StoreLayout, _ fill: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: IndigoSchemaV6.self)
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration("UserData", schema: Schema(IndigoSchemaV6.userDataModels), url: layout.userData, cloudKitDatabase: .none),
                ModelConfiguration("Local", schema: Schema(IndigoSchemaV6.localModels), url: layout.local, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            try fill(context)
            try context.save()
        }
    }

    private func legacyVisit(_ context: ModelContext, _ node: MusicNode, visits: Int, last: TimeInterval) {
        let visit = DigVisit(node: node)
        visit.visits = visits
        visit.firstVisitedAt = Date(timeIntervalSince1970: 10)
        visit.lastVisitedAt = Date(timeIntervalSince1970: last)
        context.insert(visit)
    }

    func testAStoreFromBeforeComponentsKeepsEveryCountExactly() throws {
        let layout = StoreLayout(directory: directory)
        try v6Store(layout) { context in
            legacyVisit(context, .artist("Skee Mask"), visits: 64, last: 500)
            legacyVisit(context, .artist("Objekt"), visits: 3, last: 400)
            // Two rows for one node, from before merging: they add, as they did.
            legacyVisit(context, .artist("Actress"), visits: 2, last: 300)
            legacyVisit(context, .artist("Actress"), visits: 5, last: 350)
            let step = DigStep(from: "artist:objekt", to: "artist:skee mask")
            step.count = 12; step.lastAt = Date(timeIntervalSince1970: 450)
            context.insert(step)
        }
        XCTAssertTrue(CounterBaseline.needsBaseline(store: layout.userData))

        let context = ModelContext(try Persistence.openSplitStores(layout: layout))
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        XCTAssertEqual(visits.count, 3)
        XCTAssertEqual(visits.map(\.visits).reduce(0, +), 64 + 3 + 7)
        XCTAssertEqual(visits.first { $0.nodeID == "artist:actress" }?.visits, 7)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigStep>()).first?.count, 12)
        let counters = try context.fetch(FetchDescriptor<DigCounter>())
        XCTAssertEqual(counters.filter { $0.kind == .visit }.count, 3)
        XCTAssertEqual(counters.filter { $0.kind == .step }.count, 1)
        XCTAssertEqual(counters.filter { $0.kind == .generation }.first?.count, 7)
        XCTAssertTrue(counters.filter { $0.kind != .generation }.allSatisfy { $0.deviceID == CounterID.base })
        XCTAssertEqual(UserDataInvariants.violations(in: context), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: CounterBaseline.marker(in: layout).path))

        // A record afterwards adds to the base, not replaces it.
        DigHistory(context: context, writable: true, deviceID: "this-mac").record(.artist("Skee Mask"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first { $0.nodeID == "artist:skee mask" }?.visits, 65)
    }

    func testOpeningAgainOrFinishingAnInterruptedMoveChangesNothing() throws {
        let layout = StoreLayout(directory: directory)
        try v6Store(layout) { context in legacyVisit(context, .artist("Skee Mask"), visits: 9, last: 500) }
        func snapshot() throws -> [String] {
            let context = ModelContext(try Persistence.openSplitStores(layout: layout))
            return try context.fetch(FetchDescriptor<DigCounter>()).map { "\($0.kindRaw)/\($0.deviceID)/\($0.count)" }.sorted()
        }
        let first = try snapshot()
        // As if the launch had died after migrating and before clearing the debt.
        FileManager.default.createFile(atPath: CounterBaseline.marker(in: layout).path, contents: Data())
        XCTAssertEqual(try snapshot(), first)
        XCTAssertEqual(try snapshot(), first)
        XCTAssertFalse(CounterBaseline.needsBaseline(store: layout.userData))
    }

    /// A new device's store is born with components. Rows it imports already
    /// carry projections; turning them into a base would count them twice.
    func testAStoreBornWithComponentsIsNeverGivenABase() throws {
        let layout = StoreLayout(directory: directory)
        do {
            let context = ModelContext(try Persistence.openSplitStores(layout: layout))
            let imported = DigVisit(node: .artist("Skee Mask"))
            imported.visits = 40
            context.insert(imported)
            try context.save()
        }
        XCTAssertFalse(CounterBaseline.needsBaseline(store: layout.userData))
        let context = ModelContext(try Persistence.openSplitStores(layout: layout))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigCounter>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.visits, 40)
    }

    // MARK: - What does not touch them

    func testRebuildingLocalLeavesTheCountsAlone() throws {
        let layout = StoreLayout(directory: directory)
        do {
            let context = ModelContext(try Persistence.openSplitStores(layout: layout))
            for _ in 0..<4 { DigHistory(context: context, writable: true, deviceID: "mac").record(.artist("Objekt"), from: .artist("Skee Mask")) }
        }
        for file in layout.files(of: layout.local) { try? FileManager.default.removeItem(at: file) }
        let context = ModelContext(try Persistence.openSplitStores(layout: layout))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first { $0.nodeID == "artist:objekt" }?.visits, 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigCounter>()), 2)
        XCTAssertEqual(UserDataInvariants.violations(in: context), [])
    }

    func testForgettingTakesTheComponentsWithIt() throws {
        let a = try Device("A", in: directory)
        a.dig.record(.artist("Objekt"), from: .artist("Skee Mask"))
        a.dig.forget()
        XCTAssertEqual(try a.local.fetchCount(FetchDescriptor<DigCounter>()), 0)
        a.dig.record(.artist("Objekt"))
        XCTAssertEqual(a.visits(.artist("Objekt")).first?.visits, 1)
    }
}

/// A repeatable random source, so a failure can be run again.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
