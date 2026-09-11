//
//  DigSearchTests.swift
//  IndigoTests
//
//  Search is the one DIG surface where being wrong is worse than being empty.
//  Everything else on the page is an offer the listener can ignore; a search
//  answers a question they asked, and a row that opens onto nothing — a name
//  carrying Discogs' filing marks, a label of the wrong identity, a record
//  read out of the "Artist - Title" string as though it were the title — is a
//  worse answer than none.
//

import XCTest
import SwiftData
@testable import Indigo

private struct SearchStubTransport: DiscogsTransport {
    let body: String
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func record(_ url: String) { lock.withLock { urls.append(url) } }
        var requested: [String] { lock.withLock { urls } }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorder.record(request.url?.absoluteString ?? "")
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}

/// Refuses everything with a 429 answered instantly — how Discogs turns down
/// the sixty-first request in a minute.
private struct RefusingSearchTransport: DiscogsTransport {
    let recorder: SearchStubTransport.Recorder

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorder.record(request.url?.absoluteString ?? "")
        return (Data("{}".utf8), HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
        )!)
    }
}

final class DigSearchTests: XCTestCase {
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

    // MARK: - Ranking

    /// Where a query lands in a name is most of what makes a match good.
    func testWholeNameBeatsAWordBeatsTheMiddleOfOne() {
        XCTAssertEqual(DigSearchIndex.tier(of: "boards of canada", matching: "boards"), 0)
        XCTAssertEqual(DigSearchIndex.tier(of: "the boards", matching: "boards"), 1)
        XCTAssertEqual(DigSearchIndex.tier(of: "surfboards", matching: "boards"), 2)
        XCTAssertNil(DigSearchIndex.tier(of: "skee mask", matching: "boards"))
    }

    /// One letter is not a search. It matches most of a library and returns a
    /// list nobody scrolls.
    func testASingleLetterIsNotSearched() {
        let index = DigSearchIndex(entries: [
            DigSearchIndex.Entry(
                kind: .artist, key: "skee mask", title: "Skee Mask", detail: nil,
                artworkURL: nil, destination: .digArtist(mbid: nil, name: "Skee Mask"),
                opensByIdentity: false, closeness: DigSearchIndex.dug
            )
        ])
        XCTAssertTrue(index.search("s").isEmpty)
        XCTAssertFalse(index.search("sk").isEmpty)
        XCTAssertFalse(DigSearchIndex.isSearchable("s"))
        XCTAssertFalse(DigSearchIndex.isSearchable("  "))
    }

    // MARK: - What this machine holds

    func testFindsArtistsRecordsAndLabelsAlreadyOnThisMachine() throws {
        context.insert(Track(
            path: "/Music/Rev8617.flac", relativePath: "Rev8617.flac",
            title: "Rev8617", artist: "Skee Mask", albumArtist: "Skee Mask", album: "Compro",
            genre: "Techno", trackNumber: 1, discNumber: 1, year: 2018,
            duration: 300, fileModified: Date(), fileSize: 1024,
            artworkKey: nil, scanGeneration: 1
        ))

        let release = DiscogsReleaseRecord(discogsID: 12227218, title: "Compro")
        release.artistNames = ["Skee Mask"]
        release.labelNames = ["Ilian Tape"]
        release.labelDiscogsIDs = [54782]
        release.year = 2018
        context.insert(release)
        try context.save()

        let index = DigSearchIndex(context: context)

        let artist = index.search("skee")
        XCTAssertEqual(artist.first?.kind, .artist)
        XCTAssertEqual(artist.first?.title, "Skee Mask")
        XCTAssertEqual(artist.first?.detail, "1 in library")

        // A record already read out of Discogs opens by id. The library's own
        // copy of the same album is the same row, so it is not offered twice.
        // The library's own copy of the same album is the same row. It says
        // the listener has it, and it opens onto the record's own page.
        let records = index.search("compro").filter { $0.kind == .release }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.detail, "Skee Mask · in library")
        XCTAssertEqual(records.first?.destination, .digRelease(id: 12227218, title: "Compro"))

