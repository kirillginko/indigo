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

    func testPlayersSingersAndWritersAreMusical() {
        for role in ["Bass", "Double Bass", "Drums", "Piano", "Vocals", "Featuring", "Tenor Saxophone",
                     "Conductor", "Synthesizer", "Written-By", "Composed By", "Arranged By", "Lyrics By"] {
            XCTAssertEqual(CreditRole.contribution(of: role), .musical, role)
        }
    }

    func testMakingTheRecordIsCreativeAndAProducerIsNeverTechnical() {
        for role in ["Producer", "Co-producer", "Remix", "DJ Mix", "Programmed By"] {
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
        XCTAssertEqual(CreditRole.contribution(of: "Bass, Engineer"), .musical)
        XCTAssertEqual(CreditRole.contribution(of: "Mixed By, Producer"), .creative)
        XCTAssertEqual(CreditRole.contribution(of: "Design"), .technical)
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

    private var node: MusicNode { .release("Vernal Equinox", discogsID: 1) }

    func testTheGraphIsTheSameWhateverDIGIsSetTo() {
        release(sleeve)
        MusicianFirst.override = false
        let off = Set(GraphStore(context: context).neighbors(of: node).all.map(\.id))
        try? context.save()
        MusicianFirst.override = true
        let on = Set(GraphStore(context: context).neighbors(of: node).all.map(\.id))
        XCTAssertEqual(off, on, "Musician-first is DIG's view, never a different graph")
        XCTAssertTrue(GraphStore(context: context).neighbors(of: node).all.contains { $0.to.title == "Rashad Becker" })
    }

    func testOffDIGShowsEveryMusicalCreditAsBefore() {
        MusicianFirst.override = false
        release(sleeve)
        let titles = Set(GraphStore(context: context).neighbors(of: node).forDIG.all.map(\.to.title))
        XCTAssertTrue(titles.isSuperset(of: ["Nana Vasconcelos", "Brian Eno", "Rashad Becker", "Some Engineer"]))
    }

    func testOnDIGLeavesEngineersOut() {
        MusicianFirst.override = true
        release(sleeve)
        let titles = Set(GraphStore(context: context).neighbors(of: node).forDIG.all.map(\.to.title))
        XCTAssertTrue(titles.isSuperset(of: ["Nana Vasconcelos", "Brian Eno"]))
        XCTAssertFalse(titles.contains("Rashad Becker"))
        XCTAssertFalse(titles.contains("Some Engineer"))
    }

    /// For You reads the graph through its own snapshot; DIG's switch must
    /// not move a single candidate, score or place.
    func testForYouIsTheSameWhateverDIGIsSetTo() {
        release(sleeve + [("Mark Isham", "Trumpet")])
        let kept = PersonalInputs.Kept(node: node, addedAt: Date(timeIntervalSince1970: 1_790_000_000), genreTags: ["ambient"],
                                       tasteArtistKeys: ["jon hassell"], sceneArtistKey: "jon hassell")
        let personal = PersonalInputs(crate: [kept], plays: [], met: [], artistPlays: [:], haunts: [])
        let asOf = Date(timeIntervalSince1970: 1_790_000_100)
        func forYou() -> (KnowledgeSnapshot, [ExploreSuggestion]) {
            let knowledge = LocalKnowledgeAdapter(context: context).snapshot(for: personal, scenes: false)
            let offers = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf)
            return (knowledge, offers.next + offers.shows + offers.artists)
        }
        MusicianFirst.override = false
        let (offKnowledge, off) = forYou()
        try? context.save()
        MusicianFirst.override = true
        DigRecommendations.override = true
        defer { DigRecommendations.override = nil }
        let (onKnowledge, on) = forYou()
        XCTAssertEqual(offKnowledge, onKnowledge)
        XCTAssertEqual(off.map(\.id), on.map(\.id))
        XCTAssertEqual(off.map(\.score), on.map(\.score))
        XCTAssertTrue(off.contains { $0.node.title == "Mark Isham" })
        // For You never recommends somebody for mastering a record, whatever
        // DIG is set to. See `ContributorRole`.
        XCTAssertFalse(off.contains { $0.node.title == "Rashad Becker" })
    }

    func testOnTheReleasePageStillListsEveryone() throws {
        MusicianFirst.override = true
        release(sleeve)
        let record = try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).first
        let names = Set(DigEngine.creditGroups(from: try XCTUnwrap(record)).flatMap(\.people).map(\.name))
        XCTAssertEqual(names, ["Nana Vasconcelos", "Brian Eno", "Rashad Becker", "Some Engineer"])
    }
}
