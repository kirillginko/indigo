//
//  ArtistNavigationTests.swift
//  IndigoTests
//
//  Where an artist reference lands: either spelling of Prefuse 73 on one page
//  reading what was credited under both, old crate and history references
//  still working, aliases kept apart, and an empty alias opening its richer
//  alias with a note of where the listener came from.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ArtistNavigationTests: XCTestCase {
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

    // MARK: Evidence, as the lookup leaves it

    private func recordPrefuseEvidence() throws {
        let store = ArtistIdentityStore(context: context)
        let facts = try ArtistIdentityFixtures.facts(3722)
        store.record(DiscogsSpellingCheck(
            spelling: "Prefuse73", verdict: .variation(3722), resultCount: 15,
            results: [], facts: [facts]
        ))
    }

    @discardableResult
    private func described(
        _ name: String, id: Int, releases: Int = 0, biography: String? = nil, image: Bool = false
    ) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
        record.releaseTitles = (0..<releases).map { "Record \($0)" }
        record.releaseYears = record.releaseTitles.map { _ in "2001" }
        record.releaseDiscogsIDs = (0..<releases).map { id * 1000 + $0 }
        record.releaseImageURLStrings = record.releaseTitles.map { _ in "" }
        record.releaseLabels = record.releaseTitles.map { _ in "" }
        record.biography = biography
        record.imageURLString = image ? "https://img.test/\(id).jpg" : nil
        context.insert(record)
        return record
    }

    // MARK: Prefuse 73

    func testEitherSpellingOpensTheSamePage() throws {
        try recordPrefuseEvidence()
        described("Prefuse 73", id: 3722, releases: 3, biography: "Guillermo Scott Herren", image: true)
        let store = DigStore(context: context)

        let joined = store.artistPage(ArtistReference(name: "Prefuse73"))
        let spaced = store.artistPage(ArtistReference(name: "Prefuse 73"))

        XCTAssertEqual(joined.pageID, spaced.pageID)
        XCTAssertEqual(joined.name, "Prefuse 73")
        XCTAssertEqual(joined.discogsID, 3722)
        XCTAssertEqual(joined.alsoCreditedAs, ["Prefuse 73", "Prefuse73"])
        XCTAssertEqual(spaced.alsoCreditedAs, ["Prefuse 73", "Prefuse73"])
        XCTAssertEqual(joined.arrivedAs, "Prefuse73", "The page says which spelling was followed")
        XCTAssertNil(spaced.arrivedAs)
    }

    /// A crate row or a visit saved under the spelling still opens — and opens
    /// the artist. Nothing about the saved reference is rewritten.
    func testAReferenceSavedUnderTheSpellingStillOpensTheArtist() throws {
        try recordPrefuseEvidence()
        described("Prefuse 73", id: 3722, releases: 3, biography: "x", image: true)
        let store = DigStore(context: context)
        let saved = DetailPage.digArtist(mbid: nil, name: "Prefuse73")

        guard case .digArtist(let mbid, let name, let discogsID) = saved else { return XCTFail() }
        let page = store.artistPage(ArtistReference(name: name, mbid: mbid, discogsID: discogsID))
        XCTAssertEqual(page.name, "Prefuse 73")

        let node = try XCTUnwrap(store.node(for: saved))
        XCTAssertEqual(node.key, RecordingKey.normalizeArtist("Prefuse 73"),
                       "A new visit counts toward the artist")
        XCTAssertEqual(node.discogsID, 3722)
    }

    func testBeforeAnyEvidenceASpellingOpensAsItself() {
        let store = DigStore(context: context)
        let page = store.artistPage(ArtistReference(name: "Prefuse73"))

        XCTAssertEqual(page.name, "Prefuse73")
        XCTAssertNil(page.discogsID)
        XCTAssertNil(page.arrivedAs)
    }

    /// What was credited under either spelling is on the page, each record
    /// still filed under the credit it was written with.
    func testThePageReadsRecordsCreditedUnderEitherSpelling() throws {
        described("Prefuse 73", id: 3722, biography: "x")
        for (id, title, credit) in [(10, "One Word Extinguisher", "Prefuse 73"), (11, "Point To B", "Prefuse73")] {
            let record = DiscogsReleaseRecord(discogsID: id, title: title)
            record.artistNames = [credit]
            record.year = 2003
            context.insert(record)
        }
        try context.save()

        let alone = DigEngine(context: context).artistProfile(name: "Prefuse 73", mbid: nil)
        let together = DigEngine(context: context)
            .artistProfile(name: "Prefuse 73", mbid: nil, alsoCreditedAs: ["Prefuse 73", "Prefuse73"])

        XCTAssertEqual(Set(alone.releases.map(\.title)), ["One Word Extinguisher"])
        XCTAssertEqual(Set(together.releases.map(\.title)), ["One Word Extinguisher", "Point To B"])
        let credited = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>())
            .first { $0.discogsID == 11 }?.artistNames
        XCTAssertEqual(credited, ["Prefuse73"], "The record keeps its own credit")
    }

    // MARK: Aliases

    private func recordAliasFacts() throws {
        let store = ArtistIdentityStore(context: context)
        for id in [3722, 6810891, 229415, 2576890, 1172814] {
            store.record(try ArtistIdentityFixtures.facts(id))
        }
    }

    /// The navigation case the alias work exists for: Reto A Ichi's record
    /// says nothing, Discogs lists Prefuse 73 as the same person, and the page
    /// opens Prefuse 73 — saying it came from Reto A Ichi.
    func testAnEmptyAliasOpensItsRichestAlias() throws {
        try recordAliasFacts()
        described("Reto A Ichi", id: 6810891)
        described("Prefuse 73", id: 3722, releases: 40, biography: "Guillermo Scott Herren", image: true)
        described("Scott Herren", id: 229415, releases: 12, biography: "Born: 1976", image: true)
        let store = DigStore(context: context)

        let page = store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: 6810891))

        XCTAssertEqual(page.name, "Prefuse 73")
        XCTAssertEqual(page.discogsID, 3722)
        XCTAssertEqual(page.cameFrom, "Reto A Ichi")
        XCTAssertNil(page.arrivedAs)
        XCTAssertEqual(page.resolution.identity, .discogs(6810891), "The alias keeps its own identity")
    }

    /// With two records of its own it stays itself, its records its own, and
    /// borrows Prefuse 73's description with his name on it.
    func testASparseAliasKeepsItsRecordsAndBorrowsADescription() throws {
        try recordAliasFacts()
        described("Reto A Ichi", id: 6810891, releases: 2, image: true)
        described("Prefuse 73", id: 3722, releases: 40, biography: "Guillermo Scott Herren", image: true)
        let store = DigStore(context: context)

        let page = store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: 6810891))

        XCTAssertEqual(page.name, "Reto A Ichi")
        XCTAssertEqual(page.discogsID, 6810891)
        XCTAssertNil(page.cameFrom)
        XCTAssertEqual(page.borrowed, ArtistPageIdentity.Borrowed(
            name: "Prefuse 73", discogsID: 3722, biography: "Guillermo Scott Herren"))
        XCTAssertEqual(page.alsoCreditedAs, ["Reto A Ichi"], "Not Prefuse 73's records")
    }

    func testAnEmptyAliasWithNoKnownAliasesOpensAsItself() throws {
        try recordAliasFacts()
        described("Reto A Ichi", id: 6810891)
        let store = DigStore(context: context)

        let page = store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: 6810891))

        XCTAssertEqual(page.name, "Reto A Ichi")
        XCTAssertNil(page.cameFrom)
    }

    func testMicaLeviAndMicachuEachOpenAsThemselves() throws {
        try recordAliasFacts()
        described("Mica Levi", id: 2576890, releases: 30, biography: "Composer", image: true)
        described("Micachu", id: 1172814, releases: 30, biography: "Musician", image: true)
        let store = DigStore(context: context)

        let mica = store.artistPage(ArtistReference(name: "Mica Levi", discogsID: 2576890))
        let micachu = store.artistPage(ArtistReference(name: "Micachu", discogsID: 1172814))

        XCTAssertEqual(mica.name, "Mica Levi")
        XCTAssertEqual(micachu.name, "Micachu")
        XCTAssertNil(mica.borrowed)
        XCTAssertNil(micachu.borrowed)
        XCTAssertNotEqual(mica.pageID, micachu.pageID)
    }

    /// A richer record arriving later moves the choice, with nothing rewritten.
    func testTheChoiceFollowsTheEvidenceAsItArrives() throws {
        try recordAliasFacts()
        described("Reto A Ichi", id: 6810891)
        let store = DigStore(context: context)
        let reference = ArtistReference(name: "Reto A Ichi", discogsID: 6810891)
        XCTAssertNil(store.artistPage(reference).cameFrom)

        described("Prefuse 73", id: 3722, releases: 40, biography: "x", image: true)
        store.bumpRevisionForTesting()

        XCTAssertEqual(store.artistPage(reference).cameFrom, "Reto A Ichi")
    }
}

