//
//  ArtistStagingTests.swift
//  IndigoTests
//
//  An artist's entry is written as soon as `artists/{id}` answers, rather than
//  held for their shelf, which is the slowest request an artist page makes.
//  The risk in that is a half-written artist taken for a whole one — served
//  from the cache with no discography behind it, for good. These pin that it
//  is not, from the enricher up through the store.
//

import XCTest
import SwiftData
@testable import Indigo

/// Holds an artist's shelf back until a test lets it go, so the test can look
/// at what was written in the meantime.
private final class ShelfGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let held = waiting
            waiting = []
            return held
        }
        released.forEach { $0.resume() }
    }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if goNow { continuation.resume() }
        }
    }
}

/// Every address a transport was asked for.
private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL?) {
        guard let url else { return }
        lock.withLock { urls.append(url) }
    }

    var all: [URL] { lock.withLock { urls } }
}

/// Discogs, with the shelf — the releases endpoint and the catalogue search —
/// behind a gate, and optionally failing once through it.
private struct ShelfTransport: DiscogsTransport {
    let gate: ShelfGate
    var shelfStatus = 200
    var recorder: URLRecorder? = nil
    /// Replaces the artist's entry, for a test that needs one naming nobody.
    var detailBody: String? = nil

    static let routes: [String: String] = [
        "type=artist": """
        {"results":[{"id":1,"title":"Skee Mask","cover_image":"https://img.test/search.jpg","thumb":"https://img.test/search-thumb.jpg"}]}
        """,
        "artists/1": """
        {"id":1,"name":"Skee Mask","realname":"Bryan Müller","profile":"Producer from Munich.",
         "uri":"/artist/1-Skee-Mask",
         "images":[{"type":"primary","uri":"https://img.test/artist.jpg","uri150":"https://img.test/150.jpg"}],
         "aliases":[{"id":3,"name":"SCNTST"}],"members":[],"groups":[{"id":4,"name":"Zenker Brothers"}]}
        """,
        "artists/1/releases": """
        {"releases":[
          {"id":10,"title":"Pool","year":2021,"role":"Main","type":"release","label":"Ilian Tape","artist":"Skee Mask","format":"Vinyl"},
          {"id":11,"title":"Compro","year":2018,"role":"Main","type":"release","label":"Ilian Tape","artist":"Skee Mask","format":"Vinyl"}
        ]}
        """,
        "type=release": """
        {"results":[{"id":10,"title":"Skee Mask - Pool","cover_image":"https://img.test/pool.jpg","genre":["Electronic"],"style":["Techno"]}]}
        """
    ]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorder?.record(request.url)
        let url = request.url?.absoluteString ?? ""
        let isShelf = url.contains("artists/1/releases") || url.contains("type=release")
        if isShelf { await gate.pass() }
        let route = Self.routes.keys.filter(url.contains).max { $0.count < $1.count }
        let status = route == nil ? 404 : (isShelf ? shelfStatus : 200)
        let body = (route == "artists/1" ? detailBody : nil)
            ?? route.flatMap { Self.routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

/// MusicBrainz, knowing nobody, so a store test cannot fall through to it.
private struct NobodyOnMusicBrainz: MusicBrainzTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data("{}".utf8), HTTPURLResponse(
            url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
        )!)
    }
}

final class ArtistStagingTests: XCTestCase {
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

