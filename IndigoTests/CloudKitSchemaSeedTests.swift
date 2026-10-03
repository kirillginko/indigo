//
//  CloudKitSchemaSeedTests.swift
//  IndigoTests
//
//  The seed has to fill every field, be unable to touch the listener's stores,
//  and make a difference in a string visible.
//

#if DEBUG
import XCTest
import SwiftData
@testable import Indigo

final class CloudKitSchemaSeedTests: XCTestCase {
    private let seed = CloudKitSchemaSeed.make()

    /// The names of a value's fields that hold something.
    private func filled<V>(_ value: V) -> Set<String> {
        var names = Set<String>()
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else { continue }
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .optional { if mirror.children.count > 0 { names.insert(label) } }
            else { names.insert(label) }
        }
        return names
    }

    private func optionalAttributes(_ entity: String) throws -> Set<String> {
        let found = try XCTUnwrap(Persistence.schema.entities.first { $0.name == entity })
        return Set(found.attributes.filter(\.isOptional).map(\.name))
    }

    // MARK: Every field

    func testEveryOptionalFieldOfEveryEntityIsFilledByAtLeastOneSeedRow() throws {
        let cases: [(String, Set<String>)] = [
            ("CrateItem", seed.crate.reduce(into: Set<String>()) { $0.formUnion(filled($1)) }),
            ("ListeningEvent", seed.events.reduce(into: Set<String>()) { $0.formUnion(filled($1)) }),
            ("DigVisit", seed.visits.reduce(into: Set<String>()) { $0.formUnion(filled($1)) }),
            ("DigStep", seed.steps.reduce(into: Set<String>()) { $0.formUnion(filled($1)) })
        ]
        for (entity, populated) in cases {
            let missing = try optionalAttributes(entity).subtracting(populated)
            XCTAssertTrue(missing.isEmpty, "\(entity): the seed leaves \(missing.sorted()) empty")
        }
    }

    func testEveryAttributeOfEveryEntityIsAFieldOfTheSeedsValues() throws {
        // A field added to a model without being added to the values the seed is
        // made of is a field the development schema would not get.
        func labels<V>(_ value: V) -> Set<String> { Set(Mirror(reflecting: value).children.compactMap(\.label)) }
        for (entity, names) in [("CrateItem", labels(seed.crate[0])), ("ListeningEvent", labels(seed.events[0])),
                                ("DigVisit", labels(seed.visits[0])), ("DigStep", labels(seed.steps[0]))] {
            let attributes = Set(try XCTUnwrap(Persistence.schema.entities.first { $0.name == entity }).attributes.map(\.name))
            XCTAssertTrue(attributes.isSubset(of: names), "\(entity): \(attributes.subtracting(names).sorted())")
        }
    }

    func testTheSeedHoldsTheOddCasesTheRealDataHas() {
        XCTAssertTrue(seed.crate.contains { $0.matchKey.unicodeScalars.contains("\u{1F}") }, "a match key with the unit separator")
        XCTAssertTrue(seed.crate.contains { $0.unknownCode != nil && $0.identificationStatusRaw == "probable" }, "a placeholder")
        XCTAssertTrue(seed.crate.contains { $0.kindRaw == "broadcast" })
        XCTAssertTrue(seed.events.allSatisfy { !$0.tags.isEmpty })
        XCTAssertEqual(Set(seed.crate.map(\.kindRaw)), ["recording", "broadcast", "artist"])
    }

    func testTheSeedIsConsistentWithItself() {
        for item in seed.crate { XCTAssertEqual(UserDataInvariants.problems(in: item), []) }
        for event in seed.events { XCTAssertEqual(UserDataInvariants.problems(in: event), []) }
        for visit in seed.visits { XCTAssertEqual(UserDataInvariants.problems(in: visit), []) }
        for step in seed.steps { XCTAssertEqual(UserDataInvariants.problems(in: step), []) }
    }

    func testEverySeedRowCanBeToldApartFromARealOne() {
        let seeded = Set(["crate-full", "crate-placeholder", "crate-show", "crate-artist", "event", "visit", "step"]
            .map(CloudKitSchemaSeed.id))
        XCTAssertTrue(seed.crate.allSatisfy { seeded.contains($0.id) })
        XCTAssertTrue(seed.events.allSatisfy { seeded.contains($0.id) })
        XCTAssertTrue(seed.visits.allSatisfy { seeded.contains($0.id ?? UUID()) })
        XCTAssertTrue(seed.steps.allSatisfy { seeded.contains($0.id ?? UUID()) })
        XCTAssertTrue(seed.crate.compactMap(\.title).allSatisfy { $0.contains(CloudKitSchemaSeed.marker) || $0 == "Unreleased" })
    }

    // MARK: The guard

    private let layout = StoreLayout(directory: URL(fileURLWithPath: "/tmp/indigo-seed-layout"))

    func testASeedRunIsRefusedUnlessAskedForByNameOnAStoreOfItsOwn() {
        let own = layout.directory.appendingPathComponent("CloudKitSchemaSeed.store")
        // A test process is itself a refusal; the rest are shown by what else is reported.
        XCTAssertTrue(CloudKitSeedGuard.refusals(arguments: [], store: own, layout: layout).contains("not asked for by name"))
        XCTAssertTrue(CloudKitSeedGuard.refusals(arguments: [CloudKitSeedGuard.argument], store: own, layout: layout)
            .allSatisfy { $0 == "this is a test process" })
    }

    func testASeedRunIsRefusedOnEveryFileOfTheListenersStores() {
        for base in [layout.userData, layout.local, layout.legacy, layout.archive] {
            for file in layout.files(of: base) {
                let reasons = CloudKitSeedGuard.refusals(arguments: [CloudKitSeedGuard.argument], store: file, layout: layout)
                XCTAssertTrue(reasons.contains { $0.contains("the listener's") }, file.lastPathComponent)
            }
        }
        let other = layout.directory.appendingPathComponent("Anything.store")
        XCTAssertTrue(CloudKitSeedGuard.refusals(arguments: [CloudKitSeedGuard.argument], store: other, layout: layout)
            .contains("the store is not named for the seed"))
    }

    // MARK: Did it come back whole

    func testAScalarThatChangedIsFoundAndTheSameStringIsNot() {
        let key = CloudKitSchemaSeed.separatedKey
        XCTAssertNil(UnicodeFidelity.firstDifference(sent: key, received: key))
        let stripped = key.replacingOccurrences(of: "\u{1F}", with: "")
        let diff = UnicodeFidelity.firstDifference(sent: key, received: stripped)
        XCTAssertEqual(diff?.sent, 0x1F)
    }

    func testCanonicallyEquivalentButDifferentScalarsAreNotTheSame() {
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift calls these equal")
        XCTAssertNotNil(UnicodeFidelity.firstDifference(sent: composed, received: decomposed), "a round trip must not")
    }

    func testTheSeedSurvivesALocalStoreRoundTripScalarForScalar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("CloudKitSchemaSeed.store")

        try autoreleasepool {
            let context = ModelContext(try Persistence.makeSplitContainer(userData: url, local: nil))
            for v in seed.crate { context.insert(CrateItem(restoring: v)) }
            for v in seed.events { context.insert(ListeningEvent(restoring: v)) }
            for v in seed.visits { context.insert(DigVisit(restoring: v)) }
            for v in seed.steps { context.insert(DigStep(restoring: v)) }
            try context.save()
        }
        let context = ModelContext(try Persistence.makeSplitContainer(userData: url, local: nil))
        let back = CloudKitSchemaSeed(
            crate: try context.fetch(FetchDescriptor<CrateItem>()).map(CrateValue.init),
            events: try context.fetch(FetchDescriptor<ListeningEvent>()).map(EventValue.init),
            visits: try context.fetch(FetchDescriptor<DigVisit>()).map(VisitValue.init),
            steps: try context.fetch(FetchDescriptor<DigStep>()).map(StepValue.init))

        XCTAssertEqual(UnicodeFidelity.differences(sent: seed, received: back), [])
        XCTAssertEqual(back.crate.count, seed.crate.count)
    }
}
#endif
