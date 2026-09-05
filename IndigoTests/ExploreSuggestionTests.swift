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

    // MARK: Somewhere worth going, not merely somewhere certain

    /// The bug as it was reported: "Also records as Kate NV" offered to
    /// somebody who keeps Kate NV.
    ///
    /// An alias is the best-evidenced edge in the entire graph — it outscores
    /// everything — and it is worth nothing at all as a suggestion, because it
    /// is the same person under another name. Confidence and worth are
    /// different questions, and this block ranks on the second.
    func testAnotherNameForTheSamePersonIsNotSomewhereToGo() {
        let kate = artist("Kate NV", id: 1)
        kate.aliasNames = ["Kate Shilonosova"]
        artist("Kate Shilonosova", id: 2)
        crate(artist: "Kate NV")

        XCTAssertFalse(suggestions().contains { $0.node.title == "Kate Shilonosova" })
    }

    func testAnAliasEdgeDoesNotHideARealReasonForTheSameArtist() {
        // Reached both ways: the alias must not silence the connection that
        // was actually worth offering.
        let kate = artist("Kate NV", id: 1, labels: ["RVNG Intl."])
        kate.aliasNames = ["Kate Shilonosova"]
        artist("Kate Shilonosova", id: 2, labels: ["RVNG Intl."])
        crate(artist: "Kate NV")

        // Still refused: the same person is the same person however many
        // reasons point at her.
        XCTAssertFalse(suggestions().contains { $0.node.title == "Kate Shilonosova" })
    }

    func testAPersonYouMadeARecordWithOutranksOneWhoMerelySoundsSimilar() {
        artist("Dean Blunt", id: 1, styles: ["Ambient"])
            .collaboratorNames = ["Tirzah"]
        artist("Tirzah", id: 2, styles: ["Ambient"])
        artist("Somebody Ambient", id: 3, styles: ["Ambient"])
        crate(artist: "Dean Blunt")

        let found = suggestions()
        let tirzah = found.firstIndex { $0.node.title == "Tirzah" }
        let similar = found.firstIndex { $0.node.title == "Somebody Ambient" }
        XCTAssertNotNil(tirzah)
        if let tirzah, let similar { XCTAssertLessThan(tirzah, similar) }
    }

    func testTwoRoutesToTheSamePlaceBeatOne() {
        // Every collaborator edge carries the same weight, so without this
        // a dozen of them tie and the order falls back on the alphabet — which
        // is how a real collection produced a list beginning Aksak Maboul,
        // Blue Foundation, Blue Iverson, Bottlesmoker.
        artist("Dean Blunt", id: 1).collaboratorNames = ["Tirzah"]
        artist("Kate NV", id: 2).collaboratorNames = ["Tirzah"]
        artist("Cokiyu", id: 3).collaboratorNames = ["Somebody Else"]
        artist("Tirzah", id: 4)
        artist("Somebody Else", id: 5)
        crate(artist: "Dean Blunt")
        crate(artist: "Kate NV")
        crate(artist: "Cokiyu")

        let found = suggestions()
        let tirzah = found.first { $0.node.title == "Tirzah" }
        XCTAssertEqual(tirzah?.corroboration, 2)
        XCTAssertEqual(found.first?.node.title, "Tirzah")
        // And it says so, because that is the strongest argument this engine
        // can make and hiding it would waste it.
        XCTAssertTrue(tirzah?.connection.contains("and 1 more") ?? false)
    }

    func testOneKindOfRouteDoesNotTakeTheWholeBlock() {
        // Collaboration is the most valuable route there is, which means that
        // left alone it takes every row — and the label and radio
        // neighbourhoods, the two things Indigo knows that a catalogue does
        // not, never appear at all.
        let origin = artist("Dean Blunt", id: 1, labels: ["World Music"])
        origin.collaboratorNames = (0..<10).map { "Collaborator \($0)" }
        for index in 0..<10 { artist("Collaborator \(index)", id: 100 + index) }
        for index in 0..<5 { artist("Labelmate \(index)", id: 200 + index, labels: ["World Music"]) }
        crate(artist: "Dean Blunt")

        let found = suggestions()
        let collaborators = found.filter { $0.kind == .collaborator }.count
        XCTAssertLessThanOrEqual(collaborators, ExploreSuggestionEngine.perKind)
        XCTAssertTrue(found.contains { $0.kind == .sharedLabel },
                      "the label neighbourhood has to get a row")
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
