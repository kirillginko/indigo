//
//  EncounterSectionTests.swift
//  IndigoTests
//
//  Phase 2. "Why does this sound familiar?" — the part of DIG that is about
//  the listener rather than about the music. Pinned here is when the block
//  should say nothing at all, which is the decision that keeps it from
//  becoming a heading over a count of one on every page in the app.
//

import XCTest
import SwiftData
@testable import Indigo

final class EncounterSectionTests: XCTestCase {
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

    private func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }

    // MARK: When to say nothing

    func testAPageOpenedOnceAndNeverHeardHasNothingToSay() {
        let node = MusicNode.artist("Spencer Clark")
        log.record(node, action: .opened)

        let encounters = log.encounters(with: node)
        XCTAssertNotNil(encounters)
        // Telling somebody they have come across this before, when the only
        // evidence is that they are looking at it right now, is telling them
        // what they already did.
        XCTAssertFalse(encounters?.hasSomethingToSay ?? true)
    }

    func testKeepingSomethingIsWorthSayingEvenWithoutAListen() {
        let node = MusicNode.label("Music From Memory")
        log.record(node, action: .saved)

        let encounters = try? XCTUnwrap(log.encounters(with: node))
        XCTAssertEqual(encounters?.count, 0)
        XCTAssertTrue(encounters?.isSaved ?? false)
        XCTAssertTrue(encounters?.hasSomethingToSay ?? false)
    }

    func testOneRealListenIsWorthSaying() {
        let node = MusicNode.artist("Suso Sáiz")
        log.record(node, action: .played, seconds: 1800)
        XCTAssertTrue(log.encounters(with: node)?.hasSomethingToSay ?? false)
    }

    // MARK: The sentence

    func testTheCountIsListensRatherThanTimesTheyLookedAtThePage() {
        let node = MusicNode.artist("Jon Hassell")
        log.record(node, action: .played, at: daysAgo(9), seconds: 1800)
        log.record(node, action: .played, at: daysAgo(2), seconds: 1800)
        for _ in 0..<5 { log.record(node, action: .opened) }

        XCTAssertEqual(log.encounters(with: node)?.count, 2)
    }

    func testFirstAndLatestBracketTheWholeHistory() {
        let node = MusicNode.artist("Finis Africae")
        log.record(node, action: .played, at: daysAgo(300), seconds: 900)
        log.record(node, action: .played, at: daysAgo(40), seconds: 900)
        log.record(node, action: .played, at: daysAgo(1), seconds: 900)

        let encounters = try? XCTUnwrap(log.encounters(with: node))
        let span = try? XCTUnwrap(encounters).lastAt?.timeIntervalSince(
            XCTUnwrap(encounters).firstAt ?? Date()
        )
        XCTAssertEqual(span ?? 0, 299 * 86_400, accuracy: 3600)
    }

    // MARK: Dates

    func testDatesGetCoarserTheFurtherBackTheyGo() {
        let now = Date()
        XCTAssertEqual(EncounterSection.dayLabel(now, now: now), "Today")
        XCTAssertEqual(
            EncounterSection.dayLabel(now.addingTimeInterval(-3 * 86_400), now: now),
            "3 days ago"
        )
        XCTAssertEqual(
            EncounterSection.dayLabel(now.addingTimeInterval(-9 * 86_400), now: now),
            "Last week"
        )
        XCTAssertEqual(
            EncounterSection.dayLabel(now.addingTimeInterval(-20 * 86_400), now: now),
            "2 weeks ago"
        )
        // Past a month it becomes a date, because that is how somebody
        // actually remembers a year ago.
        XCTAssertFalse(
            EncounterSection.dayLabel(now.addingTimeInterval(-400 * 86_400), now: now)
                .contains("ago")
        )
    }

    func testAGlanceIsNotReportedAsATimeHeard() {
        XCTAssertNil(EncounterSection.durationLabel(12))
        XCTAssertEqual(EncounterSection.durationLabel(35 * 60), "35m")
        XCTAssertEqual(EncounterSection.durationLabel(4 * 3600 + 20 * 60), "4h 20m")
    }

    // MARK: Getting back there

    func testAPlaceOpensTheBroadcastItWasHeardIn() {
        let node = MusicNode.artist("Suso Sáiz")
        log.record(
            node, action: .played, seconds: 900,
            source: ListeningSource(
                providerID: LYLProvider.providerID,
                showID: "lyl.episode.endpapers", showTitle: "Endpapers"
            )
        )
        let place = log.encounters(with: node)?.places.first
        XCTAssertEqual(place?.line, "LYL / Endpapers")
        XCTAssertEqual(place?.destination, .lylEpisode(slug: "endpapers"))
    }

    func testAPlaceWithNoPageIsStillNamedRatherThanDropped() {
        let node = MusicNode.artist("Someone")
        log.record(
            node, action: .played, seconds: 900,
            source: ListeningSource(providerID: KioskProvider.providerID, showTitle: "Outsiders")
        )
        let place = log.encounters(with: node)?.places.first
        XCTAssertEqual(place?.line, "Kiosk / Outsiders")
        // Kiosk publishes no per-show page. Knowing where you heard it still
        // beats not knowing, so the line stays and simply does not click.
        XCTAssertNil(place?.destination)
    }
}
