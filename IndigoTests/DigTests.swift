//
//  DigTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on musicbrainz.org/ws/2. The transport
//  is stubbed throughout: hammering a volunteer-run database from a test suite
//  would be rude as well as slow.
//

import XCTest
import SwiftData
@testable import Indigo

private struct StubTransport: MusicBrainzTransport {
    /// Matched against the request path+query, longest key first.
    let routes: [String: String]
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        var requestedURLs: [String] = []
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        recorder.requestedURLs.append(url)
        let hit = routes.keys
            .filter { url.contains($0) }
            .max { $0.count < $1.count }
        guard let hit, let body = routes[hit] else {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!)
    }
}

final class DigTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: RecordingStore!
    private var recorder: StubTransport.Recorder!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        store = RecordingStore(context: context)
        recorder = StubTransport.Recorder()
    }

    override func tearDown() {
        recorder = nil; store = nil; context = nil; container = nil
    }

    // MARK: Phase 3 graph

    func testMusicGraphCombinesExplainableEvidenceWithoutExceedingCertainty() {
        var graph = MusicGraph()
        let source = MusicNode.artist("Skee Mask")
        let destination = MusicNode.artist("Stenny")
        graph.connect(
            from: source, to: destination,
            reason: Relationship(kind: .sharedLabel, source: .discogs,
                                 detail: "Both release on Ilian Tape", confidence: 0.72)
        )
        graph.connect(
            from: source, to: destination,
            reason: Relationship(kind: .sharedBroadcast, source: .radio,
                                 detail: "Played in 4 of the same shows", confidence: 0.58)
        )

        let edge = graph.connections(from: source).first
        XCTAssertEqual(edge?.reasons.count, 2)
        XCTAssertEqual(edge?.confidence ?? 0, 0.8824, accuracy: 0.0001)
        XCTAssertEqual(edge?.confidenceBand, .high)
        XCTAssertEqual(edge?.primaryReason?.kind, .sharedLabel)
    }

    func testMusicGraphDeduplicatesRepeatedReasons() {
        var graph = MusicGraph()
        let source = MusicNode.label("Ilian Tape")
        let destination = MusicNode.catalogNumber("IT 001")
        let reason = Relationship(kind: .appearsOnRelease, source: .discogs,
                                  detail: "Catalogue entry IT001", confidence: 0.95)

        graph.connect(from: source, to: destination, reason: reason)
        graph.connect(from: source, to: destination, reason: reason)

        XCTAssertEqual(graph.connections(from: source).first?.reasons, [reason])
        XCTAssertEqual(destination.key, MusicNode.catalogNumber("IT-001").key)
    }

    func testRadioNeighborhoodIncludesShowsSelectorsAndImmediateUnknowns() throws {
        let subject = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let neighbor = try store.createUnknown(
            providerID: "nts", showID: "ben-ufo/2026-08-28",
            heardAt: Date(timeIntervalSince1970: 1_788_000_300), offsetSeconds: 330
        )
        let distant = try store.upsert(title: "Distant Track", artistName: "Someone Else")
        let showDate = Date(timeIntervalSince1970: 1_788_000_000)

        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
            showID: "ben-ufo/2026-08-28", heardAt: showDate,
            offsetSeconds: 300, isLive: false, method: .providerTracklist
        ), on: subject)
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
            showID: "ben-ufo/2026-08-28", heardAt: showDate.addingTimeInterval(30),
            offsetSeconds: 330, isLive: false, method: .none
        ), on: neighbor)
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
            showID: "ben-ufo/2026-08-28", heardAt: showDate.addingTimeInterval(900),
            offsetSeconds: 1_200, isLive: false, method: .providerTracklist
        ), on: distant)

        let edges = RadioNeighborhoodEngine(context: context).graph(around: subject)
            .connections(from: MusicNode.recording(subject))

        XCTAssertTrue(edges.contains { $0.to.kind == .broadcast })
        XCTAssertTrue(edges.contains { $0.to.kind == .selector && $0.to.title == "Ben UFO" })
        let unknown = try XCTUnwrap(edges.first { $0.to.recordingID == neighbor.id })
        XCTAssertTrue(unknown.reasons.contains { $0.kind == .sharedBroadcast })
        XCTAssertTrue(unknown.reasons.contains { $0.kind == .frequentlyPlayedNearby })
        XCTAssertFalse(edges.first { $0.to.recordingID == distant.id }?.reasons.contains {
            $0.kind == .frequentlyPlayedNearby
        } ?? true)
    }

    func testRepeatedRadioCoAppearancesReinforceOneExplainedEdge() throws {
        let subject = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let peer = try store.upsert(title: "Consumer's Tool", artistName: "Stenny")

        for index in 0..<3 {
            let show = "show/\(index)"
            store.note(appearance: MediaAppearance(
                providerID: "nts", showTitle: "Selector \(index)", showID: show,
                heardAt: Date().addingTimeInterval(Double(index)), offsetSeconds: 100,
                isLive: false, method: .providerTracklist
            ), on: subject)
            store.note(appearance: MediaAppearance(
                providerID: "nts", showTitle: "Selector \(index)", showID: show,
                heardAt: Date().addingTimeInterval(Double(index + 10)), offsetSeconds: 200,
                isLive: false, method: .providerTracklist
            ), on: peer)
        }

        let edge = RadioNeighborhoodEngine(context: context).graph(around: subject)
            .connections(from: MusicNode.recording(subject))
            .first { $0.to.recordingID == peer.id }

        XCTAssertEqual(edge?.reasons.first { $0.kind == .sharedBroadcast }?.detail,
                       "Played in 3 of the same radio shows")
        XCTAssertEqual(edge?.confidenceBand, .high)
    }

    func testNTSTracklistIngestionCreatesReusableRadioProvenance() throws {
        let detail = NTSEpisodeDetail(
            summary: NTSEpisodeSummary(
                showAlias: "ben-ufo", episodeAlias: "2026-08-28",
                name: "Ben UFO", summary: nil, location: nil,
                genres: [], moods: [], artworkURL: nil,
                broadcastAt: Date(timeIntervalSince1970: 1_788_000_000), isPublished: true
            ),
            tracklist: [
                NTSTracklistEntry(id: "one", artist: "Skee Mask", title: "Rev8617", offset: 300),
                NTSTracklistEntry(id: "two", artist: "Stenny", title: "Consumer's Tool", offset: 420)
            ],
            audio: []
        )
        let engine = RadioNeighborhoodEngine(context: context)

        engine.ingest(detail)
        engine.ingest(detail)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(recordings.count, 2)
        XCTAssertEqual(recordings.flatMap(\.appearances).count, 2,
                       "Reloading a tracklist must not duplicate its appearances")
        XCTAssertTrue(recordings.allSatisfy {
            $0.appearances.first?.method == .providerTracklist
                && $0.appearances.first?.showID == "ben-ufo/2026-08-28"
        })
    }

    // MARK: Fixtures

    private let recordingSearch = """
    {"count":1,"recordings":[{"id":"fae2e027-7f02-4269-9d9e-7ee88f8effb6","score":100,
      "title":"Rev8617","length":224000,"isrcs":["DEUM71800123"],
      "artist-credit":[{"name":"Skee Mask","artist":{"id":"2b3e25ba-983e-44ac-9def-907e03910cd2",
        "name":"Skee Mask","sort-name":"Skee Mask","disambiguation":"German DJ & producer"}}],
      "releases":[{"id":"6fb3ee64-36d4-4b7f-874f-53e40085bd6a","title":"Compro","date":"2018-05-15",
        "release-group":{"id":"557f","title":"Compro","primary-type":"Album"}}]}]}
    """

    /// The live shape my stubs originally missed: the earliest pressing often
    /// carries no label at all, and the next one does.
    private let recordingSearchTwoPressings = """
    {"count":1,"recordings":[{"id":"fae2e027","score":100,"title":"Rev8617","length":224000,
      "artist-credit":[{"artist":{"id":"2b3e25ba-983e-44ac-9def-907e03910cd2","name":"Skee Mask"}}],
      "releases":[
        {"id":"nolabel-release","title":"Compro","date":"2018-05-15"},
        {"id":"6fb3ee64-36d4-4b7f-874f-53e40085bd6a","title":"Compro","date":"2018-11-30"}]}]}
    """

    private let releaseWithoutLabel = """
    {"id":"nolabel-release","title":"Compro","date":"2018-05-15","label-info":[]}
    """

    private let release = """
    {"id":"6fb3ee64-36d4-4b7f-874f-53e40085bd6a","title":"Compro","date":"2018-05-15","country":"DE",
     "label-info":[{"catalog-number":"ITLP04","label":{"id":"cb0e0976-5f14-46ea-b5b7-796f32985439",
       "name":"Ilian Tape"}}],
     "release-group":{"id":"557f","title":"Compro","primary-type":"Album"}}
    """

    private let artist = """
    {"id":"2b3e25ba-983e-44ac-9def-907e03910cd2","name":"Skee Mask","sort-name":"Skee Mask",
     "type":"Person","disambiguation":"German DJ & producer",
     "area":{"name":"Germany"},"begin-area":{"name":"Munich"},
     "release-groups":[
       {"id":"a","title":"Compro","primary-type":"Album","first-release-date":"2018-05-15"},
       {"id":"b","title":"Pool","primary-type":"Album","first-release-date":"2021-05-07"},
       {"id":"c","title":"Shred","primary-type":"Album","first-release-date":"2016-02-01"}]}
    """

    private let label = """
    {"id":"cb0e0976-5f14-46ea-b5b7-796f32985439","name":"Ilian Tape","type":"Original Production",
     "area":{"name":"München"},"life-span":{"begin":"2007"}}
    """

    private let labelReleases = """
    {"release-count":279,"releases":[
      {"id":"r1","title":"Compro","date":"2018-05-15","artist-credit":[{"artist":{"id":"2b3e25ba-983e-44ac-9def-907e03910cd2","name":"Skee Mask"}}]},
      {"id":"r2","title":"Pool","date":"2021-05-07","artist-credit":[{"artist":{"id":"2b3e25ba-983e-44ac-9def-907e03910cd2","name":"Skee Mask"}}]},
      {"id":"r3","title":"Ritmo Hoje","date":"2019-01-01","artist-credit":[{"artist":{"id":"andrea-id","name":"Andrea"}}]},
      {"id":"r4","title":"Upsurge","date":"2020-01-01","artist-credit":[{"artist":{"id":"stenny-id","name":"Stenny"}}]},
      {"id":"r5","title":"Immersion","date":"2017-01-01","artist-credit":[{"artist":{"id":"zenker-id","name":"Zenker Brothers"}}]},
      {"id":"r6","title":"ISS004","date":"2019-10-21","artist-credit":[{"artist":{"id":"va","name":"Various Artists"}}]}]}
    """

    private let artistSearch = """
    {"count":1,"artists":[{"id":"b794b18d-5d40-46cc-9a55-4dd15ac37e30","name":"Kelly Moran",
      "score":100,"disambiguation":"keyboardist and composer","type":"Person",
      "area":{"name":"Brooklyn"},"country":"US"}]}
    """

    private let artistReleaseGroups = """
    {"release-group-count":3,"release-groups":[
      {"id":"g1","title":"Ultraviolet","primary-type":"Album","first-release-date":"2018-11-02"},
      {"id":"g2","title":"Bloodroot","primary-type":"Album","first-release-date":"2017-03-24"},
      {"id":"g3","title":"Origin","primary-type":"EP","first-release-date":"2020-09-25"},
      {"id":"g4","title":"A Compilation","primary-type":"Compilation","first-release-date":"2021-01-01"}]}
    """

    private func makeNameClient() -> MusicBrainzClient {
        MusicBrainzClient(transport: StubTransport(routes: [
            "ws/2/artist?": artistSearch,
            "ws/2/release-group?": artistReleaseGroups
        ], recorder: recorder))
    }

    private func makeClient() -> MusicBrainzClient {
        MusicBrainzClient(transport: StubTransport(routes: [
            "ws/2/recording?": recordingSearch,
            "ws/2/release/6fb3ee64": release,
            "ws/2/artist/2b3e25ba": artist,
            "ws/2/label/cb0e0976": label,
            "ws/2/release?label=": labelReleases
        ], recorder: recorder))
    }

    /// A transient throttle must never be recorded as "this release has no
    /// label" — that answer would be cached as fact and never retried.
    func testAThrottledLabelLookupFailsLoudlyRatherThanCachingAGuess() async throws {
        struct ThrottleAfterFirst: MusicBrainzTransport {
            let search: String
            let recorder: Recorder
            final class Recorder: @unchecked Sendable { var count = 0 }

            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                recorder.count += 1
                let url = request.url!
                if recorder.count == 1 {
                    return (Data(search.utf8),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                throw URLError(.timedOut)
            }
        }

        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let client = MusicBrainzClient(
            transport: ThrottleAfterFirst(search: recordingSearch, recorder: .init())
        )
        let enricher = MusicBrainzEnricher(context: context, client: client)

        do {
            _ = try await enricher.enrich(recording)
            XCTFail("A throttled release lookup must surface, not be swallowed")
        } catch let error as MusicBrainzError {
            XCTAssertEqual(error, .rateLimited, "A hung request is a throttle, not a dead connection")
        }

        let cached = enricher.metadata(for: recording.id)
        XCTAssertNil(cached?.labelName, "Nothing should have been recorded as the label")
    }

    /// The bug the stubs hid: giving up after one pressing left the label —
    /// the edge DIG leans on hardest — permanently empty.
    func testLabelIsFoundOnALaterPressingWhenTheFirstHasNone() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let client = MusicBrainzClient(transport: StubTransport(routes: [
            "ws/2/recording?": recordingSearchTwoPressings,
            "ws/2/release/nolabel-release": releaseWithoutLabel,
            "ws/2/release/6fb3ee64": release
        ], recorder: recorder))

        let metadata = try await MusicBrainzEnricher(context: context, client: client).enrich(recording)

        XCTAssertEqual(metadata?.labelName, "Ilian Tape")
        XCTAssertEqual(metadata?.catalogNumber, "ITLP04")
        XCTAssertEqual(metadata?.releaseMBID, "6fb3ee64-36d4-4b7f-874f-53e40085bd6a",
                       "The pressing that named a label is the one worth showing")
    }

    // MARK: Client

    /// Lucene treats punctuation as syntax, and track titles are full of it.
    func testSearchTermsAreEscaped() {
        XCTAssertEqual(MusicBrainzClient.quote("Rev8617"), "\"Rev8617\"")
        XCTAssertEqual(MusicBrainzClient.quote("Where?"), "\"Where\\?\"")
        XCTAssertEqual(MusicBrainzClient.quote("A+B (Mix)"), "\"A\\+B \\(Mix\\)\"")
    }

    func testRateGateHoldsRequestsApart() async {
        let gate = RateGate(interval: 0.25)
        let start = Date()
        for _ in 0..<3 { await gate.wait() }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.45, "Three requests must span at least two intervals")
    }

    // MARK: Enrichment

    func testEnrichmentFoldsCanonicalFactsIntoTheRecording() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())

        let metadata = try await enricher.enrich(recording)

        XCTAssertEqual(recording.musicBrainzRecordingID, "fae2e027-7f02-4269-9d9e-7ee88f8effb6")
        XCTAssertEqual(recording.isrc, "DEUM71800123")
        XCTAssertEqual(recording.albumTitle, "Compro")
        XCTAssertEqual(recording.durationSeconds ?? 0, 224, accuracy: 0.5)
        XCTAssertEqual(metadata?.labelName, "Ilian Tape")
        XCTAssertEqual(metadata?.catalogNumber, "ITLP04")
        XCTAssertEqual(metadata?.artistMBID, "2b3e25ba-983e-44ac-9def-907e03910cd2")
    }

    /// A lookup is expensive and rate-limited; a second call must be free.
    func testEnrichmentIsCached() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())

        try await enricher.enrich(recording)
        let afterFirst = recorder.requestedURLs.count
        try await enricher.enrich(recording)

        XCTAssertEqual(recorder.requestedURLs.count, afterFirst, "A cached lookup must not hit the network")
    }

    /// There is nothing to search MusicBrainz with, and a blind query would
    /// return somebody else's music at high confidence.
    func testUnknownRecordingsAreNotLookedUp() async throws {
        let unknown = try store.createUnknown(
            providerID: "nts", showID: "moxie/2026-08-27",
            heardAt: Date(), offsetSeconds: 120
        )
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())

        let result = try await enricher.enrich(unknown)

        XCTAssertNil(result)
        XCTAssertTrue(recorder.requestedURLs.isEmpty)
    }

    func testLabelRosterIsDerivedFromItsCatalogue() async throws {
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())

        let label = try await enricher.label(mbid: "cb0e0976-5f14-46ea-b5b7-796f32985439")

        XCTAssertEqual(label.name, "Ilian Tape")
        XCTAssertEqual(label.origin, "München")
        XCTAssertEqual(label.foundedYear, "2007")
        XCTAssertEqual(label.catalogueSize, 279)
        XCTAssertEqual(label.artistNames.first, "Skee Mask", "Ranked by share of the catalogue")
        XCTAssertTrue(label.artistNames.contains("Andrea"))
        XCTAssertTrue(label.artistNames.contains("Stenny"))
        XCTAssertFalse(label.artistNames.contains("Various Artists"),
                       "A compilation credit is not a roster artist")
    }

    // MARK: Digging an artist you only own files by

    /// The bug this covers: enrichment was driven off `Recording` rows, which
    /// only exist once something has been crated. An artist you own six files
    /// by had none, so DIG made zero requests and the page could never fill in
    /// — while a stale error made it look like a network problem.
    func testAnArtistWithNoRecordingsIsStillResolvedByName() async throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0)

        let artist = try await MusicBrainzEnricher(context: context, client: makeNameClient())
            .artist(named: "Kelly Moran")

        let resolved = try XCTUnwrap(artist)
        XCTAssertEqual(resolved.mbid, "b794b18d-5d40-46cc-9a55-4dd15ac37e30")
        XCTAssertEqual(resolved.origin, "Brooklyn / US")
        XCTAssertEqual(resolved.disambiguation, "keyboardist and composer")
        XCTAssertEqual(resolved.releaseTitles, ["Origin", "Ultraviolet", "Bloodroot"],
                       "Albums and EPs, newest first; compilations excluded")
    }

    /// Two requests, not thirty. The old path enriched eight recordings at up
    /// to three requests each before it even looked the artist up, which is
    /// what got the client throttled in the first place.
    func testResolvingAnArtistByNameCostsTwoRequests() async throws {
        _ = try await MusicBrainzEnricher(context: context, client: makeNameClient())
            .artist(named: "Kelly Moran")
        XCTAssertEqual(recorder.requestedURLs.count, 2)
    }

    func testAProfileFindsACachedArtistWithoutAnMBID() async throws {
        _ = try await MusicBrainzEnricher(context: context, client: makeNameClient())
            .artist(named: "Kelly Moran")

        let profile = DigEngine(context: context).artistProfile(name: "Kelly Moran", mbid: nil)

        XCTAssertEqual(profile.mbid, "b794b18d-5d40-46cc-9a55-4dd15ac37e30")
        XCTAssertEqual(profile.origin, "Brooklyn / US")
        XCTAssertEqual(profile.releases.first?.title, "Origin")
        XCTAssertFalse(profile.isBare)
    }

    func testACachedArtistIsReusedRatherThanRefetched() async throws {
        let enricher = MusicBrainzEnricher(context: context, client: makeNameClient())
        _ = try await enricher.artist(named: "Kelly Moran")
        let afterFirst = recorder.requestedURLs.count
        _ = try await enricher.artist(named: "kelly moran")

        XCTAssertEqual(recorder.requestedURLs.count, afterFirst,
                       "A cached artist must be matched on the normalised name")
    }

    /// Losing the optional label lookup costs the RELATED column. Saying so in
    /// red over a page that loaded its artist and discography fine reads as a
    /// failure when nothing the listener asked for actually failed.
    func testAThrottledSecondStageDoesNotReportFailureOverAPopulatedPage() async throws {
        struct ArtistThenThrottle: MusicBrainzTransport {
            let search: String
            let groups: String
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let url = request.url!
                let text = url.absoluteString
                if text.contains("ws/2/artist?") {
                    return (Data(search.utf8),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if text.contains("ws/2/release-group?") {
                    return (Data(groups.utf8),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                throw URLError(.timedOut)
            }
        }

        context.insert(Track(
            path: "/Music/Helix.flac", relativePath: "Helix.flac",
            title: "Helix", artist: "Kelly Moran", albumArtist: "Kelly Moran", album: "Ultraviolet",
            genre: "Modern Classical", trackNumber: 1, discNumber: 1, year: 2018,
            duration: 200, fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        ))

        let store = DigStore(
            context: context,
            client: MusicBrainzClient(
                transport: ArtistThenThrottle(search: artistSearch, groups: artistReleaseGroups)
            )
        )
        await store.enrichArtist(name: "Kelly Moran", mbid: nil)

        let profile = await store.artistProfile(name: "Kelly Moran", mbid: nil)
        XCTAssertFalse(profile.isBare, "Stage one should have populated the page")
        XCTAssertEqual(profile.releases.first?.title, "Origin")
        XCTAssertNil(store.notice, "A populated page must not be labelled a failure")
    }

    /// The opposite case: if nothing at all could be resolved, say so.
    func testAThrottledFirstStageDoesReportFailure() async throws {
        struct AlwaysThrottle: MusicBrainzTransport {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(.timedOut)
            }
        }
        let store = DigStore(
            context: context,
            client: MusicBrainzClient(transport: AlwaysThrottle())
        )
        await store.enrichArtist(name: "Nobody Known", mbid: nil)

        XCTAssertNotNil(store.notice)
        let bare = await store.artistProfile(name: "Nobody Known", mbid: nil)
        XCTAssertTrue(bare.isBare)
    }

    // MARK: Counting

    /// The index said 5 and the artist page said 6 for the same library,
    /// because one grouped by album artist and the other matched either field.
    func testTheIndexAndTheArtistPageCountTheSameLibrary() {
        let tracks = [
            ("Kelly Moran", "Kelly Moran", "Helix 2"),
            ("Kelly Moran", "Various Artists", "In Parallel (WXAXRXP Session)"),
            ("Kelly Moran", "Kelly Moran", "In Parallel"),
            ("Kelly Moran", "Kelly Moran", "Radian"),
            ("Kelly Moran", "Kelly Moran", "Love Birds"),
            ("Kelly Moran", "Kelly Moran", "Interlude 1")
        ]
        for (artist, albumArtist, title) in tracks {
            context.insert(Track(
                path: "/Music/\(title).flac", relativePath: "\(title).flac",
                title: title, artist: artist, albumArtist: albumArtist, album: "Album",
                genre: "Modern Classical", trackNumber: 1, discNumber: 1, year: 2018,
                duration: 200, fileModified: Date(), fileSize: 1024,
                artworkKey: nil, scanGeneration: 1
            ))
        }

        let engine = DigEngine(context: context)
        XCTAssertEqual(engine.libraryTrackCount(artist: "Kelly Moran"), 6)
        XCTAssertEqual(engine.libraryTrackCount(artist: "Various Artists"), 1,
                       "The compilation credit still counts, on its own row")

        // The same rule the index groups by.
        let all = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let indexed = all.filter {
            DigEngine.artistKeys(for: $0).contains(RecordingKey.normalizeArtist("Kelly Moran"))
        }.count
        XCTAssertEqual(indexed, engine.libraryTrackCount(artist: "Kelly Moran"))
    }

    // MARK: DIG

    func testArtistProfileReachesTheLabelAndItsPeers() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())
        try await enricher.enrich(recording)
        try await enricher.artist(mbid: "2b3e25ba-983e-44ac-9def-907e03910cd2")
        try await enricher.label(mbid: "cb0e0976-5f14-46ea-b5b7-796f32985439")

        let profile = DigEngine(context: context).artistProfile(
            name: "Skee Mask", mbid: "2b3e25ba-983e-44ac-9def-907e03910cd2"
        )

        XCTAssertEqual(profile.origin, "Munich / Germany")
        XCTAssertEqual(profile.releases.first?.title, "Pool", "Newest first")
        XCTAssertEqual(profile.releases.first?.year, "2021")
        XCTAssertEqual(profile.labels.map(\.name), ["Ilian Tape"])

        let peers = profile.related.map(\.name)
        XCTAssertTrue(peers.contains("Andrea"))
        XCTAssertTrue(peers.contains("Stenny"))
        XCTAssertTrue(peers.contains("Zenker Brothers"))
        XCTAssertFalse(peers.contains("Skee Mask"), "An artist is not related to themselves")
    }

    /// The spec is blunt: never an opaque recommendation.
    func testEveryRelatedArtistCarriesItsReason() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let enricher = MusicBrainzEnricher(context: context, client: makeClient())
        try await enricher.enrich(recording)
        try await enricher.label(mbid: "cb0e0976-5f14-46ea-b5b7-796f32985439")

        let profile = DigEngine(context: context).artistProfile(name: "Skee Mask", mbid: nil)

        XCTAssertFalse(profile.related.isEmpty)
        for peer in profile.related {
            XCTAssertFalse(peer.reasons.isEmpty, "\(peer.name) appeared with no stated reason")
            XCTAssertTrue(peer.reasons.contains { $0.detail == "Same label: Ilian Tape" })
        }
    }

    /// The counts no catalogue can give you.
    func testProfileCountsTheListenersOwnRelationship() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        store.note(
            appearance: MediaAppearance(
                providerID: "nts", stationName: "NTS 1", showTitle: "Moxie",
                showID: "moxie/2026-08-27", heardAt: Date(), isLive: true, method: .acoustic
            ),
            on: recording
        )
        context.insert(CrateItem(recording: recording))
        context.insert(Track(
            path: "/Music/Rev8617.flac", relativePath: "Rev8617.flac",
            title: "Rev8617", artist: "Skee Mask", albumArtist: "Skee Mask", album: "Compro",
            genre: "Electronic", trackNumber: 3, discNumber: 1, year: 2018, duration: 224,
            fileModified: Date(), fileSize: 2048, artworkKey: nil, scanGeneration: 1
        ))

        let profile = DigEngine(context: context).artistProfile(name: "Skee Mask", mbid: nil)

        XCTAssertEqual(profile.libraryTrackCount, 1)
        XCTAssertEqual(profile.crateCount, 1)
        XCTAssertEqual(profile.radioAppearances.first?.label, "NTS 1 / Moxie")
    }

    func testAnArtistWithNothingBehindItReportsAsBare() {
        let profile = DigEngine(context: context).artistProfile(name: "Nobody At All", mbid: nil)
        XCTAssertTrue(profile.isBare)
    }
}