// MARK: - Radio under both spellings

final class CombinedArtistRadioTests: XCTestCase {
    private let joinedRow = UUID()
    private let spacedRow = UUID()
    private let show = UUID()

    private func play(_ name: String, episode: UUID, aired: TimeInterval, show: UUID?) -> Catalog.ArtistRadioAppearance {
        Catalog.ArtistRadioAppearance(
            appearanceID: UUID(), episodeID: episode, episodeTitle: nil,
            airedAt: Date(timeIntervalSince1970: aired), archiveURL: nil,
            episodeExternalID: episode.uuidString, provider: "nts", showID: show,
            showTitle: nil, station: nil, hostName: nil, trackIndex: 1,
            rawArtistName: name, rawTrackTitle: "t", offsetSeconds: nil, recordingID: nil
        )
    }

    private func summary(_ row: UUID, plays: Int, episodes: Int, showCount: Int) -> Catalog.ArtistRadioSummary {
        Catalog.ArtistRadioSummary(
            artistID: row, appearanceCount: plays, episodeCount: episodes, showCount: showCount,
            hostCount: 0, firstAppearanceAt: nil, latestAppearanceAt: nil,
            topShows: [Catalog.ArtistRadioSummary.TopShow(
                showID: show, provider: "nts", externalID: "x", title: "Show", station: nil,
                hostName: nil, appearanceCount: plays)]
        )
    }

