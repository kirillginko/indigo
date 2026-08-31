//
//  ArtistNameTests.swift
//  IndigoTests
//
//  "Various" is where a catalogue files a compilation, not a person. Treated
//  as an artist it is catastrophic for a graph: every compilation in existence
//  connects to every other one through it, and it becomes the best-connected
//  artist in music.
//

import XCTest
import SwiftData
@testable import Indigo

final class ArtistNameTests: XCTestCase {
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

    func testFilingConventionsAreNotPeople() {
        for name in ["Various", "various artists", "VARIOUS ARTISTS",
                     "Unknown Artist", "Unknown", "No Artist", "Not On Label", ""] {
            XCTAssertFalse(ArtistName.isRealArtist(name), name)
        }
        XCTAssertFalse(ArtistName.isRealArtist(nil))
    }

    /// Matched on the whole name, never as a prefix. Both of these are real
    /// and both would be lost to a looser rule.
    func testRealArtistsWhoseNamesStartThatWaySurvive() {
        XCTAssertTrue(ArtistName.isRealArtist("Various Production"))
        XCTAssertTrue(ArtistName.isRealArtist("Unknown Mortal Orchestra"))
        XCTAssertTrue(ArtistName.isRealArtist("Skee Mask"))
    }

    /// The bug as it appeared: "Various" listed under collaborators, offering
    /// to dig into nobody.
    func testAPlaceholderNeverReachesTheRelatedList() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Seefeel"),
                                    discogsID: 1, name: "Seefeel")
        subject.labelNames = ["Too Pure"]
        subject.collaboratorNames = ["Various", "Mark Clifford"]
        subject.labelNeighbourNames = ["Various Artists", "Stereolab"]
        context.insert(subject)

        let names = Set(DigEngine(context: context).relatedArtists(to: "Seefeel").map(\.name))
        XCTAssertFalse(names.contains("Various"))
        XCTAssertFalse(names.contains("Various Artists"))
        XCTAssertTrue(names.isSuperset(of: ["Mark Clifford", "Stereolab"]))
    }

    /// And it is not offered as somewhere to start, either.
    @MainActor
    func testAPlaceholderIsNotAStartingPoint() throws {
        let crate = CrateService(context: context)
        let store = RecordingStore(context: context)
        let compilation = try store.upsert(title: "Track One", artistName: "Various")
        let real = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        crate.add(recording: compilation)
        crate.add(recording: real)

        let crated = ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? [])
            .compactMap { $0.recording?.artistName }
            .filter { ArtistName.isRealArtist($0) }
        XCTAssertEqual(crated, ["Skee Mask"])
    }

    /// A record with no catalogue entry is still a record, and clicking its
    /// tile has to land somewhere. It used to resolve first and go nowhere at
    /// all when the search came back empty — so the obscure ones were the only
    /// ones that did nothing.
    func testARecordWithNoCatalogueEntryStillHasAPage() {
        let page = DetailPage.digReleaseNamed(title: "Untitled", artist: "Seefeel")
        XCTAssertEqual(page, .digReleaseNamed(title: "Untitled", artist: "Seefeel"))
        XCTAssertNotEqual(page, .digReleaseNamed(title: "Untitled", artist: "Somebody Else"))
    }

    /// The other half of the rule. "Various" is not a person, but a record
    /// credited to it is a perfectly good record — a compilation — and that
    /// is the most informative thing available about what kind it is.
    func testARecordCreditedToNobodyIsACompilation() {
        XCTAssertEqual(
            ReleaseClassifier.classify(title: "Warp10", artistNames: ["Various"]),
            .compilation
        )
        XCTAssertEqual(
            ReleaseClassifier.classify(title: "Compro", artistNames: ["Skee Mask"]),
            .unknown,
            "A real credit says nothing about the format on its own"
        )
        XCTAssertEqual(
            ReleaseClassifier.classify(title: "Split", artistNames: ["Various", "Skee Mask"]),
            .unknown,
            "One real name among them means it is not filed under nobody"
        )
    }

    /// A compilation is the place several artists appear together, so the
    /// names worth offering are the ones on the tracks — not the credit,
    /// which is nobody.
    func testACompilationOffersTheArtistsOnIt() throws {
        let record = DiscogsReleaseRecord(discogsID: 10, title: "Warp10")
        record.artistNames = ["Various"]
        record.trackTitles = ["One", "Two", "Three"]
        record.trackPositions = ["A1", "A2", "B1"]
        record.trackArtists = ["Autechre", "Boards of Canada", "Autechre"]
        context.insert(record)

        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 10))
        XCTAssertEqual(profile.artists, ["Various"], "The credit is kept as stated")
        XCTAssertEqual(profile.tracks.compactMap(\.artist),
                       ["Autechre", "Boards of Canada", "Autechre"])

        // And none of them becomes an edge to nobody.
        let reached = DigEngine(context: context)
            .connections(from: .release("Warp10", discogsID: 10))
        XCTAssertFalse(reached.contains { $0.to.kind == .artist && $0.to.title == "Various" })
    }
}

// MARK: - Labels that are not labels

/// Discogs files a self-released record under "Not On Label", usually with
/// whose self-release it was in brackets. Treated as an imprint it does what
/// "Various" does to artists: every self-released record becomes a labelmate
/// of every other, and the app explains that two strangers are connected
/// because both are on Not On Label.
final class LabelNameTests: XCTestCase {
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

    func testTheAbsenceOfALabelIsNotOne() {
        for name in ["Not On Label", "not on label",
                     "Not On Label (Seefeel Self-Released)",
                     "Unknown Label", "No Label", "Self Released", ""] {
            XCTAssertFalse(LabelName.isRealLabel(name), name)
        }
        XCTAssertFalse(LabelName.isRealLabel(nil))
    }

    func testRealImprintsSurvive() {
        for name in ["Warp Records", "Ilian Tape", "Too Pure", "Label", "On-U Sound"] {
            XCTAssertTrue(LabelName.isRealLabel(name), name)
        }
    }

    /// The bug as it appeared: two artists said to be connected because
    /// neither of them was on a label.
    func testSelfReleasedArtistsAreNotLabelmates() throws {
        for name in ["Seefeel", "Somebody Else"] {
            let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name),
                                       discogsID: name.count, name: name)
            artist.labelNames = ["Not On Label (\(name) Self-Released)"]
            artist.styles = ["Ambient"]
            context.insert(artist)
        }

        let related = DigEngine(context: context).relatedArtists(to: "Seefeel")
        let peer = related.first { $0.name == "Somebody Else" }
        XCTAssertFalse(
            peer?.reasons.contains { $0.kind == .sharedLabel } ?? false,
            "Being self-released is a real fact, and not a shared one"
        )
    }

    /// And it is not offered as somewhere to dig into.
    func testTheAbsenceOfALabelIsNotAPlaceToGo() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Seefeel"),
                                   discogsID: 1, name: "Seefeel")
        artist.labelNames = ["Not On Label (Seefeel Self-Released)", "Too Pure"]
        context.insert(artist)

        let labels = DigEngine(context: context).artistProfile(name: "Seefeel", mbid: nil).labels
        XCTAssertEqual(labels.map(\.name), ["Too Pure"])
    }
}
