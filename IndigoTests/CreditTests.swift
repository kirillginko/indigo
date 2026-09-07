//
//  CreditTests.swift
//  IndigoTests
//
//  Phase 3. A record is not only its headline artist. Following a producer or
//  an engineer out of a sleeve is a route no "similar artists" list can offer,
//  because it is a fact somebody typed off the back of the record rather than
//  a resemblance.
//
//  The decision pinned hardest here is which credits are musical at all.
//  Discogs lists the photographer beside the producer, and an artist first met
//  through a shared sleeve designer is the moment DIG stops being about music.
//

import XCTest
import SwiftData
@testable import Indigo

final class CreditTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: What counts as a musical credit

    func testSleeveCreditsAreNotMusicalConnections() {
        for role in ["Design", "Artwork By", "Photography By", "Layout",
                     "Sleeve Notes", "Liner Notes", "Illustration",
                     "Lacquer Cut By", "Distributed By", "Management"] {
            XCTAssertFalse(CreditRole.isMusical(role), role)
        }
    }

    func testTheJobsThatMadeTheMusicAreKept() {
        XCTAssertEqual(CreditRole.kind(of: "Producer"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Co-producer"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Mixed By"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Remix"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Written-By"), .writing)
        XCTAssertEqual(CreditRole.kind(of: "Composed By"), .writing)
        XCTAssertEqual(CreditRole.kind(of: "Mastered By"), .engineering)
        XCTAssertEqual(CreditRole.kind(of: "Engineer"), .engineering)
        // Anything played or sung, without enumerating every instrument
        // Discogs has ever recorded.
        XCTAssertEqual(CreditRole.kind(of: "Bass"), .performance)
        XCTAssertEqual(CreditRole.kind(of: "Soprano Saxophone"), .performance)
        XCTAssertEqual(CreditRole.kind(of: "Vocals"), .performance)
    }

    func testAProducerWhoAlsoTookThePhotographIsStillAProducer() {
        XCTAssertEqual(CreditRole.kind(of: "Producer, Photography By"), .production)
        XCTAssertEqual(CreditRole.kind(of: "Design, Written-By"), .writing)
    }

    func testACreditWithNoJobIsNotOne() {
        XCTAssertNil(CreditRole.kind(of: nil))
        XCTAssertNil(CreditRole.kind(of: ""))
        XCTAssertNil(CreditRole.kind(of: "   "))
        XCTAssertNil(CreditRole.kind(of: "Design"))
    }

    // MARK: Grouping for the page

    private func record(
        id: Int = 1, title: String = "Vernal Equinox",
        artists: [String] = ["Jon Hassell"],
        credits: [(name: String, role: String, tracks: String)]
    ) -> DiscogsReleaseRecord {
        let record = DiscogsReleaseRecord(discogsID: id, title: title)
        record.artistNames = artists
        record.creditNames = credits.map(\.name)
        record.creditRoles = credits.map(\.role)
        record.creditTracks = credits.map(\.tracks)
        context.insert(record)
        return record
    }

    func testCreditsReadInTheOrderASleeveWouldPrintThem() {
        let record = record(credits: [
            ("Nana Vasconcelos", "Percussion", ""),
            ("Brian Eno", "Producer", ""),
            ("Jon Hassell", "Written-By", "")
        ])
        let groups = DigEngine.creditGroups(from: record)

        XCTAssertEqual(groups.map(\.kind), [.production, .writing, .performance])
        XCTAssertEqual(groups.first?.people.first?.name, "Brian Eno")
        XCTAssertEqual(groups.first?.title, "Produced by")
    }

    func testOnePersonCreditedTwoWaysGetsTwoLines() {
        // "Producer, Bass" is what the record says; joining them would be
        // Indigo's summary of it rather than the record's own words.
        let record = record(credits: [
            ("Adrian Sherwood", "Producer", ""),
            ("Adrian Sherwood", "Bass", "")
        ])
        let groups = DigEngine.creditGroups(from: record)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap(\.people).count, 2)
    }

    func testTheExactSameCreditTwiceIsOneLine() {
        let record = record(credits: [
            ("Rashad Becker", "Mastered By", ""),
            ("Rashad Becker", "Mastered By", "")
        ])
        XCTAssertEqual(DigEngine.creditGroups(from: record).flatMap(\.people).count, 1)
    }

    func testALineSaysWhichTracksWhenItIsNotTheWholeRecord() {
        let record = record(credits: [("Jah Wobble", "Bass", "A1 to A4")])
        let person = DigEngine.creditGroups(from: record).first?.people.first
        XCTAssertEqual(person?.detail, "Bass · A1 to A4")

        let whole = self.record(id: 2, credits: [("Jah Wobble", "Bass", "")])
        XCTAssertEqual(DigEngine.creditGroups(from: whole).first?.people.first?.detail, "Bass")
    }

    // MARK: Edges

    func testASleeveBecomesSomewhereToGo() {
        record(credits: [
            ("Brian Eno", "Producer", ""),
            ("Nana Vasconcelos", "Percussion", ""),
            ("Some Photographer", "Photography By", "")
        ])
        try? context.save()

        let graph = GraphStore(context: context)
        let node = MusicNode.release("Vernal Equinox", discogsID: 1)
        let edges = graph.compute(node).all

        let producers = edges.filter { $0.kind == .producer }
        let personnel = edges.filter { $0.kind == .personnel }
        XCTAssertEqual(producers.map(\.to.title), ["Brian Eno"])
        XCTAssertEqual(personnel.map(\.to.title), ["Nana Vasconcelos"])
        // The photographer is not a musical connection and never became one.
        XCTAssertFalse(edges.contains { $0.to.title == "Some Photographer" })
    }

    func testTheEdgeSaysTheJobTheRecordSaid() {
        record(credits: [("Rashad Becker", "Mastered By", "")])
        try? context.save()

        let edges = GraphStore(context: context)
            .compute(.release("Vernal Equinox", discogsID: 1)).all
        let edge = edges.first { $0.to.title == "Rashad Becker" }
        // "Mastered By" says something the bucket name "Personnel" does not.
        XCTAssertEqual(edge?.reason, "Mastered By on Vernal Equinox")
    }

    func testTheHeadlineArtistIsNotOfferedAsSomebodyElseToMeet() {
        record(artists: ["Jon Hassell"], credits: [("Jon Hassell", "Producer", "")])
        try? context.save()

        let edges = GraphStore(context: context)
            .compute(.release("Vernal Equinox", discogsID: 1)).all
        // The page is already about him.
        XCTAssertFalse(edges.contains { $0.kind == .producer })
    }

    func testEveryCreditedNameIsSomewhereYouCanActuallyGo() {
        record(credits: [("Brian Eno", "Producer", "")])
        try? context.save()

        let edges = GraphStore(context: context)
            .compute(.release("Vernal Equinox", discogsID: 1)).all
        for edge in edges where edge.kind == .producer || edge.kind == .personnel {
            XCTAssertNotNil(edge.to.destination, edge.to.title)
        }
    }

    // MARK: No dead ends

    func testASceneIsSomewhereYouCanGo() {
        // It has had a page for a while. This was the one route to it that
        // did not know, so every scene the graph handed back was a row that
        // looked like a link and would not open.
        let scene = MusicNode.scene(city: "Berlin", sound: "Dub Techno")
        XCTAssertEqual(scene.destination, .digScene(city: "Berlin", sound: "Dub Techno"))
    }
}