// MARK: - Connection lanes

/// Each lane used to be a filter that scanned every lane before it, so a
/// well-connected artist cost several thousand comparisons on every redraw.
final class ConnectionLaneTests: XCTestCase {
    private func artist(_ name: String, _ kinds: [RelationshipKind]) -> RelatedArtist {
        RelatedArtist(
            name: name, mbid: nil,
            reasons: kinds.map {
                Relationship(kind: $0, source: .discogs, detail: "because", confidence: 0.7)
            }
        )
    }

    /// An artist belongs in exactly one lane, or the page lists them twice.
    func testEveryArtistLandsInExactlyOneLane() {
        let related = [
            artist("Credited", [.collaborator]),
            artist("Alias", [.aliasOrProject]),
            artist("Labelmate", [.sharedLabel]),
            artist("Similar", [.sharedStyle]),
            artist("Heard together", [.sharedBroadcast]),
            artist("Contemporary", [.sameEra])
        ]
        let lanes = ArtistDigView.Connections.split(related)
        let placed = lanes.collaborators + lanes.projects + lanes.labelArtists
            + lanes.soundArtists + lanes.personalArtists + lanes.eraArtists

        XCTAssertEqual(placed.count, related.count)
        XCTAssertEqual(Set(placed.map(\.name)).count, related.count, "Nobody appears twice")
    }

