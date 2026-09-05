//
//  ExploreSuggestionTests.swift
//  IndigoTests
//
//  EXPLORE could only ever show the listener their own crate back: every
//  section on it was a filter over things they had already decided to keep.
//  What is pinned here is the one property that makes the new block a way of
//  finding anything — that what it offers is somewhere they have not been.
//

import XCTest
import SwiftData
@testable import Indigo

final class ExploreSuggestionTests: XCTestCase {
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

    /// An artist Discogs knows, with labelmates to reach.
    @discardableResult
    private func artist(
        _ name: String, id: Int, labels: [String] = [], styles: [String] = []
    ) -> DiscogsArtist {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name
        )
        record.labelNames = labels
        record.styles = styles
        context.insert(record)
        return record
    }

    private func crate(artist name: String) {
        let item = CrateItem(
            digKind: .artist, providerID: "dig.artist.name",
            entityID: RecordingKey.normalizeArtist(name), title: name,
            subtitle: "Artist", artworkURL: nil
        )
        context.insert(item)
    }

    private func suggestions() -> [ExploreSuggestion] {
        try? context.save()
        return ExploreSuggestionEngine(context: context).suggestions()
    }

    // MARK: The point of it

    func testItOffersSomewhereYouHaveNotBeen() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        artist("Inga Copeland", id: 2, labels: ["World Music"])
        crate(artist: "Dean Blunt")

        let found = suggestions()
        let copeland = found.first { $0.node.title == "Inga Copeland" }
        XCTAssertNotNil(copeland)
        XCTAssertEqual(copeland?.via, "Dean Blunt")

        // The label he releases on is offered too, and should be: an imprint
        // is somewhere to dig, not only a fact about an artist. Everything
        // reachable is fair game as long as it has a page and has not been met.
        XCTAssertTrue(found.contains { $0.node.kind == .label && $0.node.title == "World Music" })
    }

    func testItNeverOffersSomethingAlreadyInTheCrate() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        artist("Inga Copeland", id: 2, labels: ["World Music"])
        crate(artist: "Dean Blunt")
        crate(artist: "Inga Copeland")

        // Both are already kept. A suggestion somebody has already decided
        // about is not a suggestion, and leaving it in is how a discovery
        // surface turns back into a mirror.
        XCTAssertFalse(suggestions().contains { $0.node.title == "Inga Copeland" })
    }

    func testItNeverOffersSomethingAlreadyHeard() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        artist("Inga Copeland", id: 2, labels: ["World Music"])
        crate(artist: "Dean Blunt")
        ListeningLog(context: context).record(
            .artist("Inga Copeland"), action: .played, seconds: 1800
        )

        XCTAssertFalse(suggestions().contains { $0.node.title == "Inga Copeland" })
    }

    func testWithNothingKeptThereIsNothingToWalkOutOf() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        // No crate, no history. Offering something anyway would mean
        // inventing a starting point this listener never gave.
        XCTAssertTrue(suggestions().isEmpty)
    }

    // MARK: Explaining itself

    func testEverySuggestionSaysWhatItRestsOn() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        artist("Inga Copeland", id: 2, labels: ["World Music"])
        crate(artist: "Dean Blunt")

        let found = suggestions()
        XCTAssertFalse(found.isEmpty)
        for suggestion in found {
            // The rule the whole of DIG rests on: a connection Indigo cannot
            // explain is one it will not show.
            XCTAssertFalse(suggestion.reason.isEmpty, suggestion.node.title)
            XCTAssertFalse(suggestion.via.isEmpty, suggestion.node.title)
            XCTAssertTrue(suggestion.connection.contains("via"), suggestion.connection)
        }
    }

    func testTheReasonIsTheEdgesOwnWordsRatherThanAPhraseInventedHere() {
        artist("Dean Blunt", id: 1, labels: ["World Music"])
        artist("Inga Copeland", id: 2, labels: ["World Music"])
        crate(artist: "Dean Blunt")

        XCTAssertEqual(suggestions().first?.reason, "Releases on World Music")
    }

    // MARK: Somewhere to land

    func testNothingIsOfferedThatCannotBeOpened() {
        artist("Dean Blunt", id: 1, labels: ["World Music"], styles: ["Ambient"])
        artist("Inga Copeland", id: 2, labels: ["World Music"], styles: ["Ambient"])
        crate(artist: "Dean Blunt")

        for suggestion in suggestions() {
            // A row that looks like a link and does nothing is worse than no
            // row. Styles and selectors have no page, so they never appear.
            XCTAssertNotNil(suggestion.node.destination, suggestion.node.title)
        }
    }

    func testTheSameThingReachedTwoWaysIsOfferedOnce() {
        artist("Dean Blunt", id: 1, labels: ["World Music"], styles: ["Ambient"])
        artist("Babyfather", id: 3, labels: ["World Music"], styles: ["Ambient"])
        artist("Inga Copeland", id: 2, labels: ["World Music"], styles: ["Ambient"])
        crate(artist: "Dean Blunt")
        crate(artist: "Babyfather")

        let copeland = suggestions().filter { $0.node.title == "Inga Copeland" }
        XCTAssertEqual(copeland.count, 1)
    }

    func testTheListIsCappedSoThePageStaysAPage() {
        for index in 0..<40 {
            artist("Artist \(index)", id: index + 10, labels: ["World Music"])
        }
        crate(artist: "Artist 0")
        try? context.save()

        XCTAssertLessThanOrEqual(
            ExploreSuggestionEngine(context: context).suggestions(limit: 12).count, 12
        )
    }
}
