//
//  ReleaseCreditTests.swift
//  IndigoTests
//
//  Who a release credits, kept with the Discogs ids its document gives them,
//  and opened by those ids rather than by searching a name again.
//

import XCTest
import SwiftData
@testable import Indigo

/// A release document shaped like Discogs' own: a namesake headline artist,
/// a headline credit under another spelling, one person credited twice, a
/// sleeve credit, a name with no entry, and a credit for one track.
private let document = #"""
{"id":555,"title":"Split","year":2009,
 "artists":[{"id":1874027,"name":"Hype Williams (2)"},{"id":3722,"name":"Prefuse 73","anv":"Prefuse73"}],
 "extraartists":[
   {"id":3722,"name":"Prefuse 73","anv":"","role":"Producer","tracks":""},
   {"id":3722,"name":"Prefuse 73","anv":"","role":"Mixed By","tracks":"B1"},
   {"id":229415,"name":"Scott Herren","anv":"G. S. Herren","role":"Written-By","tracks":""},
   {"id":777,"name":"Designers Republic","role":"Design"},
   {"name":"Unfiled Friend","role":"Vocals"}
 ],
 "tracklist":[
   {"position":"A1","title":"One","artists":[{"id":1874027,"name":"Hype Williams (2)"}],
    "extraartists":[{"id":9999,"name":"Dean Blunt","role":"Producer"}]},
   {"position":"B1","title":"Two"}
 ]}
"""#

private let refreshed = #"""
{"id":555,"title":"Split","year":2009,
 "artists":[{"id":1874027,"name":"Hype Williams (2)"}],
 "extraartists":[{"id":229415,"name":"Scott Herren","role":"Written-By"}]}
