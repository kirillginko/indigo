//
//  DigHistoryTests.swift
//  IndigoTests
//
//  Phase 3F. DIG learns from this listener's own history before anybody
//  else's. What is pinned here is the part that decides whether that is
//  useful or merely flattering: a suggestion has to be somewhere they have
//  not already been.
//

import XCTest
import SwiftData
@testable import Indigo

final class DigHistoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var history: DigHistory!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        history = DigHistory(context: context)
    }

    override func tearDown() {
        history = nil
        context = nil
        container = nil
    }

    @discardableResult
    private func artist(_ name: String, id: Int, labels: [String] = [], styles: [String] = []) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
        record.labelNames = labels
        record.styles = styles
        context.insert(record)
        return record
    }

    // MARK: Recording

    func testOpeningSomethingTwiceIsOneRowAndTwoVisits() {
        let node = MusicNode.label("Ilian Tape")
        history.record(node)
        history.record(node)

        XCTAssertEqual(history.visits().count, 1)
        XCTAssertEqual(history.visit(for: node)?.visits, 2)
    }

    /// Arriving from outside a dig — off the Crate, out of a search — is a
    /// visit but not a step. Counting it as one invents a path nobody walked.
    func testArrivingFromNowhereIsNotAStep() {
        history.record(.label("Ilian Tape"))
        XCTAssertTrue(history.steps().isEmpty)

        history.record(.artist("Stenny"), from: .label("Ilian Tape"))
        XCTAssertEqual(history.steps().count, 1)
        XCTAssertEqual(history.steps().first?.count, 1)
    }

    /// "Ilian Tape → Stenny" is the line the home page shows, and it has to be
    /// the step they actually keep taking rather than the last one they took.
    func testTheUsualNextStepIsTheOneMostOftenTaken() {
        let label = MusicNode.label("Ilian Tape")
        for _ in 0..<3 { history.record(.artist("Stenny"), from: label) }
        history.record(.artist("Andrea"), from: label)

        XCTAssertEqual(history.usualNextStep(from: label)?.title, "Stenny")
    }

    /// Opening something once is curiosity. Opening it a fourth time is how
    /// they listen — and a list of one-offs would crowd out the difference.
    func testWhatTheyKeepReturningToIsNotWhatTheyGlancedAt() {
        for _ in 0..<4 { history.record(.label("Ilian Tape")) }
        for _ in 0..<2 { history.record(.label("Hyperdub")) }
        history.record(.label("Seen Once"))

        XCTAssertEqual(history.haunts().map(\.title), ["Ilian Tape", "Hyperdub"])
    }

    func testHistoryCanBeThrownAway() {
        history.record(.artist("Stenny"), from: .label("Ilian Tape"))
        history.forget()

        XCTAssertTrue(history.visits().isEmpty)
        XCTAssertTrue(history.steps().isEmpty)
    }

    // MARK: Suggestions

    /// The whole point. A suggestion they have already opened four times is
    /// not a suggestion, and leaving it in turns the list into a mirror.
    func testWhereTheyHaveAlreadyBeenIsNotASuggestion() throws {
        artist("Skee Mask", id: 1, labels: ["Ilian Tape"], styles: ["Techno"])
        artist("Stenny", id: 2, labels: ["Ilian Tape"], styles: ["Techno"])
        artist("Andrea", id: 3, labels: ["Ilian Tape"], styles: ["Techno"])

        for _ in 0..<3 { history.record(.artist("Skee Mask")) }
        for _ in 0..<2 { history.record(.artist("Stenny")) }

        let suggested = history.suggestions().map(\.node.title)
        XCTAssertTrue(suggested.contains("Andrea"))
        XCTAssertFalse(suggested.contains("Stenny"), "Already opened twice")
        XCTAssertFalse(suggested.contains("Skee Mask"), "And this is where they came from")
    }

    /// Every suggestion carries the place in their own history that argues
    /// for it — "via Ilian Tape" — because an unexplained one is exactly what
    /// the spec forbids.
    func testEverySuggestionSaysWhatItCameOutOf() throws {
        artist("Skee Mask", id: 1, labels: ["Ilian Tape"], styles: ["Techno"])
        artist("Andrea", id: 2, labels: ["Ilian Tape"], styles: ["Techno"])
        for _ in 0..<3 { history.record(.artist("Skee Mask")) }

        let suggestion = try XCTUnwrap(history.suggestions().first)
        XCTAssertEqual(suggestion.via.title, "Skee Mask")
        XCTAssertNotNil(suggestion.why)
        XCTAssertNotNil(suggestion.node.destination, "A suggestion nobody can open is not one")
    }

    /// Nothing visited more than once means nothing to reason from, and
    /// guessing anyway would be worse than saying nothing.
    func testNoHistoryMeansNoSuggestions() {
        artist("Skee Mask", id: 1, labels: ["Ilian Tape"])
        history.record(.artist("Skee Mask"))

        XCTAssertTrue(history.suggestions().isEmpty)
    }

    // MARK: Identity

    /// A page and the graph have to agree about what a thing is, or the same
    /// label ends up remembered as two.
    @MainActor
    func testAPageAndTheGraphAgreeOnIdentity() throws {
        let dig = DigStore(context: context)

        XCTAssertEqual(dig.node(for: .digLabel(mbid: "mb-1", name: "Ilian Tape"))?.id,
                       MusicNode.label("Ilian Tape", mbid: "mb-1").id)
        XCTAssertEqual(dig.node(for: .digDiscogsLabel(name: "Ilian Tape"))?.id,
                       MusicNode.label("Ilian Tape").id)
        XCTAssertEqual(dig.node(for: .digCatalog(number: "IT-001"))?.id,
                       MusicNode.catalogNumber("IT 001").id)
        XCTAssertNil(dig.node(for: .album("something")), "Not everything is part of the graph")
    }

    /// Identifying a track later must not leave its unknown past behind as a
    /// second remembered node.
    @MainActor
    func testARecordingIsRememberedAsTheGraphKnowsIt() throws {
        let store = RecordingStore(context: context)
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let dig = DigStore(context: context)

        XCTAssertEqual(
            dig.node(for: .digRecording(id: recording.id, title: "Rev8617"))?.id,
            MusicNode.recording(recording).id
        )
    }
}
