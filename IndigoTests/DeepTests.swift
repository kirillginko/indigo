//
//  DeepTests.swift
//  IndigoTests
//
//  Phase 3C. What ↓ DEEPER promises: that pressing it takes the obvious
//  answers away rather than adding more of them, and that the deepest objects
//  in the graph — the white labels and the unnamed — are filed by what they
//  are rather than by which route happened to reach them.
//

import XCTest
import SwiftData
@testable import Indigo

final class DeepTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        store = RecordingStore(context: context)
    }

    override func tearDown() {
        store = nil
        context = nil
        container = nil
    }

    // MARK: Release kinds

    /// A catalogue built for albums throws these away. They are the point.
    func testTheObjectsACatalogueWouldRatherNotAdmitExist() {
        XCTAssertEqual(ReleaseClassifier.classify(title: "Untitled", notes: "White label, 300 copies"), .whiteLabel)
        XCTAssertEqual(ReleaseClassifier.classify(notes: "Dubplate cut at Transition"), .dubplate)
        XCTAssertEqual(ReleaseClassifier.classify(title: "ITLP09 (Test Pressing)"), .testPress)
        XCTAssertEqual(ReleaseClassifier.classify(title: "Compro (Promo)"), .promo)
        XCTAssertEqual(ReleaseClassifier.classify(releaseType: "Album"), .album)

        XCTAssertTrue(ReleaseKind.whiteLabel.isUnderground)
        XCTAssertTrue(ReleaseKind.dubplate.isUnderground)
        XCTAssertFalse(ReleaseKind.album.isUnderground)
        XCTAssertGreaterThan(ReleaseKind.dubplate.deepness, ReleaseKind.promo.deepness)
    }

    /// A record with no metadata is a valid record, not a broken one.
    func testARecordThatRefusesToExplainItselfIsStillARecord() {
        XCTAssertEqual(ReleaseClassifier.classify(title: "Untitled"), .unknown)
        XCTAssertTrue(ReleaseKind.unknown.isUnderground)
    }

    /// "ep" must not fire on "Deep Cuts", and "promo" must not fire on
    /// "Promotion" — but it must on "(Promo)".
    func testMarkersAreWholeWordsRatherThanSubstrings() {
        XCTAssertEqual(ReleaseClassifier.classify(title: "Deep Cuts"), .unknown)
        XCTAssertEqual(ReleaseClassifier.classify(title: "Sales Promotion"), .unknown)
        XCTAssertEqual(ReleaseClassifier.classify(title: "Rave (Promo)"), .promo)
    }

    // MARK: Obscurity

    /// Obscurity is not low popularity. It is how hard something is to arrive
    /// at by accident — so anything already in the listener's own world is,
    /// for them, not a discovery at all.
    func testWhatIsAlreadyYoursIsNotADiscovery() {
        var stranger = ObscuritySignals()
        stranger.knownReleases = 3
        stranger.labelCatalogueSize = 8
        stranger.releaseKind = .album

        var known = stranger
        known.libraryMatches = 12
        known.crateCount = 4

        XCTAssertGreaterThan(stranger.score, known.score)
    }

    func testTheDeepestThingIsTheThingNobodyHasNamed() {
        var named = ObscuritySignals()
        named.knownReleases = 2
        named.releaseKind = .single

        var unnamed = named
        unnamed.isUnidentified = true
        unnamed.releaseKind = .unknown

        XCTAssertGreaterThan(unnamed.score, named.score)
        XCTAssertLessThanOrEqual(unnamed.score, 1)
        XCTAssertGreaterThanOrEqual(named.score, 0)
    }

    func testASmallImprintIsADeeperFindThanALargeOne() {
        var small = ObscuritySignals()
        small.labelCatalogueSize = 6
        small.releaseKind = .album
        var large = small
        large.labelCatalogueSize = 600

        XCTAssertGreaterThan(small.score, large.score)
    }

    // MARK: Levels

    /// The whole promise of DEEPER: a candidate belongs to exactly one level,
    /// the shallowest that would have shown it, so going deeper cannot serve
    /// up what you already saw.
    func testACandidateBelongsToExactlyOneLevel() {
        var ordinary = ObscuritySignals()
        ordinary.libraryMatches = 5
        ordinary.knownReleases = 40
        ordinary.labelCatalogueSize = 400
        ordinary.releaseKind = .album

        let bothWays = [
            MusicEdge(from: .artist("A"), to: .artist("B"), kind: .sharedLabel,
                      source: .discogs, reason: "Same label", confidence: 0.8),
            MusicEdge(from: .artist("A"), to: .artist("B"), kind: .sharedBroadcast,
                      source: .radio, reason: "Same show", confidence: 0.7)
        ]

        XCTAssertEqual(
            DeepEngine.level(for: .artist("B"), edges: bothWays, signals: ordinary),
            .label,
            "Reachable two ways means reachable obviously — it files at the shallower one"
        )
    }

    /// What a thing is outranks how it was found. Filing a white label under
    /// RADIO because that is where you heard it buries the deepest object in
    /// the graph three levels early.
    func testAWhiteLabelHeardOnAirIsStillAWhiteLabel() {
        var pressing = ObscuritySignals()
        pressing.releaseKind = .whiteLabel
        let radioOnly = [
            MusicEdge(from: .artist("A"), to: .release("Untitled", discogsID: 9),
                      kind: .playedInShow, source: .radio,
                      reason: "Played on NTS", confidence: 0.7)
        ]

        XCTAssertEqual(
            DeepEngine.level(for: .release("Untitled", discogsID: 9), edges: radioOnly, signals: pressing),
            .underground
        )
    }

    func testMusicNobodyHasNamedGoesToTheBottom() throws {
        let unknown = try store.createUnknown(
            providerID: "nts", showID: "ben-ufo/2026-08-28",
            heardAt: Date(), offsetSeconds: 330
        )
        let node = MusicNode.recording(unknown)
        var signals = ObscuritySignals()
        signals.isUnidentified = true

        XCTAssertEqual(
            DeepEngine.level(for: node, edges: [
                MusicEdge(from: .artist("A"), to: node, kind: .sharedBroadcast,
                          source: .radio, reason: "Same show", confidence: 0.7)
            ], signals: signals),
            .unknown
        )
    }

    func testAnAliasIsAsSurfaceAsItGets() {
        var ordinary = ObscuritySignals()
        ordinary.libraryMatches = 3
        ordinary.knownReleases = 30
        ordinary.labelCatalogueSize = 200
        ordinary.releaseKind = .album

        XCTAssertEqual(
            DeepEngine.level(for: .artist("DJ Metatron"), edges: [
                MusicEdge(from: .artist("Traumprinz"), to: .artist("DJ Metatron"),
                          kind: .sameAlias, source: .discogs,
                          reason: "Also records as Traumprinz", confidence: 0.95)
            ], signals: ordinary),
            .surface
        )
    }

    // MARK: Walking down

    /// Pressing DEEPER onto an empty page is how a discovery tool loses
    /// somebody's trust, so it skips levels that have nothing in them.
    func testDeeperSkipsLevelsWithNothingInThem() throws {
        let skeeMask = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                     discogsID: 1, name: "Skee Mask")
        skeeMask.aliasNames = ["SCNTST"]
        context.insert(skeeMask)
        context.insert(DiscogsArtist(nameKey: RecordingKey.normalizeArtist("SCNTST"),
                                     discogsID: 2, name: "SCNTST"))

        let engine = DeepEngine(context: context)
        let origin = MusicNode.artist("Skee Mask")
        let levels = Set(engine.results(from: origin).map(\.level))

        XCTAssertTrue(levels.contains(.surface), "The alias is a surface connection")
        let next = engine.nextLevel(from: origin, after: .surface)
        XCTAssertNotEqual(next, .label, "There are no label connections to offer")
        if let next { XCTAssertTrue(levels.contains(next)) }
    }

    /// Inside a level the least reachable thing comes first — that is what
    /// makes the page worth reading top-down.
    func testTheLeastReachableThingIsAtTheTop() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        store.note(appearance: MediaAppearance(
            providerID: "nts", showTitle: "Ben UFO", showID: "ben-ufo/1",
            heardAt: Date(), offsetSeconds: 100, isLive: false, method: .providerTracklist
        ), on: recording)

        let unknown = try store.createUnknown(
            providerID: "nts", showID: "ben-ufo/1", heardAt: Date(), offsetSeconds: 130
        )
        store.note(appearance: MediaAppearance(
            providerID: "nts", showTitle: "Ben UFO", showID: "ben-ufo/1",
            heardAt: Date(), offsetSeconds: 130, isLive: false, method: .none
        ), on: unknown)

        let show = MusicNode.broadcast(providerID: "nts", showID: "ben-ufo/1", title: "Ben UFO")
        let deepest = DeepEngine(context: context).results(from: show, at: .unknown)

        XCTAssertEqual(deepest.map(\.node.recordingID), [unknown.id],
                       "The unnamed recording, and only it, is at the bottom level")
        XCTAssertNotNil(deepest.first?.why, "Even the deepest result has to say why")
    }
}

