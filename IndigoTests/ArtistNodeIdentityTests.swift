//
//  ArtistNodeIdentityTests.swift
//  IndigoTests
//
//  A graph node's Discogs id is identity only when something that identifies
//  the artist supports it.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ArtistNodeIdentityTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func row(_ key: String, _ id: Int, _ name: String, labels: [String] = []) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: key, discogsID: id, name: name)
        record.labelNames = labels
        context.insert(record)
        return record
    }

    private func credits(_ releaseID: Int, _ list: [(filing: String, credited: String, id: Int)]) throws {
        let artists = list.map { #"{"id":\#($0.id),"name":"\#($0.filing)","anv":"\#($0.credited == $0.filing ? "" : $0.credited)"}"# }
        let json = #"{"id":\#(releaseID),"title":"R\#(releaseID)","artists":[\#(artists.joined(separator: ","))]}"#
        ReleaseCreditStore(context: context).replace(
            releaseID: releaseID,
            from: try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)),
            source: ReleaseCreditStore.source(storedRelease: releaseID))
    }

    private func identify(_ node: MusicNode) -> ArtistNodeIdentity {
        ArtistNodeIdentifier(store: DigStore(context: context)).identify(node)
    }

    // MARK: The audit's false merge

    /// The shadow audit found "duenn nyantora" and "duenn" resolving to one
    /// entry: a cached row filed under "duenn nyantora" holds Duenn's record,
    /// and the graph made a node keyed by the row and titled by the record.
    func testDuennNyantoraIsNotDuenn() {
        row("duenn nyantora", 3328071, "Duenn")
        row("duenn", 3328071, "Duenn")
        let misfiled = MusicNode.artist("Duenn", key: "duenn nyantora")
        let duenn = MusicNode.artist("Duenn")

        let misfiledIdentity = identify(misfiled)
        let duennIdentity = identify(duenn)

        XCTAssertEqual(duennIdentity.identity, .discogs(3328071))
        XCTAssertEqual(duennIdentity.provenance, .filedRecord)
        XCTAssertEqual(misfiledIdentity.identity, .name("duenn nyantora"))
        XCTAssertEqual(misfiledIdentity.provenance, .nameOnly)
        XCTAssertNotEqual(misfiledIdentity.identity, duennIdentity.identity)
    }

    func testAMisfiledRowSaysNothingAboutTheName() {
        row("walton", 77829, "Rik Walton")

        XCTAssertEqual(identify(.artist("walton")).provenance, .nameOnly)
        let carried = identify(.artist("Walton", discogsID: 77829))
        XCTAssertEqual(carried.provenance, .inferred, "An id with nothing behind it is kept, never trusted")
        XCTAssertEqual(carried.identity, .name("Walton"))
        XCTAssertEqual(carried.carriedDiscogsID, 77829)
    }

    func testOnlyARecordFiledUnderItsOwnNameIsTrusted() {
        XCTAssertTrue(row("oliwa", 1, "Oliwa (2)").isFiledUnderItsOwnName(), "Filing marks are not a different name")
        XCTAssertTrue(row("savath", 3838, "Savath & Savalas").isFiledUnderItsOwnName())
        XCTAssertFalse(row("duenn nyantora", 3328071, "Duenn").isFiledUnderItsOwnName())
        XCTAssertFalse(row("various", 331217, "Various Production").isFiledUnderItsOwnName())
    }

    // MARK: Verified namesakes

    /// Both Hype Williams share a key; their credits say which is which.
    func testVerifiedNamesakesAreTwoIdentities() throws {
        try credits(1, [("Hype Williams (2)", "Hype Williams (2)", 1874027)])
        try credits(2, [("Hype Williams", "Hype Williams", 82)])

        let duo = identify(.artist("Hype Williams", discogsID: 1874027))
        let director = identify(.artist("Hype Williams", discogsID: 82))

        XCTAssertEqual(duo.identity, .discogs(1874027))
        XCTAssertEqual(director.identity, .discogs(82))
        XCTAssertEqual(duo.provenance, .credit)
        XCTAssertEqual(director.provenance, .credit)
    }

    // MARK: Conflicts

    /// A spelling verified to be Prefuse 73 is Prefuse 73, whatever id the
    /// node arrived carrying.
    func testVerifiedEvidenceBeatsACarriedID() throws {
        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Prefuse73", verdict: .variation(3722), resultCount: 1,
            results: [], facts: [try ArtistIdentityFixtures.facts(3722)]))

        let node = identify(.artist("Prefuse73", discogsID: 999))

        XCTAssertEqual(node.identity, .discogs(3722))
        XCTAssertEqual(node.provenance, .resolver)
        XCTAssertEqual(node.carriedDiscogsID, 999)
    }

    // MARK: Alternate credited spellings

    /// Forsyth Gardens credits Scott Herren as "Guillermo S. Herren".
    func testACreditedSpellingWithItsEntryIsVerified() throws {
        try credits(6947405, [("Scott Herren", "Guillermo S. Herren", 229415)])

        let credited = identify(.artist("Guillermo S. Herren", discogsID: 229415))
        XCTAssertEqual(credited.identity, .discogs(229415))
        XCTAssertEqual(credited.provenance, .credit)

        let bare = identify(.artist("Guillermo S. Herren"))
        XCTAssertEqual(bare.provenance, .nameOnly, "The spelling alone, without the credit's id, is only a name")
    }

    // MARK: Where the graph stamps ids

    func testALabelRosterStampsOnlyTrustedIDs() throws {
        row("duenn nyantora", 3328071, "Duenn", labels: ["Ftarri"])
        row("sugai ken", 4243, "Sugai Ken", labels: ["Ftarri"])
        try context.save()

        let edges = GraphStore(context: context).neighbors(of: .label("Ftarri")).all
            .filter { $0.to.kind == .artist }
        let ids = Dictionary(edges.map { ($0.to.title, $0.to.discogsID) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(ids["Sugai Ken"], .some(4243))
        XCTAssertEqual(ids["Duenn"], .some(nil), "Still offered, without an id the row cannot vouch for")
    }
}
