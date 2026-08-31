//
//  CatalogTests.swift
//  IndigoTests
//
//  Phase 3D. A catalogue number is a position in a run, not a field on a
//  release — and reading along the run is how a pressing nobody wrote about
//  gets found. What is pinned here is that the run is navigable, that it stops
//  at the edge of the label's own numbering, and that the deep end of a
//  catalogue is reachable.
//

import XCTest
import SwiftData
@testable import Indigo

final class CatalogTests: XCTestCase {
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
    private func release(
        _ title: String, id: Int, label: String, catalog: String, notes: String? = nil
    ) -> DiscogsReleaseRecord {
        let record = DiscogsReleaseRecord(discogsID: id, title: title)
        record.labelNames = [label]
        record.catalogNumbers = [catalog]
        record.notes = notes
        context.insert(record)
        return record
    }

    /// A search box cannot do this, because you would have to already know
    /// what you were looking for.
    func testACatalogueNumberLeadsToItsNeighboursOnTheShelf() throws {
        release("Eight", id: 1, label: "Ilian Tape", catalog: "ITLP08")
        release("Nine", id: 2, label: "Ilian Tape", catalog: "ITLP09")
        release("Ten", id: 3, label: "Ilian Tape", catalog: "ITLP10")
        release("Far Off", id: 4, label: "Ilian Tape", catalog: "ITLP44")
        release("Elsewhere", id: 5, label: "Hyperdub", catalog: "HDB09")

        let reached = DigEngine(context: context).connections(from: .catalogNumber("ITLP09"))
        let titles = Set(reached.map(\.to.title))

        XCTAssertTrue(titles.contains("Nine"), "The record the number names")
        XCTAssertTrue(titles.isSuperset(of: ["Eight", "Ten"]))
        XCTAssertFalse(titles.contains("Far Off"), "Thirty-five along is not a neighbour")
        XCTAssertFalse(titles.contains("Elsewhere"), "A different prefix is a different shelf")
    }

    /// The record the number actually names has to be distinguishable from
    /// the ones merely near it, or the page cannot tell you what you opened.
    func testThePressingItselfIsMarkedApartFromItsNeighbours() throws {
        release("Nine", id: 2, label: "Ilian Tape", catalog: "ITLP09")
        release("Ten", id: 3, label: "Ilian Tape", catalog: "ITLP10")

        let reached = DigEngine(context: context).connections(from: .catalogNumber("ITLP09"))
        let itself = try XCTUnwrap(reached.first { $0.to.title == "Nine" })
        let neighbour = try XCTUnwrap(reached.first { $0.to.title == "Ten" })

        XCTAssertTrue(itself.reasons.contains { $0.kind == .sameRelease })
        XCTAssertFalse(neighbour.reasons.contains { $0.kind == .sameRelease })
        XCTAssertGreaterThan(itself.confidence, neighbour.confidence)
    }

    func testHowPeopleWriteANumberDoesNotChangeWhichShelfItIsOn() throws {
        release("Nine", id: 2, label: "Ilian Tape", catalog: "IT 001")

        let spaced = DigEngine(context: context).connections(from: .catalogNumber("IT-001"))
        XCTAssertTrue(spaced.contains { $0.to.title == "Nine" })
        XCTAssertEqual(MusicNode.catalogNumber("IT 001").destination,
                       .digCatalog(number: "IT 001"))
    }

    /// The spec's DEEP CUTS: the end of a catalogue nobody arrives at by
    /// accident.
    func testALabelsDeepEndIsReachable() throws {
        release("Ordinary Album", id: 1, label: "Ilian Tape", catalog: "ITLP01")
        release("Untitled", id: 2, label: "Ilian Tape", catalog: "ITX003",
                notes: "White label, 200 copies")

        let cuts = DeepEngine(context: context)
            .results(from: .label("Ilian Tape"), at: .underground)

        XCTAssertTrue(cuts.contains { $0.node.title == "Untitled" })
        XCTAssertEqual(cuts.first { $0.node.title == "Untitled" }?.signals.releaseKind, .whiteLabel)
        XCTAssertFalse(cuts.contains { $0.node.title == "Ordinary Album" },
                       "An album on the same label is not a deep cut")
    }

    /// A label's catalogue numbers are its spine, and every one of them has to
    /// be somewhere you can go.
    func testALabelOffersItsWholeRun() throws {
        release("One", id: 1, label: "Ilian Tape", catalog: "ITLP01")
        release("Two", id: 2, label: "Ilian Tape", catalog: "ITLP02")

        let numbers = DigEngine(context: context)
            .connections(from: .label("Ilian Tape"))
            .filter { $0.to.kind == .catalogNumber }

        XCTAssertEqual(Set(numbers.map(\.to.title)), ["ITLP01", "ITLP02"])
        XCTAssertTrue(numbers.allSatisfy { $0.to.destination != nil },
                      "A number nobody can open is a number nobody can follow")
    }
}