// MARK: - Co-appearance

/// Tracking which shows two records turned up in together — the part no
/// catalogue holds, and the route the Crate now opens onto.
final class CoAppearanceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        store = RecordingStore(context: context)
    }

    override func tearDown() {
        store = nil
        context = nil
        container = nil
    }

    private func heard(_ recording: Recording, show: String, offset: Double) {
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: show, showID: show,
            heardAt: Date(timeIntervalSince1970: 1_788_000_000 + offset),
            offsetSeconds: offset, isLive: false, method: .providerTracklist
        ), on: recording)
    }

    /// Two records that keep turning up in the same hours are connected by
    /// whoever kept putting them there. Counting it is what separates a scene
    /// from a coincidence.
    func testRecordsAreLinkedByTheShowsTheyShared() throws {
        let subject = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let travelling = try store.upsert(title: "Consumer's Tool", artistName: "Stenny")
        let once = try store.upsert(title: "Passing Through", artistName: "Someone")

        for index in 0..<4 {
            heard(subject, show: "show-\(index)", offset: 100)
            heard(travelling, show: "show-\(index)", offset: 400)
        }
        heard(once, show: "show-0", offset: 900)

        let graph = RadioNeighborhoodEngine(context: context).graph(around: subject)
        let peers = graph.connections(from: .recording(subject))
            .filter { $0.to.kind == .recording || $0.to.kind == .unknownRecording }

        let stenny = try XCTUnwrap(peers.first { $0.to.recordingID == travelling.id })
        let passerby = try XCTUnwrap(peers.first { $0.to.recordingID == once.id })

        XCTAssertGreaterThan(stenny.confidence, passerby.confidence,
                             "Four shared hours outrank one")
        XCTAssertEqual(
            stenny.reasons.first { $0.kind == .sharedBroadcast }?.detail,
            "Played in 4 of the same radio shows"
        )
    }

    /// A recording opens onto its own page rather than straight to its artist:
    /// where it was played, and what was played beside it, is the route
    /// onward — and the artist is still one step from there.
    @MainActor
    func testMusicHeardOnAirOpensOntoItsOwnPage() throws {
        let heardOnAir = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        heard(heardOnAir, show: "ben-ufo/1", offset: 100)
        let neverHeard = try store.upsert(title: "Quiet One", artistName: "Skee Mask")

        let dig = DigStore(context: context)
        XCTAssertEqual(dig.recordingDestination(for: heardOnAir),
                       .digRecording(id: heardOnAir.id, title: "Rev8617"))
        XCTAssertEqual(dig.recordingDestination(for: neverHeard),
                       .digArtist(mbid: nil, name: "Skee Mask"),
                       "Nothing heard means nothing to show; the artist is the page")
        XCTAssertEqual(dig.destination(for: heardOnAir),
                       .digArtist(mbid: nil, name: "Skee Mask"),
                       "DIG still means dig into the artist")
    }

    /// Every appearance has to lead back to the hour it happened in.
    func testAnAppearanceLeadsBackToTheBroadcast() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        store.note(appearance: MediaAppearance(
            providerID: "nts", showTitle: "Ben UFO", showID: "ben-ufo/2026-08-28",
            heardAt: Date(), offsetSeconds: 300, isLive: false, method: .providerTracklist
        ), on: recording)

        let appearance = try XCTUnwrap(recording.appearances.first)
        XCTAssertEqual(
            BroadcastSource.destination(showID: try XCTUnwrap(appearance.showID),
                                        providerID: appearance.providerID),
            .ntsEpisode(show: "ben-ufo", episode: "2026-08-28")
        )
    }
}