    func testBothRowsAreOneRecordAndEveryPlayKeepsItsCredit() throws {
        let shared = UUID()
        let spaced = Catalog.ArtistRadioPart(
            summary: summary(spacedRow, plays: 2, episodes: 2, showCount: 1),
            appearances: [play("Prefuse 73", episode: shared, aired: 100, show: show),
                          play("Prefuse 73", episode: UUID(), aired: 300, show: show)],
            relations: [])
        let joined = Catalog.ArtistRadioPart(
            summary: summary(joinedRow, plays: 1, episodes: 1, showCount: 1),
            appearances: [play("Prefuse73", episode: shared, aired: 100, show: show)],
            relations: [])

        let combined = try XCTUnwrap(Catalog.combinedRadio([spaced, joined]))

        XCTAssertEqual(combined.summary.appearanceCount, 3)
        XCTAssertEqual(combined.summary.episodeCount, 2, "One episode played both spellings")
        XCTAssertEqual(combined.summary.showCount, 1)
        XCTAssertEqual(combined.summary.topShows.first?.appearanceCount, 3)
        XCTAssertEqual(combined.summary.artistID, spacedRow, "The primary row stays primary")
        XCTAssertEqual(Set(combined.appearances.compactMap(\.rawArtistName)), ["Prefuse 73", "Prefuse73"])
        XCTAssertEqual(combined.appearances.first?.airedAt, Date(timeIntervalSince1970: 300))
    }

    func testAnEdgeBetweenTheTwoRowsIsDropped() throws {
        func relation(to row: UUID, evidence: Int) -> Catalog.RadioRelation {
            Catalog.RadioRelation(
                relationshipType: "radio_neighbor", entityType: "artist", entityID: row,
                title: nil, station: nil, provider: nil, externalID: nil,
                evidenceCount: evidence, confidence: 0.5, metadata: nil)
        }
        let other = UUID()
        let combined = try XCTUnwrap(Catalog.combinedRadio([
            Catalog.ArtistRadioPart(summary: summary(spacedRow, plays: 1, episodes: 1, showCount: 1),
                                    appearances: [], relations: [relation(to: joinedRow, evidence: 4), relation(to: other, evidence: 2)]),
            Catalog.ArtistRadioPart(summary: summary(joinedRow, plays: 1, episodes: 1, showCount: 1),
                                    appearances: [], relations: [relation(to: other, evidence: 3)])
        ]))

        XCTAssertEqual(combined.relations.map(\.entityID), [other])
        XCTAssertEqual(combined.relations.first?.evidenceCount, 5)
        XCTAssertEqual(combined.summary.episodeCount, 2, "Counts are added when the plays were not read in full")
    }
}
