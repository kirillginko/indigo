//
//  ShowSuggestionTests.swift
//  IndigoTests
//
//  A tracklist is the best description of a radio show there is. It is what
//  the selector actually reached for, rather than the genre words a station
//  wrote on the schedule, and it is the same evidence a person uses reading
//  down a playlist deciding whether to put an hour into it.
//
//  The graph could only reach a show through an artist whose records happened
//  to be in the local store *and* to carry an appearance — five of those
//  across a whole crate, while the appearance log held eighteen complete
//  tracklists nobody was reading.
//

import XCTest
import SwiftData
@testable import Indigo

final class ShowSuggestionTests: XCTestCase {
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

    @discardableResult
    private func artist(_ name: String, id: Int, styles: [String] = []) -> DiscogsArtist {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name
        )
        record.styles = styles
        context.insert(record)
        return record
    }

    /// A broadcast with a tracklist.
    private func show(_ title: String, slug: String, played: [String]) {
        let store = RecordingStore(context: context)
        for name in played {
            let recording = try? store.upsert(title: "\(name) track", artistName: name)
            let appearance = MediaAppearance(
                providerID: "nts", showTitle: title,
                showID: "\(slug)/\(slug)-episode", isLive: false, method: .providerTracklist
            )
            context.insert(appearance)
            appearance.recording = recording
        }
    }

    private func suggestions(
        taste: TasteProfile = .empty, kept: Set<String> = [], limit: Int = 6
    ) -> [ExploreSuggestion] {
        try? context.save()
        return ShowSuggestionEngine(context: context).suggestions(
            taste: taste, known: [], keptArtistKeys: kept, limit: limit
        )
    }

    // MARK: Who was on it

    func testAShowThatPlayedSomebodyYouKeepIsOffered() {
        show("Soup To Nuts", slug: "soup", played: ["Aphex Twin", "A Stranger"])

        let found = suggestions(kept: [RecordingKey.normalizeArtist("Aphex Twin")])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.node.title, "Soup To Nuts")
        // Names, because a name is something a person can check and a genre is
        // something they have to take on trust.
        XCTAssertEqual(found.first?.reason, "Played Aphex Twin, who you keep")
    }

    func testMoreOfYourPeopleOnOneShowCountsForMore() {
        show("Three", slug: "three", played: ["A", "B", "C", "Nobody"])
        show("One", slug: "one", played: ["A", "Nobody Else"])
        let kept = Set(["A", "B", "C"].map(RecordingKey.normalizeArtist))

        let found = suggestions(kept: kept)
        XCTAssertEqual(found.first?.node.title, "Three")
        XCTAssertTrue(found.first?.reason.contains("and 1 more you keep") ?? false,
                      found.first?.reason ?? "-")
    }

    // MARK: What it sounded like

    func testAShowIsOfferedForSoundingLikeWhatYouListenTo() {
        artist("Someone", id: 1, styles: ["Ambient", "Drone"])
        artist("Somebody", id: 2, styles: ["Ambient"])
        show("An Hour Of It", slug: "hour", played: ["Someone", "Somebody"])

        let taste = TasteProfile.build(from: [
            ListeningEvent(node: .artist("X"), action: .played, seconds: 2400, tags: ["ambient"])
        ])
        let found = suggestions(taste: taste)
        XCTAssertEqual(found.first?.node.title, "An Hour Of It")
        XCTAssertEqual(found.first?.reason, "Ambient — what you listen to")
    }

    func testAnHourWithNothingInCommonIsNotOffered() {
        artist("Someone", id: 1, styles: ["Happy Hardcore"])
        show("Not For You", slug: "no", played: ["Someone"])

        let taste = TasteProfile.build(from: [
            ListeningEvent(node: .artist("X"), action: .played, seconds: 2400, tags: ["ambient"])
        ])
        // Dressing this up as a match is how a recommendation surface stops
        // being worth reading.
        XCTAssertTrue(suggestions(taste: taste).isEmpty)
    }

    func testAShowNobodyCouldNameATrackFromSaysNothingAboutItself() {
        let appearance = MediaAppearance(
            providerID: "nts", showTitle: "Unknown",
            showID: "unknown/episode", isLive: false, method: .none
        )
        context.insert(appearance)
        XCTAssertTrue(suggestions(kept: ["anything"]).isEmpty)
    }

    // MARK: Not offering what they have

    func testAShowAlreadyHeardIsNotOffered() {
        show("Soup To Nuts", slug: "soup", played: ["Aphex Twin"])
        let node = MusicNode.broadcast(providerID: "nts", showID: "soup/soup-episode", title: "Soup To Nuts")
        ListeningLog(context: context).record(node, action: .played, seconds: 2400)

        XCTAssertTrue(suggestions(kept: [RecordingKey.normalizeArtist("Aphex Twin")]).isEmpty)
    }

    func testAShowWithNoPageIsNotOffered() {
        let store = RecordingStore(context: context)
        let recording = try? store.upsert(title: "A track", artistName: "Aphex Twin")
        // Kiosk publishes no per-show page.
        let appearance = MediaAppearance(
            providerID: "kiosk", showTitle: "A Kiosk Show",
            showID: "some-slug", isLive: false, method: .providerTracklist
        )
        context.insert(appearance)
        appearance.recording = recording

        XCTAssertTrue(suggestions(kept: [RecordingKey.normalizeArtist("Aphex Twin")]).isEmpty)
    }

    // MARK: The profile behind it

    func testTasteIsReadFromTheCrateWhenTheLogIsEmpty() {
        // The log is new; the crate is years of decisions. A profile that
        // could only read the log would be empty on every copy of the app
        // that predates it.
        artist("Kept Artist", id: 1, styles: ["Fourth World", "Ambient"])
        let item = CrateItem(
            digKind: .artist, providerID: "dig.artist.name",
            entityID: RecordingKey.normalizeArtist("Kept Artist"), title: "Kept Artist",
            subtitle: "Artist", artworkURL: nil
        )
        context.insert(item)
        try? context.save()

        let taste = TasteProfile.collected(context: context)
        XCTAssertFalse(taste.isEmpty)
        XCTAssertGreaterThan(taste["fourth world"], 0)
        XCTAssertGreaterThan(taste["ambient"], 0)
    }

    func testAnEmptyCollectionHasNoTasteRatherThanAnInventedOne() {
        XCTAssertTrue(TasteProfile.collected(context: context).isEmpty)
    }
}
