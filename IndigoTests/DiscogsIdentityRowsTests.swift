//
//  DiscogsIdentityRowsTests.swift
//  IndigoTests
//

import XCTest
@testable import Indigo

final class DiscogsIdentityRowsTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func link(_ row: UUID, _ provider: String, _ id: String) -> DiscogsIdentityRows.Link {
        .init(entity_id: row, provider: provider, external_id: id)
    }

    func testAMusicBrainzLinkGivesARowWithoutADirectOneItsEntry() {
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: [link(a, "musicbrainz_discogs", "361057")]), [a: 361057])
    }

    func testADirectLinkWinsWhicheverArrivesFirst() {
        let mixed = [link(a, "musicbrainz_discogs", "5"), link(a, "discogs", "900")]
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: mixed), [a: 900])
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: mixed.reversed()), [a: 900])
    }

    func testWithinOneProviderTheSmallestIdWins() {
        let two = [link(a, "discogs", "3999072"), link(a, "discogs", "1982320")]
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: two), [a: 1982320])
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: two.reversed()), [a: 1982320])
    }

    /// One MusicBrainz artist leading to two Discogs entries (Anika: 1982320,
    /// 3999072) may be an alias or a second project: neither is read.
    func testARowWhoseMusicBrainzLinksNameTwoEntriesReadsNeither() {
        let two = [link(a, "musicbrainz_discogs", "3999072"), link(a, "musicbrainz_discogs", "1982320"), link(b, "discogs", "1982320")]
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: two), [b: 1982320])
        XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: two), [1982320: [b]])
        // A direct link still counts.
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: two + [link(a, "discogs", "77")]), [a: 77, b: 1982320])
    }

    func testOtherProvidersAndUnreadableIdsAreNothing() {
        let noise = [link(a, "musicbrainz", "003f3a74"), link(b, "discogs", "not-a-number"), link(c, "spotify", "12")]
        XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: noise), [:])
        XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: noise), [:])
    }

    func testAnIdsDirectlyLinkedRowsComeFirstThenTheRestByRowId() {
        // Prefuse 73 holds 3722 directly; the split "Prefuse73" row through MusicBrainz.
        let links = [link(a, "musicbrainz_discogs", "3722"), link(c, "discogs", "3722"), link(b, "discogs", "3722")]
        XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: links), [3722: [b, c, a]])
        XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: links.reversed()), [3722: [b, c, a]])
    }

    func testARowLinkedBothWaysIsListedOnceAsDirect() {
        let links = [link(b, "musicbrainz_discogs", "7"), link(a, "musicbrainz_discogs", "7"), link(b, "discogs", "7")]
        XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: links), [7: [b, a]])
    }

    func testTheOverrideDecidesAndOffIsTheDefaultOutsideADevelopmentSwitch() {
        defer { DiscogsIdentityRows.override = nil }
        DiscogsIdentityRows.override = false
        XCTAssertFalse(DiscogsIdentityRows.isEnabled)
        DiscogsIdentityRows.override = true
        XCTAssertTrue(DiscogsIdentityRows.isEnabled)
    }

    /// Off, each reader folds the `discogs` rows exactly as it did before.
    func testOffTheReadersKeepTheirOwnFolds() {
        let links = [link(b, "discogs", "9"), link(a, "discogs", "30"), link(a, "discogs", "20")]
        XCTAssertEqual(DiscogsIdentityRows.firstDiscogs(byRow: links), [b: 9, a: 30])
        XCTAssertEqual(DiscogsIdentityRows.smallestDiscogs(byRow: links), [b: 9, a: 20])
        let shared = [link(c, "discogs", "7"), link(a, "discogs", "7")]
        XCTAssertEqual(DiscogsIdentityRows.arrivingRows(byDiscogs: shared), [7: [c, a]])
    }

    /// On, the answer does not depend on the order the rows arrive in, so
    /// two devices asking the same question read the same identities.
    func testOnTheAnswerIsTheSameInEveryArrivalOrder() {
        let links = [link(a, "musicbrainz_discogs", "3722"), link(b, "discogs", "3722"), link(c, "musicbrainz_discogs", "3722"),
                     link(c, "discogs", "11"), link(b, "discogs", "40")]
        let byRow = DiscogsIdentityRows.discogs(byRow: links), byID = DiscogsIdentityRows.rows(byDiscogs: links)
        XCTAssertEqual(byRow, [a: 3722, b: 40, c: 11])
        XCTAssertEqual(byID[3722], [b, a, c])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let shuffled = links.shuffled(using: &generator)
            XCTAssertEqual(DiscogsIdentityRows.discogs(byRow: shuffled), byRow)
            XCTAssertEqual(DiscogsIdentityRows.rows(byDiscogs: shuffled), byID)
        }
    }

    /// For You merges on `discogs:<id>`: a radio row known only through
    /// MusicBrainz now joins a bundle's sighting of the same Discogs entry.
    func testAMusicBrainzLinkedRadioRowMergesWithTheSameDiscogsEntry() {
        let entry = DiscogsIdentityRows.discogs(byRow: [link(a, "musicbrainz_discogs", "361057")])[a]
        let radio = ListenerRetrieval.Sighting(name: "Ornella Vanoni", discogsID: entry, catalogueRow: a,
                                               route: .init(provenance: .radioAdjacent, score: 1, seed: "s", cluster: 0, why: "radio"))
        let bundle = ListenerRetrieval.Sighting(name: "Ornella Vanoni", discogsID: 361057, catalogueRow: nil,
                                                route: .init(provenance: .direct, score: 1, seed: "s", cluster: 0, why: "credit"))
        let merged = ListenerRetrieval.merge([radio, bundle]).candidates
        XCTAssertEqual(merged.map(\.identity), ["discogs:361057"])
        XCTAssertEqual(merged.first?.routes.count, 2)
    }
}