/// A page must not announce "nothing at this depth" about a store nothing has
/// been fetched into yet.
final class DeepReadinessTests: XCTestCase {
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

    /// The walk over an empty store returns nothing, which is true and means
    /// nothing — the catalogues have not been asked yet.
    func testAnEmptyWalkIsNotAnEmptyAnswer() {
        let descent = DeepEngine(context: context).descent(from: .artist("Nobody"), at: .surface)
        XCTAssertTrue(descent.results.isEmpty)
        XCTAssertNil(descent.next, "And there is nowhere deeper to offer either")
    }

    /// Once something is actually known, the same walk has something to say.
    func testAWalkOverAStockedStoreAnswers() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        context.insert(subject)

        let peer = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Stenny"),
                                 discogsID: 2, name: "Stenny")
        peer.labelNames = ["Ilian Tape"]
        context.insert(peer)

        let descent = DeepEngine(context: context).descent(from: .artist("Skee Mask"), at: .label)
        XCTAssertTrue(descent.results.contains { $0.node.title == "Stenny" })
    }
}

// MARK: - Not a second copy of the page

/// The engine's own promise, applied to the thing the page is standing on.
/// DEEP is the graph with the obvious answers taken away, and the most obvious
/// answer of all is the one already printed six inches higher up.
extension DeepTests {
    private func pressing(
        _ title: String, id: Int, label: String, catalog: String
    ) -> DiscogsReleaseRecord {
        let record = DiscogsReleaseRecord(discogsID: id, title: title)
        record.labelNames = [label]
        record.catalogNumbers = [catalog]
        record.artistNames = ["Skee Mask"]
        context.insert(record)
        return record
    }

