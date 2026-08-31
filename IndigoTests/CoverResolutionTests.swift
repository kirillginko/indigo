//
//  CoverResolutionTests.swift
//  IndigoTests
//
//  Which sleeve a crated track wears.
//
//  Every source below can return *a* picture; only some can return the right
//  one. A title search will happily hand back a reissue, a compilation, or an
//  unrelated single that shares a name — so what is pinned here is the order,
//  and the refusal to guess once the album is actually known.
//

import XCTest
import SwiftData
@testable import Indigo

private struct SilentTransport: MusicBrainzTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data("{}".utf8), HTTPURLResponse(
            url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
        )!)
    }
}

private struct RecordingTransport: DiscogsTransport {
    let routes: [String: String]
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        var urls: [String] = []
        func asked(about term: String) -> Bool {
            urls.contains { $0.contains(term.replacingOccurrences(of: " ", with: "+")) }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        recorder.urls.append(url)
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        guard let route, let body = routes[route] else {
            return (Data("{}".utf8), HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!)
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}

@MainActor
final class CoverResolutionTests: XCTestCase {
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

    private func makeStore(
        routes: [String: String],
        recorder: RecordingTransport.Recorder
    ) -> DigStore {
        DigStore(
            context: context,
            client: MusicBrainzClient(transport: SilentTransport()),
            discogsClient: DiscogsClient(
                transport: RecordingTransport(routes: routes, recorder: recorder),
                token: "test"
            )
        )
    }

    /// The bug: a track on a known album whose album lookup came back empty
    /// used to fall through to searching Discogs for a *release* named after
    /// the track — and attach whatever that found. A song must never end up
    /// wearing an unrelated record's sleeve.
    func testATrackOnAKnownAlbumIsNeverGivenACoverFoundByItsOwnName() async throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        recording.albumTitle = "Untrue"

        let recorder = RecordingTransport.Recorder()
        // Discogs knows of a record called "Archangel" — by somebody else.
        let dig = makeStore(routes: [
            "release_title=Archangel": """
            {"results":[{"id":99,"title":"Archangel","cover_image":"https://img.test/wrong.jpg"}]}
            """
        ], recorder: recorder)

        await dig.resolveRelease(for: recording)

        XCTAssertNil(dig.releaseDetail(for: recording).artwork,
                     "No sleeve is the honest answer; the wrong one is not")
        XCTAssertTrue(recorder.asked(about: "Untrue"), "It should look for the album it is on")
        XCTAssertFalse(recorder.asked(about: "release_title=Archangel"),
                       "It must not go looking for a record named after the track")
    }

    /// With no album named by anyone, asking which release carries the track
    /// is a fair last resort — but only if what comes back is actually the
    /// artist's.
    func testWithNoAlbumKnownTheTrackNameIsAFairLastResort() async throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [
            "track=Archangel": """
            {"results":[{"id":99,"title":"Archangel","cover_image":"https://img.test/found.jpg"}]}
            """,
            "releases/99": """
            {"id":99,"title":"Archangel","uri":"/release/99",
             "artists":[{"id":1,"name":"Burial"}],"labels":[],"genres":[],"styles":[],
             "images":[{"type":"primary","uri":"https://img.test/found.jpg","uri150":"https://img.test/s.jpg"}],
             "tracklist":[]}
            """
        ], recorder: recorder)

        await dig.resolveRelease(for: recording)

