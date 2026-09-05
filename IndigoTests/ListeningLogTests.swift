//
//  ListeningLogTests.swift
//  IndigoTests
//
//  Phase 1. The listening log exists so DIG and EXPLORE can be about this
//  listener rather than about a catalogue. What is pinned here is the part
//  that decides whether it is worth anything: a log that counts a mis-click
//  the same as an evening is a log of a mouse.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListeningLogTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var log: ListeningLog!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        log = ListeningLog(context: context)
    }

    override func tearDown() {
        log = nil
        context = nil
        container = nil
    }

    private func hoursAgo(_ hours: Double) -> Date {
        Date().addingTimeInterval(-hours * 3600)
    }

    // MARK: What counts as listening

    func testAMisClickWeighsNothingAndAnEveningWeighsEverything() {
        let node = MusicNode.artist("Suso Sáiz")
        let glance = ListeningEvent(node: node, action: .played, seconds: 4)
        let evening = ListeningEvent(node: node, action: .played, seconds: 3600)

        XCTAssertEqual(glance.weight, 0)
        XCTAssertEqual(evening.weight, 1)
    }

    func testATrackPlayedToItsEndCountsFullyHoweverShortItWas() {
        // Ninety seconds is nowhere near the twenty-minute ceiling, so without
        // completion a finished interlude would score 0.075 — the same as
        // abandoning a mix a minute in.
        let interlude = ListeningEvent(
            node: .artist("Jon Hassell"), action: .played,
            seconds: 90, completion: 1
        )
        XCTAssertEqual(interlude.weight, 1)
    }

    func testASkipArguesForNothingAndADismissalArguesAgainst() {
        let node = MusicNode.artist("Pablo's Eye")
        XCTAssertEqual(ListeningEvent(node: node, action: .skipped, seconds: 12).weight, 0)
        XCTAssertLessThan(ListeningEvent(node: node, action: .dismissed).weight, 0)
    }

    func testANodeWithNoKeyIsNotLogged() {
        // An unnamed thing with no identity would be a row nothing could ever
        // be counted against.
        let nameless = MusicNode(kind: .artist, key: "", title: "")
        XCTAssertNil(log.record(nameless, action: .played, seconds: 600))
        XCTAssertTrue(log.all().isEmpty)
    }

    // MARK: Counting

    func testTheSameThingMetTwiceIsTwoEventsAndOneRow() {
        let node = MusicNode.artist("Suso Sáiz")
        log.record(node, action: .played, at: hoursAgo(48), seconds: 900)
        log.record(node, action: .played, at: hoursAgo(2), seconds: 900)

        XCTAssertEqual(log.events(for: node).count, 2)
        let gathered = ListeningLog.gather(log.all())
        XCTAssertEqual(gathered.count, 1)
        XCTAssertEqual(gathered.first?.count, 2)
    }

    func testStationsAreRankedByListeningRatherThanByClicks() {
        // Six glances at one station and one long sitting with another. The
        // afternoon is what they listen to; the clicking is what they did.
        let clicked = MusicNode.station(providerID: NTSProvider.providerID)
        let listened = MusicNode.station(providerID: KioskProvider.providerID)
        for index in 0..<6 {
            log.record(clicked, action: .played, at: hoursAgo(Double(index)), seconds: 40)
        }
        log.record(listened, action: .played, at: hoursAgo(1), seconds: 4 * 3600)

        XCTAssertEqual(log.stations().first?.node.id, listened.id)
    }

    func testSkipsDoNotEarnAPlaceInWhatTheyListenTo() {
        let rejected = MusicNode.artist("Nobody")
        for index in 0..<20 {
            log.record(rejected, action: .skipped, at: hoursAgo(Double(index)), seconds: 8)
        }
        XCTAssertTrue(log.artists().isEmpty)
    }

    // MARK: Where have I heard this

    func testAnArtistRemembersEveryPlaceTheyWereMetOnce() {
        let node = MusicNode.artist("Suso Sáiz")
        let noods = ListeningSource(
            providerID: NoodsProvider.providerID,
            showID: "noods.show.endpapers", showTitle: "Endpapers"
        )
        let nts = ListeningSource(
            providerID: NTSProvider.providerID,
            showID: "nts.episode.psf", showTitle: "Perfect Sound Forever"
        )
        log.record(node, action: .played, at: hoursAgo(50), seconds: 800, source: noods)
        log.record(node, action: .played, at: hoursAgo(20), seconds: 800, source: nts)
        // The same show again: a place met twice is still one place.
        log.record(node, action: .played, at: hoursAgo(1), seconds: 800, source: noods)

        let encounters = try? XCTUnwrap(log.encounters(with: node))
        XCTAssertEqual(encounters?.count, 3)
        XCTAssertEqual(encounters?.places.count, 2)
        // Most recent first, so the answer to "why is this familiar" starts
        // with the time they are likeliest to remember.
        XCTAssertEqual(encounters?.places.first?.line, "Noods / Endpapers")
        XCTAssertTrue(encounters?.places.contains { $0.line == "NTS / Perfect Sound Forever" } ?? false)
    }

    func testOpeningAPageIsAnEncounterButNotAListen() {
        let node = MusicNode.artist("Finis Africae")
        log.record(node, action: .opened)
        let encounters = log.encounters(with: node)

        XCTAssertNotNil(encounters)
        // Reading about somebody four times is not hearing them four times.
        XCTAssertEqual(encounters?.count, 0)
        XCTAssertTrue(log.hasEncountered(node))
    }

    func testSomethingNeverMetIsNotAnEncounter() {
        XCTAssertFalse(log.hasEncountered(.artist("Spencer Clark")))
        XCTAssertNil(log.encounters(with: .artist("Spencer Clark")))
    }

    // MARK: Tags

    func testTagsAreFoldedSoOneInterestIsNotCountedThreeTimes() {
        let folded = ListeningLog.foldTags(["Ambient", "ambient", "AMBIENT / Drone", "  dub  "])
        XCTAssertEqual(folded, ["ambient", "drone", "dub"])
    }
}