    /// The complaint exactly: a release's descent opened on the label and the
    /// catalogue number printed directly above it.
    func testAReleaseDescentDoesNotRepeatTheReleasePage() {
        pressing("Compro", id: 12_345, label: "Ilian Tape", catalog: "ITLP09")
        let origin = MusicNode.release("Compro", discogsID: 12_345)
        let engine = DeepEngine(context: context)

        let everything = Set(engine.results(from: origin).map(\.node.id))
        XCTAssertTrue(everything.contains(MusicNode.label("Ilian Tape").id),
                      "The walk still knows the label")

        // What the page has already drawn: its label, its number, its artist.
        let shown: Set<String> = [
            MusicNode.label("Ilian Tape").id,
            MusicNode.catalogNumber("ITLP09").id,
            MusicNode.artist("Skee Mask").id
        ]
        let left = Set(engine.results(from: origin, showing: shown).map(\.node.id))

        XCTAssertTrue(left.isDisjoint(with: shown),
                      "Nothing the reader has just read comes back as a discovery")
    }

    /// Taking the page's contents out must not leave DEEPER as a button you
    /// press through empty levels to reach the first real row.
    func testADescentSettlesOnALevelThatHasSomething() {
        pressing("Compro", id: 12_345, label: "Ilian Tape", catalog: "ITLP09")
        let origin = MusicNode.release("Compro", discogsID: 12_345)
        let engine = DeepEngine(context: context)

        // Empty the surface by declaring everything on it already shown.
        let surface = Set(
            engine.results(from: origin).filter { $0.level == .surface }.map(\.node.id)
        )
        XCTAssertFalse(surface.isEmpty, "The surface had something to empty")

        let descent = engine.descent(from: origin, at: .surface, showing: surface)

        XCTAssertNotEqual(descent.level, .surface, "It did not stop on the level it emptied")
        XCTAssertFalse(descent.results.isEmpty, "And it landed somewhere with rows in it")
    }

    /// Levels accumulate, so the walk must never hand back a level that is
    /// already on the page — a rebuild after a write would print its rows
    /// twice.
    func testASettledLevelIsTheOneItSaysItIs() {
        pressing("Compro", id: 12_345, label: "Ilian Tape", catalog: "ITLP09")
        let origin = MusicNode.release("Compro", discogsID: 12_345)
        let engine = DeepEngine(context: context)

        let surface = Set(
            engine.results(from: origin).filter { $0.level == .surface }.map(\.node.id)
        )
        let descent = engine.descent(from: origin, at: .surface, showing: surface)

        XCTAssertTrue(
            descent.results.allSatisfy { $0.level == descent.level },
            "Every row belongs to the level the descent claims to be at"
        )
        XCTAssertNotEqual(descent.next, descent.level, "DEEPER never re-offers where you are")
    }
}