    /// An alias is a fact and a shared decade is barely a hint, so somebody
    /// reached by both belongs under the stronger one.
    func testTheStrongestReasonDecidesTheLane() {
        let lanes = ArtistDigView.Connections.split([
            artist("Both", [.sameEra, .sharedLabel, .collaborator])
        ])
        XCTAssertEqual(lanes.collaborators.map(\.name), ["Both"])
        XCTAssertTrue(lanes.labelArtists.isEmpty)
        XCTAssertTrue(lanes.eraArtists.isEmpty)
    }

    /// A page has to be drawable before the graph has been walked.
    func testAPlaceholderProfileIsSafeToDraw() {
        let placeholder = ArtistProfile.placeholder(name: "Skee Mask", mbid: "mb-1")
        XCTAssertEqual(placeholder.name, "Skee Mask")
        XCTAssertEqual(placeholder.mbid, "mb-1")
        XCTAssertTrue(placeholder.isBare, "Which is why the view must not announce it")
        XCTAssertTrue(placeholder.related.isEmpty)
        XCTAssertTrue(placeholder.listen.isEmpty)
    }
}

/// The loading indicator says the one thing a label was being used to say.
final class WorkingBarTests: XCTestCase {
    /// Driven by the clock rather than by state, so it costs nothing off
    /// screen and never needs starting or stopping. What is pinned here is
    /// that the sweep stays inside its own track — an indicator that walks out
    /// of its bounds is worse than no indicator.
    func testTheSweepStaysInsideItsTrack() {
        let width: Double = 120
        let period: Double = 1.1
        let segment = width * 0.28
        let travel = width * 0.72

        for step in 0...40 {
            let phase = (Double(step) / 40 * period)
                .truncatingRemainder(dividingBy: period) / period
            let eased = (1 - cos(phase * 2 * .pi)) / 2
            let offset = travel * eased

            XCTAssertGreaterThanOrEqual(offset, 0)
            XCTAssertLessThanOrEqual(offset + segment, width + 0.001,
                                     "The bar must not run past its own track")
        }
    }
}