"""#

private let withoutArtists = #"{"id":555,"title":"Split","year":2009}"#

private func decode(_ json: String) throws -> DiscogsReleaseDetail {
    try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8))
}

final class ReleaseCreditBuilderTests: XCTestCase {
    func testEveryAppearanceIsKeptInDocumentOrder() throws {
        let credits = try XCTUnwrap(ReleaseCredit.credits(in: try decode(document)))

        XCTAssertEqual(credits.filter { $0.category == .artist }.map(\.order), [0, 1])
        XCTAssertEqual(credits.filter { $0.category == .credit }.count, 5, "Every credit as written, sleeve included")
        XCTAssertEqual(credits.filter { $0.category == .credit && $0.discogsID == 3722 }.map(\.role),
                       ["Producer", "Mixed By"], "One person, two credits — not collapsed by id")
        XCTAssertEqual(credits.filter { $0.category == .track }.map(\.tracks), ["A1", "A1"])
    }

    func testTheCreditedSpellingAndTheFilingNameAreBothKept() throws {
        let credits = try XCTUnwrap(ReleaseCredit.credits(in: try decode(document)))
        let prefuse = try XCTUnwrap(credits.first { $0.category == .artist && $0.discogsID == 3722 })
        XCTAssertEqual(prefuse.creditedName, "Prefuse73")
        XCTAssertEqual(prefuse.filingName, "Prefuse 73")

        let hype = try XCTUnwrap(credits.first { $0.category == .artist })
        XCTAssertEqual(hype.filingName, "Hype Williams (2)", "The namesake's mark is kept")
        XCTAssertEqual(hype.name, "Hype Williams")
    }

    func testADocumentWithoutArtistsIsNoAnswer() throws {
        XCTAssertNil(ReleaseCredit.credits(in: try decode(withoutArtists)))
    }
}

@MainActor
final class ReleaseCreditStoreTests: XCTestCase {
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

    private var enricher: DiscogsEnricher { DiscogsEnricher(context: context, client: DiscogsClient()) }

    func testWritingAReleaseKeepsItsCreditsAndLeavesItsNamesAsTheyWere() throws {
        let record = enricher.store(try decode(document), id: 555)

        XCTAssertEqual(record.artistNames, ["Hype Williams", "Prefuse 73"], "Unchanged: names, marks stripped")
        XCTAssertEqual(record.creditNames, ["Prefuse 73", "Prefuse 73", "G. S. Herren", "Unfiled Friend"])
        let store = ReleaseCreditStore(context: context)
        XCTAssertEqual(store.credits(releaseID: 555)?.count, 9)
        XCTAssertEqual(store.provenance(releaseID: 555), "discogs:releases/555")
    }

    func testASleeveSpellingFindsTheEntryItCredited() throws {
        enricher.store(try decode(document), id: 555)
        let store = ReleaseCreditStore(context: context)

        XCTAssertEqual(store.entry(credited: "G. S. Herren")?.discogsID, 229415,
                       "A spelling Discogs' search cannot place, placed by the credit that used it")
        XCTAssertEqual(store.entry(credited: "Prefuse73")?.discogsID, 3722)
        XCTAssertNil(store.entry(credited: "Unfiled Friend"), "No entry named, no answer")
        XCTAssertNil(store.entry(credited: "Nobody At All"))
    }

    func testASpellingCreditedToTwoEntriesAnswersNothing() throws {
        enricher.store(try decode(document), id: 555)
        enricher.store(try decode(#"""
        {"id":556,"title":"Other","artists":[{"id":1,"name":"Someone"}],
         "extraartists":[{"id":424242,"name":"Gary Herren","anv":"G. S. Herren","role":"Bass"}]}
        """#), id: 556)
        XCTAssertNil(ReleaseCreditStore(context: context).entry(credited: "G. S. Herren"), "Namesakes: cannot say which")
    }

    func testARefreshedDocumentReplacesEveryCredit() throws {
        enricher.store(try decode(document), id: 555)
        enricher.store(try decode(refreshed), id: 555, source: ReleaseCreditStore.source(storedRelease: 555))

        let credits = try XCTUnwrap(ReleaseCreditStore(context: context).credits(releaseID: 555))
        XCTAssertEqual(credits.map(\.filingName), ["Hype Williams (2)", "Scott Herren"], "Nothing of the old one left")
        XCTAssertEqual(ReleaseCreditStore(context: context).provenance(releaseID: 555), "r2:releases/555.json")
    }

    func testAnIncompleteDocumentCannotEraseCredits() throws {
        enricher.store(try decode(document), id: 555)
        enricher.store(try decode(withoutArtists), id: 555)

        XCTAssertEqual(ReleaseCreditStore(context: context).credits(releaseID: 555)?.count, 9)
    }

    // MARK: The page

    func testTheRecordShowsHowItCreditsThemAndOpensTheEntryItNames() throws {
        enricher.store(try decode(document), id: 555)
        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 555))

        XCTAssertEqual(profile.artistCredits.map(\.creditedAs), ["Hype Williams", "Prefuse73"])
        XCTAssertEqual(profile.artistCredits[0].page, .digArtist(mbid: nil, name: "Hype Williams", discogsID: 1874027),
                       "The namesake by its entry, never by its name")
        XCTAssertEqual(profile.artistCredits[1].page, .digArtist(mbid: nil, name: "Prefuse 73", discogsID: 3722))
    }

    func testEveryCreditIsALineWithItsRoleAndEntry() throws {
        enricher.store(try decode(document), id: 555)
        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 555))
        let people = profile.credits.flatMap(\.people)

        let prefuse = people.filter { $0.discogsID == 3722 }
        XCTAssertEqual(prefuse.map(\.detail).sorted(), ["Mixed By · B1", "Producer"])
        let herren = try XCTUnwrap(people.first { $0.discogsID == 229415 })
        XCTAssertEqual(herren.name, "G. S. Herren", "Shown as the record spells it")
        XCTAssertEqual(herren.page, .digArtist(mbid: nil, name: "Scott Herren", discogsID: 229415))
        let track = try XCTUnwrap(people.first { $0.discogsID == 9999 })
        XCTAssertEqual(track.detail, "Producer · A1", "A credit for one track says which")
        XCTAssertFalse(people.contains { $0.name == "Designers Republic" }, "The sleeve is not music")
        let unfiled = try XCTUnwrap(people.first { $0.name == "Unfiled Friend" })
        XCTAssertEqual(unfiled.page, .digArtist(mbid: nil, name: "Unfiled Friend", discogsID: nil),
                       "No entry named: the name, as before")
    }

    /// A credit's entry goes through the same resolver every other way in does.
    func testACreditOpensThroughTheOneIdentityPath() throws {
        enricher.store(try decode(document), id: 555)
        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 555))
        guard case .digArtist(let mbid, let name, let id) = profile.artistCredits[1].page else { return XCTFail() }

        let page = DigStore(context: context).artistPage(ArtistReference(name: name, mbid: mbid, discogsID: id))
        XCTAssertEqual(page.resolution.identity, .discogs(3722))
        XCTAssertEqual(page.resolution.basis, .discogsID)
    }

    // MARK: A release cached before its credits kept ids

    /// The record as an older build left it: names, no credit row.
    private func cachedBeforeCredits() throws {
        enricher.store(try decode(document), id: 555)
        let rows = try context.fetch(FetchDescriptor<ReleaseCreditRecord>())
        rows.forEach(context.delete)
        try context.save()
    }

    private final class Reads: @unchecked Sendable {
        var count = 0
    }

    private func store(answering answer: DigStore.StoredReleaseRead, reads: Reads) -> DigStore {
        let store = DigStore(context: context)
        store.readStoredRelease = { _ in reads.count += 1; return answer }
        return store
    }

    func testWithoutCreditIDsThePageFallsBackToNames() throws {
        try cachedBeforeCredits()
        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 555))

        XCTAssertEqual(profile.artistCredits.map(\.page), [
            .digArtist(mbid: nil, name: "Hype Williams", discogsID: nil),
            .digArtist(mbid: nil, name: "Prefuse 73", discogsID: nil)
        ])
        XCTAssertTrue(profile.credits.flatMap(\.people).allSatisfy { $0.discogsID == nil })
    }

    func testTheStoredDocumentFillsInTheIDsWithOneRead() async throws {
        try cachedBeforeCredits()
        let reads = Reads()
        let store = store(answering: .document(try decode(document)), reads: reads)

        await store.backfillReleaseCredits(id: 555)
        await store.backfillReleaseCredits(id: 555)

        XCTAssertEqual(reads.count, 1, "Once filled, never read again")
        XCTAssertEqual(ReleaseCreditStore(context: context).provenance(releaseID: 555), "r2:releases/555.json")
        XCTAssertEqual(DigEngine(context: context).releaseProfile(id: 555)?.artistCredits.first?.discogsID, 1874027)
    }

    func testOpeningAnArtistFillsTheIDsBehindTheirRecordsCredits() async throws {
        try cachedBeforeCredits()
        let reads = Reads()
        let store = store(answering: .document(try decode(document)), reads: reads)

        await store.backfillReleaseCredits(forArtist: "Hype Williams")

        XCTAssertEqual(reads.count, 1)
        // The sleeve's "G. S. Herren" now opens Scott Herren's entry.
        XCTAssertEqual(ReleaseCreditStore(context: context).entry(credited: "G. S. Herren")?.discogsID, 229415)
        await store.backfillReleaseCredits(forArtist: "Hype Williams")
        XCTAssertEqual(reads.count, 1, "Held credits are never read again")
    }

    func testAMissingDocumentIsNotAskedForAgain() async throws {
        try cachedBeforeCredits()
        let reads = Reads()
        let store = store(answering: .missing, reads: reads)

        await store.backfillReleaseCredits(id: 555)
        await store.backfillReleaseCredits(id: 555)

        XCTAssertEqual(reads.count, 1)
        XCTAssertNil(ReleaseCreditStore(context: context).credits(releaseID: 555))
    }

    /// A failed read — offline, a 5xx, a document that would not decode — is
    /// not a finding: nothing is kept and the next open asks again.
    func testAFailedReadIsAskedAgainAndKeepsNothing() async throws {
        try cachedBeforeCredits()
        let reads = Reads()
        let store = store(answering: .unavailable, reads: reads)

        await store.backfillReleaseCredits(id: 555)
        await store.backfillReleaseCredits(id: 555)

        XCTAssertEqual(reads.count, 2)
        XCTAssertNil(ReleaseCreditStore(context: context).credits(releaseID: 555))
    }

    func testAStoredDocumentWithoutArtistsLeavesTheNamesAndIsNotReadAgain() async throws {
        try cachedBeforeCredits()
        let reads = Reads()
        let store = store(answering: .document(try decode(withoutArtists)), reads: reads)

        await store.backfillReleaseCredits(id: 555)
        await store.backfillReleaseCredits(id: 555)

        XCTAssertEqual(reads.count, 1)
        XCTAssertNil(ReleaseCreditStore(context: context).credits(releaseID: 555))
        XCTAssertEqual(DigEngine(context: context).releaseProfile(id: 555)?.artistCredits.count, 2)
    }

    func testCreditsAlreadyHeldAreNeverReadFromStorage() async throws {
        enricher.store(try decode(document), id: 555)
        let reads = Reads()
        let store = store(answering: .missing, reads: reads)

        await store.backfillReleaseCredits(id: 555)

        XCTAssertEqual(reads.count, 0)
    }
}