    private func storedArtist() -> DiscogsArtist? {
        let key = RecordingKey.normalizeArtist("Skee Mask")
        var descriptor = FetchDescriptor<DiscogsArtist>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The entry lands while the shelf is still out, and is not a finished artist.
    func testAnArtistsEntryIsWrittenAheadOfTheirShelfWithoutBeingStampedComplete() async throws {
        let gate = ShelfGate()
        let client = DiscogsClient(transport: ShelfTransport(gate: gate), token: "secret")
        let enricher = DiscogsEnricher(context: context, client: client)
        let lookedUp = try await client.artistHead(named: "Skee Mask")
        let head = try XCTUnwrap(lookedUp)

        async let shelf = client.artistShelf(named: "Skee Mask", id: 1)
        let detail = try await client.artistDetail(id: 1)
        let early = enricher.artistDetail(named: "Skee Mask", head: head, detail: detail)

        XCTAssertEqual(early.realName, "Bryan Müller")
        XCTAssertNotNil(early.biography)
        XCTAssertEqual(early.aliasNames, ["SCNTST"])
        XCTAssertEqual(early.imageURL?.absoluteString, "https://img.test/artist.jpg")
        XCTAssertTrue(early.releaseTitles.isEmpty, "The shelf has not arrived")
        XCTAssertLessThan(early.cacheVersion, 12)
        XCTAssertNil(enricher.freshArtist(named: "Skee Mask"),
                     "A profile with no shelf behind it must not satisfy the cache")

        gate.open()
        let found = try await shelf
        let complete = try XCTUnwrap(enricher.artist(named: "Skee Mask", bundle: DiscogsArtistBundle(
            detail: detail, releases: found.releases,
            searchImageURL: head.coverImage, searchThumbnailURL: head.thumbnail,
            catalogue: found.catalogue
        )))
        XCTAssertFalse(complete.releaseTitles.isEmpty)
        XCTAssertEqual(complete.cacheVersion, 12)
        XCTAssertEqual(complete.realName, "Bryan Müller", "The complete write agrees with the early one")
        XCTAssertNotNil(enricher.freshArtist(named: "Skee Mask"))
    }

    /// A shelf that never arrives leaves an artist that is asked about again,
    /// not one served forever with no discography.
    func testAnEntryWhoseShelfNeverArrivesIsAskedForAgain() async throws {
        let gate = ShelfGate()
        gate.open()
        let client = DiscogsClient(transport: ShelfTransport(gate: gate, shelfStatus: 500), token: "secret")
        let enricher = DiscogsEnricher(context: context, client: client)
        let lookedUp = try await client.artistHead(named: "Skee Mask")
        let head = try XCTUnwrap(lookedUp)

        let detail = try await client.artistDetail(id: 1)
        enricher.artistDetail(named: "Skee Mask", head: head, detail: detail)
        do {
            _ = try await client.artistShelf(named: "Skee Mask", id: 1)
            XCTFail("The shelf was set up to fail")
        } catch {}

        XCTAssertNil(enricher.freshArtist(named: "Skee Mask"))
        do {
            _ = try await enricher.artist(named: "Skee Mask", head: head)
            XCTFail("The partial entry was served as the artist instead of being asked for again")
        } catch {}
    }

    /// Through the store, as a page drives it: the profile is on the row while
    /// the shelf is still held back, and the row is only complete after.
    @MainActor
    func testTheStoreWritesTheEntryWhileTheShelfIsStillOnItsWay() async throws {
        let gate = ShelfGate()
        let store = DigStore(
            context: context,
            client: MusicBrainzClient(transport: NobodyOnMusicBrainz()),
            discogsClient: DiscogsClient(transport: ShelfTransport(gate: gate), token: "secret")
        )
        let enrichment = Task { await store.enrichArtist(name: "Skee Mask", mbid: nil) }

        for _ in 0..<500 where storedArtist()?.realName != "Bryan Müller" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let partial = try XCTUnwrap(storedArtist(), "The entry should not wait for the shelf")
        XCTAssertEqual(partial.realName, "Bryan Müller")
        XCTAssertTrue(partial.releaseTitles.isEmpty)
        XCTAssertLessThan(partial.cacheVersion, 12)

        gate.open()
        await enrichment.value

        let complete = try XCTUnwrap(storedArtist())
        XCTAssertEqual(complete.cacheVersion, 12)
        XCTAssertFalse(complete.releaseTitles.isEmpty)
    }

    /// A shelf that never comes still leaves somewhere to go when the entry
    /// named other people — an alias, a group — because those are routes of
    /// their own. The empty state is for an entry that named nobody.
    @MainActor
    func testAnEntryWithoutAShelfStillOffersThePeopleItNamed() async throws {
        let profile = try await profileAfterAFailedShelf(detailBody: nil)
        let names = profile.related.map(\.name)
        XCTAssertNotNil(profile.biography)
        XCTAssertTrue(names.contains("SCNTST") || names.contains("Zenker Brothers"),
                      "The routes came from somewhere other than the entry's aliases and groups: \(names)")
        XCTAssertFalse(profile.hasNothingToDig, "An alias and a group are somewhere to go")
    }

    /// And an entry that named nobody leaves a biography over an empty page —
    /// which, once the entry could land without its shelf, stopped saying
    /// there was nothing to dig.
    @MainActor
    func testAProfileWithNoShelfAndNobodyElseSaysThereIsNothingToDig() async throws {
        let profile = try await profileAfterAFailedShelf(detailBody: """
        {"id":1,"name":"Skee Mask","profile":"Producer from Munich.","aliases":[],"members":[],"groups":[]}
        """)
        XCTAssertNotNil(profile.biography, "The entry arrived before the shelf failed")
        XCTAssertFalse(profile.isBare)
        XCTAssertTrue(
            profile.hasNothingToDig,
            "releases=\(profile.releases.count) labels=\(profile.labels.count) related=\(profile.related.map(\.name)) radio=\(profile.radioAppearances.count) library=\(profile.libraryTrackCount)"
        )
    }

    /// The artist's entry arrives; their shelf is refused; nobody on
    /// MusicBrainz knows them.
    @MainActor
    private func profileAfterAFailedShelf(detailBody: String?) async throws -> ArtistProfile {
        let gate = ShelfGate()
        gate.open()
        let store = DigStore(
            context: context,
            client: MusicBrainzClient(transport: NobodyOnMusicBrainz()),
            discogsClient: DiscogsClient(
                transport: ShelfTransport(gate: gate, shelfStatus: 500, detailBody: detailBody), token: "secret"
            )
        )
        await store.enrichArtist(name: "Skee Mask", mbid: nil)
        return await store.artistProfile(name: "Skee Mask", mbid: nil)
    }

    /// With the minute nearly spent, the artist on screen is still looked up in
    /// full — and the neighbourhood searches and record reads that follow wait
    /// for room rather than spend the last of it.
    @MainActor
    func testWorkThePageCanDoWithoutWaitsForRoomRatherThanSpendingTheLastOfTheMinute() async throws {
        let gate = ShelfGate()
        gate.open()
        let recorder = URLRecorder()
        let budget = DiscogsBudget()
        await budget.record(HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/database/search")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["X-Discogs-Ratelimit-Remaining": "10", "X-Discogs-Ratelimit": "60"]
        )!)
        let store = DigStore(
            context: context,
            client: MusicBrainzClient(transport: NobodyOnMusicBrainz()),
            discogsClient: DiscogsClient(
                transport: ShelfTransport(gate: gate, recorder: recorder), token: "secret", budget: budget
            )
        )
        store.budgetPatience = .milliseconds(150)

        await store.enrichArtist(name: "Skee Mask", mbid: nil)
        XCTAssertEqual(storedArtist()?.cacheVersion, 12, "The artist on screen is still looked up in full")

        await store.fillMissingReleaseArtwork(forArtist: "Skee Mask", mbid: nil, limit: 12, whenThereIsRoom: true)

        let neighbourhood = recorder.all.filter {
            $0.absoluteString.contains("label=") || $0.absoluteString.contains("style=")
        }
        XCTAssertTrue(neighbourhood.isEmpty, "Five searches sent into a budget below the reserve")
        XCTAssertTrue(recorder.all.filter { $0.path.hasPrefix("/releases/") }.isEmpty,
                      "A batch of record reads sent into a budget below the reserve")
    }
}