/// A page must not announce a failure it has not yet had.
final class LoadingStateTests: XCTestCase {
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

    /// The sequence that produced the complaint: the page read an empty store,
    /// found nothing, said so, and only then went and asked. Emptiness before
    /// the catalogues have been asked is not evidence of anything.
    @MainActor
    func testAnEmptyStoreIsNotAnAnswer() async throws {
        let dig = DigStore(context: context)
        let beforeAsking = await dig.artistProfile(name: "Skee Mask", mbid: nil)
        XCTAssertTrue(beforeAsking.isBare, "Nothing known yet")

        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 1, name: "Skee Mask")
        artist.releaseTitles = ["Compro"]
        context.insert(artist)
        try? context.save()

        // The same page, a moment later, once something has arrived.
        let dug = DigStore(context: context)
        let after = await dug.artistProfile(name: "Skee Mask", mbid: nil)
        XCTAssertFalse(after.isBare)
    }

    /// A record with an identifier is looked up by the catalogue, so the
    /// "no catalogue has this" state belongs only to one that has none.
    func testARecordWithAnIdentifierIsNotUnclaimed() {
        XCTAssertEqual(
            DetailPage.digRelease(id: 12_345, title: "Compro"),
            .digRelease(id: 12_345, title: "Compro")
        )
        XCTAssertNotEqual(
            DetailPage.digRelease(id: 12_345, title: "Compro"),
            .digReleaseNamed(title: "Compro", artist: "Skee Mask")
        )
    }

    /// A row says what it is, not which service is carrying it. Naming the
    /// provider on every line is noise where it does not change the row.
    func testARowNeedNotNameItsService() {
        let unnamed = ListenRow(
            title: "Rev8617", duration: "5:00", isCurrent: false, isPlaying: false,
            isCrated: false, play: {}, keep: {}
        )
        XCTAssertNil(unnamed.provider)
    }
}
