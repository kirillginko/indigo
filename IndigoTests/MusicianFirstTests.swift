//
//  MusicianFirstTests.swift
//  IndigoTests
//
//  What a credit is for, and that the switch changes nothing while it is off.
//

import XCTest
import SwiftData
@testable import Indigo

final class MusicianFirstTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        MusicianFirst.override = nil
        context = nil
        container = nil
    }

    // MARK: The taxonomy

    func testPlayersAndSingersArePerforming() {
        for role in ["Bass", "Double Bass", "Drums", "Piano", "Vocals", "Featuring", "Tenor Saxophone",
                     "Conductor", "Programmed By", "Synthesizer"] {
            XCTAssertEqual(CreditRole.contribution(of: role), .performing, role)
        }
    }

    func testMakingTheMusicIsCreativeAndAProducerIsNeverTechnical() {
        for role in ["Producer", "Co-producer", "Remix", "DJ Mix", "Written-By", "Composed By",
                     "Arranged By", "Lyrics By"] {
            XCTAssertEqual(CreditRole.contribution(of: role), .creative, role)
        }
    }

    func testWorkingTheEquipmentIsTechnical() {
        for role in ["Engineer", "Recorded By", "Mixed By", "Mastered By", "Remastered By", "Edited By",
                     "Engineer [Assistant]", "Executive-Producer", "Recording Supervisor",
                     "Art Direction, Graphic Design", "Video Director"] {
            XCTAssertEqual(CreditRole.contribution(of: role), .technical, role)
        }
    }

    func testTheStrongestJobWins() {
        XCTAssertEqual(CreditRole.contribution(of: "Bass, Engineer"), .performing)
        XCTAssertEqual(CreditRole.contribution(of: "Mixed By, Producer"), .creative)
        XCTAssertNil(CreditRole.contribution(of: "Design"))
        XCTAssertNil(CreditRole.contribution(of: nil))
    }

    func testTheOldSortingIsUntouched() {
        // The visible grouping on release pages reads `kind`, not this.
        XCTAssertEqual(CreditRole.kind(of: "Mixed By"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Mastered By"), .engineering)
    }

    // MARK: The switch

    private func release(_ credits: [(String, String)]) {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "Vernal Equinox")
        record.artistNames = ["Jon Hassell"]
        record.creditNames = credits.map(\.0)
        record.creditRoles = credits.map(\.1)
        record.creditTracks = credits.map { _ in "" }
        context.insert(record)
        try? context.save()
    }

    private let sleeve = [("Nana Vasconcelos", "Percussion"), ("Brian Eno", "Producer"),
                          ("Rashad Becker", "Mastered By"), ("Some Engineer", "Mixed By")]

    func testOffEveryMusicalCreditIsARouteAsBefore() {
        MusicianFirst.override = false
        release(sleeve)
        let titles = Set(GraphStore(context: context).compute(.release("Vernal Equinox", discogsID: 1)).all.map(\.to.title))
        XCTAssertTrue(titles.isSuperset(of: ["Nana Vasconcelos", "Brian Eno", "Rashad Becker", "Some Engineer"]))
    }

    func testOnEngineersStayOffTheRoutes() {
        MusicianFirst.override = true
        release(sleeve)
        let titles = Set(GraphStore(context: context).compute(.release("Vernal Equinox", discogsID: 1)).all.map(\.to.title))
        XCTAssertTrue(titles.isSuperset(of: ["Nana Vasconcelos", "Brian Eno"]))
        XCTAssertFalse(titles.contains("Rashad Becker"))
        XCTAssertFalse(titles.contains("Some Engineer"))
    }

    func testTurningTheSwitchNeverReadsTheOtherRulesStoredEdges() {
        release(sleeve)
        let node = MusicNode.release("Vernal Equinox", discogsID: 1)
        MusicianFirst.override = false
        XCTAssertTrue(GraphStore(context: context).neighbors(of: node).all.contains { $0.to.title == "Rashad Becker" })
        try? context.save()
        MusicianFirst.override = true
        XCTAssertFalse(GraphStore(context: context).neighbors(of: node).all.contains { $0.to.title == "Rashad Becker" },
                       "Stored under today's rules, worked out again under musician-first")
        try? context.save()
        MusicianFirst.override = false
        XCTAssertTrue(GraphStore(context: context).neighbors(of: node).all.contains { $0.to.title == "Rashad Becker" })
    }

    func testOnTheReleasePageStillListsEveryone() throws {
        MusicianFirst.override = true
        release(sleeve)
        let record = try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).first
        let names = Set(DigEngine.creditGroups(from: try XCTUnwrap(record)).flatMap(\.people).map(\.name))
        XCTAssertEqual(names, ["Nana Vasconcelos", "Brian Eno", "Rashad Becker", "Some Engineer"])
    }
}
