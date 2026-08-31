//
//  PortraitFillTests.swift
//  IndigoTests
//
//  Filling in the rows nobody has dug into, slowly, without emptying the
//  request budget.
//

import XCTest
import SwiftData
@testable import Indigo

final class PortraitFillTests: XCTestCase {
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

    /// A picture found on its own is not the same as having dug into someone.
    /// Keeping them apart is what stops a thumbnail lookup masquerading as a
    /// full artist record.
    func testALookedUpPictureIsNotADugArtist() throws {
        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)

        XCTAssertTrue(((try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []).isEmpty)
        XCTAssertEqual(portrait.imageURL?.absoluteString, "https://img.test/stenny.jpg")
    }

    /// Nothing found is a real answer worth remembering, so the same name is
    /// not asked after on every launch — but a catalogue gains artists, so it
    /// is not remembered forever either.
    func testAMissIsRememberedButNotForever() {
        let miss = ArtistPortrait(nameKey: "nobody", name: "Nobody")
        miss.lookupFailed = true
        XCTAssertFalse(miss.isWorthRetrying, "Not today")

        miss.fetchedAt = Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        XCTAssertTrue(miss.isWorthRetrying, "But eventually")

        let hit = ArtistPortrait(nameKey: "stenny", name: "Stenny")
        hit.imageURLString = "https://img.test/stenny.jpg"
        hit.fetchedAt = Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)
        XCTAssertFalse(hit.isWorthRetrying, "A picture we have does not go stale")
    }

    /// The whole point: a row that had nothing gets a picture once the
    /// background fill has been past, without anybody digging into them.
    func testAFilledPortraitReachesTheRow() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny"]
        context.insert(subject)

        XCTAssertNil(DigEngine(context: context).relatedArtists(to: "Skee Mask")
            .first { $0.name == "Stenny" }?.imageURL)

        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)

        XCTAssertEqual(
            DigEngine(context: context).relatedArtists(to: "Skee Mask")
                .first { $0.name == "Stenny" }?.imageURL?.absoluteString,
            "https://img.test/stenny.jpg"
        )
    }

    /// A real portrait from a dig outranks one found by the background fill.
    @MainActor
    func testADugPortraitOutranksALookedUpOne() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny"]
        context.insert(subject)

        let dug = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Stenny"),
                                discogsID: 2, name: "Stenny")
        dug.imageURLString = "https://img.test/dug.jpg"
        dug.labelNames = ["Ilian Tape"]
        context.insert(dug)

        let looked = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        looked.imageURLString = "https://img.test/looked-up.jpg"
        context.insert(looked)

        XCTAssertEqual(
            DigEngine(context: context).relatedArtists(to: "Skee Mask")
                .first { $0.name == "Stenny" }?.imageURL?.absoluteString,
            "https://img.test/dug.jpg"
        )
        XCTAssertEqual(DigStore(context: context).portrait(for: "STENNY")?.imageURLString,
                       "https://img.test/looked-up.jpg",
                       "And the lookup is still findable by however the name was spelled")
    }
}