        // The label carries the identity the release recorded, not just the
        // string — two labels can share a name.
        let label = index.search("ilian").first
        XCTAssertEqual(label?.kind, .label)
        XCTAssertEqual(label?.destination, .digDiscogsLabel(name: "Ilian Tape", discogsID: 54782))
    }

    /// A crated artist and the same artist reached through a dug discography
    /// are one row, and it should say the thing the listener did.
    func testTheClosestCopyOfANameWins() throws {
        let dug = DiscogsArtist(nameKey: "skee mask", discogsID: 1, name: "Skee Mask")
        dug.labelNames = ["Ilian Tape"]
        context.insert(dug)

        let recording = Recording(
            title: "Rev8617", artistName: "Skee Mask", status: .identified)
        context.insert(recording)
        context.insert(CrateItem(recording: recording))
        try context.save()

        let found = DigSearchIndex(context: context).search("skee")
            .filter { $0.kind == .artist }
        XCTAssertEqual(found.count, 1, "One artist, however many tables know them")
        XCTAssertEqual(found.first?.detail, "crated")
    }

    /// "Various" is where a catalogue files a compilation. Offered as a search
    /// result it is a row that opens onto everybody.
    func testFilingConventionsAreNotSearchResults() throws {
        context.insert(Track(
            path: "/Music/Comp.flac", relativePath: "Comp.flac",
            title: "One", artist: "Various", albumArtist: "Various", album: "Various Sounds",
            genre: "", trackNumber: 1, discNumber: 1, year: 2001,
            duration: 100, fileModified: Date(), fileSize: 10, artworkKey: nil, scanGeneration: 1
        ))
        let release = DiscogsReleaseRecord(discogsID: 5, title: "Various Sounds")
        release.labelNames = ["Not On Label"]
        context.insert(release)
        try context.save()

        let found = DigSearchIndex(context: context).search("various")
        XCTAssertFalse(found.contains { $0.kind == .artist },
                       "\"Various\" is a filing convention, not somebody to dig into")
        XCTAssertTrue(DigSearchIndex(context: context).search("not on label").isEmpty)
    }

    /// A film is not a record, and this is an application about records.
    func testVideosAreNotOfferedAsReleases() throws {
        let film = DiscogsReleaseRecord(discogsID: 99, title: "The Work Of Director")
        film.formats = ["DVD, NTSC"]
        context.insert(film)
        try context.save()

        XCTAssertTrue(DigSearchIndex(context: context).search("the work").isEmpty)
    }

    // MARK: - Merging the three sources

    func testYourOwnCopyWinsAndNothingIsSaidTwice() {
        let mine = DigSearchResult(
            kind: .artist, origin: .yours, title: "Skee Mask", detail: "14 in library",
            artworkURL: nil, destination: .digArtist(mbid: nil, name: "Skee Mask")
        )
        let theirs = DigSearchResult(
            kind: .artist, origin: .discogs, title: "skee mask", detail: nil,
            artworkURL: nil, destination: .digArtist(mbid: nil, name: "skee mask")
        )
        let record = DigSearchResult(
            kind: .release, origin: .discogs, title: "Skee Mask", detail: nil,
            artworkURL: nil, destination: .digRelease(id: 1, title: "Skee Mask")
        )

        let merged = DigSearchResults(yours: [mine], catalogue: [], discogs: [theirs, record])
            .merged
        XCTAssertEqual(merged.count, 2, "One artist, and a record that happens to share the name")
        XCTAssertEqual(merged.first?.detail, "14 in library")
        XCTAssertEqual(merged.last?.kind, .release)

        XCTAssertEqual(
            DigSearchResults(yours: [mine], catalogue: [], discogs: [theirs, record])
                .merged(scope: .releases).count,
            1
        )
    }

    // MARK: - Reading Discogs' answers

    /// Discogs' filing marks are not names. Carried into the app they become
    /// rows that open onto nothing.
    func testDiscogsFilingMarksAreStrippedFromNames() {
        let results = [
            DiscogsSearchResult(
                id: 1, title: "Nirvana (2)", coverImage: nil, thumbnail: nil,
                genre: nil, style: nil, label: nil, year: nil
            ),
            DiscogsSearchResult(
                id: 2, title: "Flowdan*", coverImage: nil, thumbnail: nil,
                genre: nil, style: nil, label: nil, year: nil
            )
        ]
        let rows = DigSearchResult.rows(fromDiscogs: results, kind: .artist)
        XCTAssertEqual(rows.map(\.title), ["Nirvana", "Flowdan"])
        XCTAssertEqual(rows.first?.destination, .digArtist(mbid: nil, name: "Nirvana"))
    }

    /// A label result opens the label Discogs meant, by id — the whole reason
    /// `labelDiscogsIDs` exists everywhere else.
    func testLabelResultsCarryTheirIdentity() {
        let rows = DigSearchResult.rows(
            fromDiscogs: [DiscogsSearchResult(
                id: 54782, title: "Ilian Tape", coverImage: nil, thumbnail: nil,
                genre: nil, style: nil, label: nil, year: nil
            )],
            kind: .label
        )
        XCTAssertEqual(rows.first?.destination,
                       .digDiscogsLabel(name: "Ilian Tape", discogsID: 54782))
    }

    /// Discogs writes a release as "Artist - Title". Read as a title it is a
    /// record nothing is filed under.
    func testAReleaseIsSplitFromItsCredit() {
        let rows = DigSearchResult.rows(
            fromDiscogs: [DiscogsSearchResult(
                id: 12227218, title: "Skee Mask - Compro",
                coverImage: "https://img.test/cover.jpg",
                thumbnail: "https://st.discogs.com/images/spacer.gif",
                genre: nil, style: nil, label: ["Ilian Tape"], year: "2018"
            )],
            kind: .release
        )
        XCTAssertEqual(rows.first?.title, "Compro")
        XCTAssertEqual(rows.first?.detail, "Skee Mask · 2018 · Ilian Tape")
        XCTAssertEqual(rows.first?.destination, .digRelease(id: 12227218, title: "Compro"))
        // The spacer is Discogs saying there is no sleeve. Drawn, it is a
        // transparent pixel where the placeholder should be.
        XCTAssertEqual(rows.first?.artworkURL?.absoluteString, "https://img.test/cover.jpg")
    }

    // MARK: - Asking Discogs

    func testSearchAsksForOneKindAtATime() async throws {
        let recorder = SearchStubTransport.Recorder()
        let client = DiscogsClient(
            transport: SearchStubTransport(body: #"{"results":[]}"#, recorder: recorder),
            token: "test"
        )

        _ = try await client.search("ilian tape", kind: .label, limit: 6)
        let url = try XCTUnwrap(recorder.requested.first)
        XCTAssertTrue(url.contains("database/search"))
        XCTAssertTrue(url.contains("type=label"))
        XCTAssertTrue(url.contains("per_page=6"))
        XCTAssertTrue(url.contains("q=ilian%20tape") || url.contains("q=ilian+tape"))
    }

    /// Discogs caps a page at a hundred and refuses more; an empty query is a
    /// request for everything it holds.
    func testSearchRefusesNothingAndClampsTheAsk() async throws {
        let recorder = SearchStubTransport.Recorder()
        let client = DiscogsClient(
            transport: SearchStubTransport(body: #"{"results":[]}"#, recorder: recorder),
            token: "test"
        )

        let nothing = try await client.search("   ", kind: .artist)
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertTrue(recorder.requested.isEmpty, "An empty query is not a question")

        _ = try await client.search("skee", kind: .artist, limit: 500)
        XCTAssertTrue(try XCTUnwrap(recorder.requested.first).contains("per_page=50"))
    }

    // MARK: - Reading the catalogue's answer

    func testCatalogueRowsDecodeAndKeepTheirIdentities() throws {
        let payload = """
        {"artists":[{"id":"6C6D8A5E-1F5B-4E7C-9E1A-2B3C4D5E6F70","name":"Skee Mask",
                     "country":"DE","discogs_id":"2477159"}],
         "labels":[{"id":"7C6D8A5E-1F5B-4E7C-9E1A-2B3C4D5E6F71","name":"Ilian Tape",
                    "country":null,"discogs_id":"54782"}],
         "releases":[{"id":"8C6D8A5E-1F5B-4E7C-9E1A-2B3C4D5E6F72","title":"Compro",
                      "artist_name":"Skee Mask","label_name":"Ilian Tape",
                      "release_year":2018,"catalog_number":"ITLP07","discogs_id":"12227218"}]}
        """
        let results = try JSONDecoder().decode(
            Catalog.SearchResults.self, from: Data(payload.utf8))
        let rows = DigSearchResult.rows(from: results)

        XCTAssertEqual(rows.map(\.kind), [.artist, .label, .release])
        XCTAssertEqual(rows[1].destination,
                       .digDiscogsLabel(name: "Ilian Tape", discogsID: 54782))
        XCTAssertEqual(rows[2].destination, .digRelease(id: 12227218, title: "Compro"))
        XCTAssertEqual(rows[2].detail, "Skee Mask · Ilian Tape · 2018 · ITLP07")
    }

    // MARK: - When the catalogue is enough

    /// The rule that decides whether Discogs is asked at all. Getting it wrong
    /// in one direction spends the shared budget on questions already
    /// answered; in the other it makes search confidently miss the thing it
    /// was for.
    func testAnArtistOrLabelWhoseNameStartsWithTheQueryIsTheAnswer() {
        let artist = DigSearchResult(
            kind: .artist, origin: .catalogue, title: "Purelink", detail: nil,
            artworkURL: nil, destination: .digArtist(mbid: nil, name: "Purelink")
        )
        XCTAssertTrue(DigSearchResult.answers([artist], query: "purelink"))
        XCTAssertTrue(DigSearchResult.answers([artist], query: "pure"), "Still being typed")

        let label = DigSearchResult(
            kind: .label, origin: .catalogue, title: "Ilian Tape", detail: nil,
            artworkURL: nil, destination: .digDiscogsLabel(name: "Ilian Tape", discogsID: 54782)
        )
        XCTAssertTrue(DigSearchResult.answers([label], query: "ilian"))
    }

    /// A record whose title matches is not an answer to a name.
    ///
    /// This is the case the rule exists for: "warp" turns up a dozen records
    /// with it in the title and none of them is Warp Records, and treating
    /// those as sufficient is how the search would come to skip Discogs and
    /// miss the label entirely.
    func testAMatchingReleaseTitleIsNotAnAnswer() {
        let record = DigSearchResult(
            kind: .release, origin: .catalogue, title: "Warp Speed", detail: nil,
            artworkURL: nil, destination: .digRelease(id: 1, title: "Warp Speed")
        )
        XCTAssertFalse(DigSearchResult.answers([record], query: "warp"))
    }

    /// Nor is a name that merely contains the query somewhere in the middle.
    func testASubstringMatchIsNotAnAnswer() {
        let artist = DigSearchResult(
            kind: .artist, origin: .catalogue, title: "Surfboards", detail: nil,
            artworkURL: nil, destination: .digArtist(mbid: nil, name: "Surfboards")
        )
        XCTAssertFalse(DigSearchResult.answers([artist], query: "boards"))
        XCTAssertFalse(DigSearchResult.answers([], query: "boards"), "Nothing answers nothing")
    }

    // MARK: - Being refused

    /// The bug this pair exists for: searching for Purelink, which Discogs
    /// certainly has, came back "Nothing under that name". Discogs had not
    /// said there was no such artist — it had said it was busy, and the answer
    /// was thrown away and reported as an absence.
    func testARefusalIsNotAnAbsence() async throws {
        let recorder = SearchStubTransport.Recorder()
        let client = DiscogsClient(
            transport: RefusingSearchTransport(recorder: recorder), token: "test")

        do {
            _ = try await client.search("purelink", kind: .artist)
            XCTFail("A 429 must reach the caller, not read as an empty result")
        } catch DiscogsError.rateLimited {
            // As it should be.
        }
    }

    /// And it is not worth waiting out. Three attempts is three seconds and
    /// two further requests against a budget just proved empty, to answer a
    /// query the listener has probably finished typing over.
    func testASearchAsksOnceAndTakesTheRefusal() async throws {
        let recorder = SearchStubTransport.Recorder()
        let client = DiscogsClient(
            transport: RefusingSearchTransport(recorder: recorder), token: "test")

        _ = try? await client.search("purelink", kind: .artist)
        XCTAssertEqual(recorder.requested.count, 1,
                       "A refused search should not climb the retry ladder")
    }

    /// Everything else still retries, because a page nobody is typing into is
    /// worth three seconds. Only search opts out.
    func testAPageLoadStillWaitsOutARefusal() async throws {
        let recorder = SearchStubTransport.Recorder()
        let client = DiscogsClient(
            transport: RefusingSearchTransport(recorder: recorder), token: "test")

        _ = try? await client.release(id: 12227218)
        XCTAssertEqual(recorder.requested.count, 3)
    }

    /// A catalogue row with no Discogs id still has a page — by name, which is
    /// what `digReleaseNamed` is for.
    func testACatalogueReleaseWithoutAnIdStillOpens() throws {
        let payload = """
        {"artists":[],"labels":[],
         "releases":[{"id":"8C6D8A5E-1F5B-4E7C-9E1A-2B3C4D5E6F72","title":"Compro",
                      "artist_name":"Skee Mask","label_name":null,
                      "release_year":null,"catalog_number":null,"discogs_id":null}]}
        """
        let results = try JSONDecoder().decode(
            Catalog.SearchResults.self, from: Data(payload.utf8))
        XCTAssertEqual(
            DigSearchResult.rows(from: results).first?.destination,
            .digReleaseNamed(title: "Compro", artist: "Skee Mask")
        )
    }
}