        XCTAssertEqual(dig.releaseDetail(for: recording).artwork?.absoluteString,
                       "https://img.test/found.jpg")
    }

    /// Discogs' search is forgiving. A title match credited to someone else is
    /// a different record, and its sleeve belongs to that record.
    func testASearchResultCreditedToSomebodyElseIsRefused() async throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [
            "track=Archangel": """
            {"results":[{"id":99,"title":"Archangel","cover_image":"https://img.test/wrong.jpg"}]}
            """,
            "releases/99": """
            {"id":99,"title":"Archangel","uri":"/release/99",
             "artists":[{"id":7,"name":"Two Steps From Hell"}],"labels":[],"genres":[],"styles":[],
             "images":[{"type":"primary","uri":"https://img.test/wrong.jpg","uri150":"https://img.test/s.jpg"}],
             "tracklist":[]}
            """
        ], recorder: recorder)

        await dig.resolveRelease(for: recording)

        XCTAssertNil(dig.releaseDetail(for: recording).artwork)
    }

    /// A crate row imported by an earlier build carries whatever the old
    /// name-search-first ladder found. The recording's own resolved cover is
    /// the better answer, so it replaces it rather than deferring to it.
    func testAStaleCrateSleeveIsCorrectedRatherThanKept() async throws {
        let crate = CrateService(context: context)
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        crate.add(recording: recording)

        let item = try XCTUnwrap(((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []).first)
        item.artworkURLString = "https://img.test/stale.jpg"

        let metadata = RecordingMetadata(recordingID: recording.id)
        metadata.releaseTitle = "Untrue"
        metadata.artworkURLString = "https://img.test/untrue.jpg"
        context.insert(metadata)

        let recorder = RecordingTransport.Recorder()
        await makeStore(routes: [:], recorder: recorder).enrichCratedRecording(recording)

        XCTAssertEqual(item.artworkURLString, "https://img.test/untrue.jpg")
    }

    /// The route that was missing, and the one radio music actually needs. A
    /// tracklist gives you a song; a song is almost never the name of a
    /// record. Searching for a *release* called "Rev8617" finds nothing —
    /// asking which release has a track called "Rev8617" on it returns Compro.
    func testATrackResolvesToTheRecordItIsOn() async throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [
            "track=Rev8617": """
            {"results":[{"id":11,"title":"Skee Mask - Compro","year":"2018",
                         "cover_image":"https://img.test/compro.jpg"}]}
            """,
            "releases/11": """
            {"id":11,"title":"Compro","year":2018,"uri":"/release/11-Compro",
             "artists":[{"id":1,"name":"Skee Mask"}],
             "labels":[{"id":5,"name":"Ilian Tape","catno":"ITLP09"}],
             "genres":["Electronic"],"styles":["Techno"],
             "images":[{"type":"primary","uri":"https://img.test/compro.jpg","uri150":"https://img.test/s.jpg"}],
             "tracklist":[{"position":"A1","title":"Rev8617","duration":"5:00"}]}
            """
        ], recorder: recorder)

        await dig.resolveRelease(for: recording)

        XCTAssertEqual(dig.releaseDetail(for: recording).artwork?.absoluteString,
                       "https://img.test/compro.jpg")
        XCTAssertTrue(recorder.asked(about: "track=Rev8617"))
    }

    /// Stations write "MLN ft. Tony Njoku"; catalogues file "MLN". The suffix
    /// is true and it is also why the search comes back empty, so it is taken
    /// off the question — never off the recording.
    func testTheFeaturedArtistTailIsDroppedFromTheQuestionOnly() async throws {
        let recording = try store.upsert(title: "MLN ft. Tony Njoku", artistName: "Space Afrika")

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [:], recorder: recorder)
        await dig.resolveRelease(for: recording)

        XCTAssertTrue(recorder.asked(about: "track=MLN"), "Asked for the track as catalogued")
        XCTAssertEqual(recording.title, "MLN ft. Tony Njoku", "The recording keeps what was broadcast")
        XCTAssertEqual(TrackCredit.searchTitle("Rev8617"), "Rev8617", "Nothing to strip, nothing stripped")
        XCTAssertEqual(TrackCredit.searchTitle("ft. Only"), "ft. Only", "Never strips a title to nothing")
    }

    /// The bug that survived two rounds: a release with no Discogs ID is
    /// exactly the one with no sleeve, and the prefetch used to skip it —
    /// so the blank tiles stayed blank until somebody clicked each one, which
    /// resolved it by title and filled the grid in on the way back.
    func testABlankTileIsFilledInWithoutBeingClicked() async throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Seefeel"),
                                   discogsID: 1, name: "Seefeel")
        artist.releaseTitles = ["Squared Roots"]
        artist.releaseDiscogsIDs = []          // no identifier, as Discogs often leaves it
        artist.releaseImageURLStrings = [""]   // and no sleeve
        artist.releaseYears = ["2024"]
        artist.cacheVersion = 3
        context.insert(artist)

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [
            "release_title=Squared": """
            {"results":[{"id":500,"title":"Seefeel - Squared Roots","year":"2024",
                         "cover_image":"https://img.test/squared.jpg"}]}
            """,
            "releases/500": """
            {"id":500,"title":"Squared Roots","year":2024,"uri":"/release/500",
             "artists":[{"id":1,"name":"Seefeel"}],
             "labels":[{"id":9,"name":"Warp Records","catno":"WARP500"}],
             "genres":[],"styles":[],
             "images":[{"type":"primary","uri":"https://img.test/squared.jpg","uri150":"https://img.test/s.jpg"}],
             "tracklist":[]}
            """
        ], recorder: recorder)

        XCTAssertNil(dig.artistProfile(name: "Seefeel", mbid: nil).releases.first?.imageURL,
                     "Blank to begin with")

        await dig.fillMissingReleaseArtwork(forArtist: "Seefeel", mbid: nil)

        let release = try XCTUnwrap(dig.artistProfile(name: "Seefeel", mbid: nil).releases.first)
        XCTAssertEqual(release.imageURL?.absoluteString, "https://img.test/squared.jpg")
        XCTAssertEqual(release.label, "Warp Records")
    }

    /// The page reads the profile on every redraw — including every hover —
    /// and each miss walks the whole graph. Nothing but a write should cost
    /// that.
    func testTheProfileIsNotRebuiltForEveryRedraw() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Seefeel"),
                                   discogsID: 1, name: "Seefeel")
        artist.releaseTitles = ["Quique"]
        artist.styles = ["Ambient"]
        context.insert(artist)

        let recorder = RecordingTransport.Recorder()
        let dig = makeStore(routes: [:], recorder: recorder)

        let first = dig.artistProfile(name: "Seefeel", mbid: nil)
        let second = dig.artistProfile(name: "Seefeel", mbid: nil)
        XCTAssertEqual(first.releases.map(\.id), second.releases.map(\.id))

        // A different artist must not be served the cached one.
        XCTAssertNotEqual(dig.artistProfile(name: "Somebody Else", mbid: nil).name, "Seefeel")
        XCTAssertEqual(dig.artistProfile(name: "Seefeel", mbid: nil).styles, ["Ambient"])
    }
}
