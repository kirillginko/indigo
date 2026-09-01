//
//  DigRegressionTests.swift
//  IndigoTests
//
//  Two faults that reached the listener, kept from coming back.
//

import XCTest
import SwiftData
@testable import Indigo

private struct StubDiscogsTransport: DiscogsTransport {
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        func note(_ request: URLRequest) { lock.withLock { seen.append(request) } }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorder.note(request)
        let url = request.url?.absoluteString ?? ""
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let body = route.flatMap { routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }

    let routes: [String: String]

    init(routes: [String: String], recorder: Recorder) {
        self.routes = routes
        self.recorder = recorder
    }
}

@MainActor
final class DigRegressionTests: XCTestCase {
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

    /// "Fatal error: Duplicate values for key: 'release:the sunset violent'".
    ///
    /// The merge that builds the discography keeps a record pressed on two
    /// formats as two rows, because their titles are punctuated differently.
    /// Identity dropped the bracketed part, so both rows claimed to be the
    /// same row — and the page filed them by it and trapped. Opening any
    /// artist with an LP and a deluxe of the same record crashed the app.
    func testTwoPressingsOfOneRecordDoNotShareAnIdentity() throws {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Mount Kimbie"),
            discogsID: 1, name: "Mount Kimbie"
        )
        record.releaseTitles = [
            "The Sunset Violent", "The Sunset Violent (LP)", "The Sunset Violent [Deluxe]"
        ]
        record.releaseYears = ["2024", "2024", "2024"]
        record.releaseDiscogsIDs = [10, 11, 12]
        record.releaseImageURLStrings = ["", "", ""]
        record.releaseThumbnailURLStrings = ["", "", ""]
        record.releaseLabels = ["Warp", "Warp", "Warp"]
        context.insert(record)
        try context.save()

        let releases = DigEngine(context: context)
            .artistProfile(name: "Mount Kimbie", mbid: nil).releases
        let identities = releases.map(\.id)

        XCTAssertEqual(
            Set(identities).count, identities.count,
            "Every row on the page has to be a different row: \(identities)"
        )
        // The trap was here — this is what the view does with them.
        XCTAssertNoThrow(
            Dictionary(uniqueKeysWithValues: identities.enumerated().map { ($1, $0) })
        )
    }

    /// The page must not wait two round trips to stop being empty.
    ///
    /// The search that finds an artist already carries their name and a
    /// picture of them. Waiting for the detail, discography and catalogue
    /// before drawing anything meant the portrait arrived twice as late as
    /// it had to.
    func testTheSearchAloneGivesThePageAPortrait() async throws {
        let recorder = StubDiscogsTransport.Recorder()
        let search = """
        {"results":[{"id":41,"title":"Autechre",
                     "cover_image":"https://img.test/ae.jpg",
                     "thumb":"https://img.test/ae-150.jpg"}]}
        """
        let client = DiscogsClient(transport: StubDiscogsTransport(
            routes: ["type=artist": search], recorder: recorder
        ), token: "secret")

        let head = try await client.artistHead(named: "Autechre")
        let match = try XCTUnwrap(head)
        XCTAssertEqual(recorder.requests.count, 1, "One request, not the whole bundle")

        let record = DiscogsEnricher(context: context, client: client)
            .artistIdentity(named: "Autechre", head: match)
        XCTAssertEqual(record.discogsID, 41)
        XCTAssertNotNil(record.imageURL, "The search's own picture is the first portrait")
    }

    /// What one cold artist costs the request budget.
    ///
    /// Discogs allows sixty requests a minute. Opening somebody new spends a
    /// search to find them, three for their bundle, and five for the
    /// neighbourhood — and the background portrait fill was spending forty a
    /// minute alongside it on rows nobody had looked at. Over the limit, the
    /// nine that somebody is actually waiting for are the ones throttled,
    /// which is how opening an artist came to take six seconds.
    ///
    /// The fill stands aside now. This guards the other half: that a cold
    /// artist stays a bounded number of requests, so no fan-out creeps back
    /// in and quietly reclaims the budget.
    func testAColdArtistCostsABoundedNumberOfRequests() async throws {
        let recorder = StubDiscogsTransport.Recorder()
        let head = #"{"results":[{"id":7,"title":"Ekman","thumb":"https://img.test/e.jpg"}]}"#
        let detail = #"{"id":7,"name":"Ekman","profile":"","uri":"https://discogs.test/7"}"#
        let releases = #"{"releases":[{"id":1,"title":"Vertigo","role":"Main","label":"Abstract Forms"}]}"#
        let catalogue = #"{"results":[{"id":1,"title":"Ekman - Vertigo","label":["Abstract Forms"],"style":["Electro"],"year":"2015"}]}"#
        let client = DiscogsClient(transport: StubDiscogsTransport(routes: [
            "type=artist": head,
            "artists/7": detail,
            "artists/7/releases": releases,
            "type=release": catalogue
        ], recorder: recorder), token: "secret")

        let store = DigStore(context: context, discogsClient: client)
        await store.enrichArtist(name: "Ekman", mbid: nil)

        let spent = recorder.requests.count
        XCTAssertGreaterThan(spent, 0, "It has to actually ask for something")
        XCTAssertLessThanOrEqual(
            spent, 12,
            "A cold artist is a search, a bundle and a neighbourhood — not a fan-out"
        )
    }

    /// The background fill must not be racing the page for the same budget.
    ///
    /// It is explicitly work nobody is waiting on — one thumbnail every
    /// second and a half, forty a minute out of sixty — and it used to run
    /// straight through a page load, so the requests somebody was waiting for
    /// queued behind the ones they were not.
    func testTheBackgroundFillStandsAsideWhileAPageIsLoading() async throws {
        let recorder = StubDiscogsTransport.Recorder()
        let head = #"{"results":[{"id":7,"title":"Ekman"}]}"#
        let client = DiscogsClient(transport: StubDiscogsTransport(routes: [
            "type=artist": head
        ], recorder: recorder), token: "secret")
        let store = DigStore(context: context, discogsClient: client)

        XCTAssertFalse(
            store.isDiggingInForeground,
            "Nothing is loading, so the fill is free to work"
        )

        async let dig: Void = store.enrichArtist(name: "Ekman", mbid: nil)
        await dig
        XCTAssertTrue(
            store.isDiggingInForeground,
            "A page that has just finished asking is still settling; the fill waits"
        )
    }

    // MARK: - A picture that survives changing surface

    /// A sleeve in the grid must be a sleeve on the record's own page.
    ///
    /// The two were reached by different ladders. A tile drew from the
    /// artist's catalogue listing, which carries a thumbnail and often no
    /// cover; the record's page drew from the release cache, which carried a
    /// cover and — until the thumbnail was stored — nothing else. So the same
    /// record showed a picture in one place and a blank square in the other,
    /// in both directions depending on which half happened to exist.
    func testAThumbnailAloneStillFillsTheExpandedView() throws {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Ekman"), discogsID: 7, name: "Ekman"
        )
        record.releaseTitles = ["Vertigo"]
        record.releaseYears = ["2015"]
        record.releaseDiscogsIDs = [55]
        // The listing's usual shape: a small cut and no cover at all.
        record.releaseImageURLStrings = [""]
        record.releaseThumbnailURLStrings = ["https://img.test/vertigo-150.jpg"]
        record.releaseLabels = ["Abstract Forms"]
        record.fetchedAt = Date()
        record.cacheVersion = 6
        context.insert(record)
        try context.save()

        let line = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Ekman", mbid: nil)
                .releases.first { $0.title == "Vertigo" }
        )
        XCTAssertNotNil(line.previewURL, "The tile has the small cut")
        XCTAssertNotNil(
            line.coverURL,
            "A record with only a thumbnail must not open onto an empty frame"
        )

        // And the record's own page reaches the same picture, though it is
        // filed on the artist rather than on the release.
        let sleeve = DigArtwork(context: context).release(title: "Vertigo", artist: "Ekman")
        XCTAssertFalse(
            sleeve.isEmpty,
            "The ladder must look at the artist's listing, which is where the grid found it"
        )
    }

    /// And the other direction: a cover with no small cut.
    func testACoverWithNoThumbnailStillFillsTheTile() throws {
        let release = DiscogsReleaseRecord(discogsID: 55, title: "Vertigo")
        release.artistNames = ["Ekman"]
        release.labelNames = ["Abstract Forms"]
        release.imageURLString = "https://img.test/vertigo.jpg"
        context.insert(release)

        let artist = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Ekman"), discogsID: 7, name: "Ekman"
        )
        artist.releaseTitles = ["Vertigo"]
        artist.releaseYears = ["2015"]
        artist.releaseDiscogsIDs = [55]
        artist.releaseImageURLStrings = [""]
        artist.releaseThumbnailURLStrings = [""]
        artist.releaseLabels = ["Abstract Forms"]
        artist.fetchedAt = Date()
        artist.cacheVersion = 6
        context.insert(artist)
        try context.save()

        let line = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Ekman", mbid: nil)
                .releases.first { $0.title == "Vertigo" }
        )
        XCTAssertNotNil(line.coverURL, "The record's own page has the cover")
        XCTAssertNotNil(
            line.previewURL,
            "A record with only a cover must not leave the tile blank"
        )
    }

    /// The small cut arrives in the same response as the cover, and used to be
    /// thrown away — which left the release cache able to answer only half the
    /// question wherever it was asked.
    func testAFetchedReleaseKeepsBothHalvesOfItsSleeve() throws {
        let body = #"{"id":55,"title":"Vertigo","images":[{"type":"primary","uri":"https://img.test/v.jpg","uri150":"https://img.test/v-150.jpg"}]}"#
        let detail = try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(body.utf8))
        let stored = DiscogsEnricher(
            context: context, client: DiscogsClient(transport: StubDiscogsTransport(
                routes: [:], recorder: StubDiscogsTransport.Recorder()
            ), token: "secret")
        ).store(detail, id: 55)

        XCTAssertEqual(stored.imageURL?.absoluteString, "https://img.test/v.jpg")
        XCTAssertEqual(
            stored.thumbnailURL?.absoluteString, "https://img.test/v-150.jpg",
            "The small cut came free with the cover and must be kept"
        )
    }

    /// Rows that open onto nothing must not be offered at all.
    ///
    /// Discogs files two artists who share a name as "Bing" and "Bing (14)",
    /// and marks a variant credit with an asterisk — "Flowdan*", "VA*".
    /// Those marks belong to their database, not to the artist, and carried
    /// into the app they became connections nothing is filed under: every one
    /// of them opened onto an empty page.
    func testDiscogsFilingMarksNeverBecomeArtistNames() throws {
        let body = """
        {"results":[
          {"id":1,"title":"Bing (14) - A Record"},
          {"id":2,"title":"Flowdan* - Another Record"},
          {"id":3,"title":"Ineffekt (2) - Third"},
          {"id":4,"title":"Space Afrika - Honest Labour"}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            DiscogsSearchResponse.self, from: Data(body.utf8)
        )
        let names = DiscogsClient.neighbours(from: decoded.results ?? []).map(\.name)

        XCTAssertEqual(names, ["Bing", "Flowdan", "Ineffekt", "Space Afrika"])
        XCTAssertFalse(
            names.contains { $0.contains("(") || $0.hasSuffix("*") },
            "A name carrying Discogs' filing marks opens onto nothing: \(names)"
        )
    }

    /// Cleaning the fetch is not enough.
    ///
    /// An artist cached before the fix keeps "Bing (14)" and "Hayden James,
    /// Bob Moses (5)" in their stored neighbour lists, and those rows are the
    /// ones on the page. Names have to be put right where they are read, not
    /// only where they are written, or the fix only reaches data nobody has.
    func testNamesAlreadyStoredAreCleanedOnTheWayOut() throws {
        let subject = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Skee Mask"), discogsID: 1, name: "Skee Mask"
        )
        subject.labelNames = ["Ilian Tape"]
        subject.styles = ["Techno"]
        // Written by an older build, exactly as it would still be on disk.
        subject.labelNeighbourNames = ["Bing (14)", "Hayden James, Bob Moses (5)", "Flowdan*"]
        subject.collaboratorNames = ["Ineffekt (2)"]
        context.insert(subject)
        try context.save()

        let names = Set(DigEngine(context: context).relatedArtists(to: "Skee Mask").map(\.name))
        XCTAssertFalse(
            names.contains { $0.contains("(") || $0.hasSuffix("*") },
            "Stored names must be cleaned on the way out too: \(names.sorted())"
        )
        XCTAssertTrue(names.contains("Bing"))
        XCTAssertTrue(names.contains("Hayden James"), "A compound credit becomes its artists")
        XCTAssertTrue(names.contains("Ineffekt"))
    }

    /// The page's own title must not carry a filing number.
    ///
    /// A row cached before the fix still holds "Oliwa (2)" in `name`, and
    /// that is what the artist's own page is titled with — the one place a
    /// Discogs disambiguator is most obviously not the artist's name.
    func testAPageIsNotTitledWithAFilingNumber() throws {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Oliwa"), discogsID: 1, name: "Oliwa (2)"
        )
        record.realName = "Sebastian Oliwa"
        record.releaseTitles = ["A Record"]
        record.releaseYears = ["2020"]
        record.releaseDiscogsIDs = [7]
        record.releaseImageURLStrings = [""]
        record.releaseThumbnailURLStrings = [""]
        record.releaseLabels = [""]
        context.insert(record)
        try context.save()

        let profile = DigEngine(context: context).artistProfile(name: "Oliwa", mbid: nil)
        XCTAssertEqual(profile.name, "Oliwa")
    }

    /// A cleaned name must still find what was stored under the dirty one.
    ///
    /// Portraits, catalogue rows and neighbour pictures were all filed under
    /// the name as Discogs gave it. Cleaning the name for display changed the
    /// key they are looked up by, so the rows went blank — the picture was
    /// there the whole time, under the old key.
    func testAPortraitStoredUnderTheOldNameIsStillFound() throws {
        let subject = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Skee Mask"), discogsID: 1, name: "Skee Mask"
        )
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Bing (14)"]
        subject.labelNeighbourImageURLStrings = ["https://img.test/bing.jpg"]
        context.insert(subject)

        // Filed by the background portrait fill under the name as it was.
        let portrait = ArtistPortrait(
            nameKey: RecordingKey.normalizeArtist("Bing (14)"), name: "Bing (14)"
        )
        portrait.imageURLString = "https://img.test/portrait.jpg"
        context.insert(portrait)
        try context.save()

        let peer = try XCTUnwrap(
            DigEngine(context: context).relatedArtists(to: "Skee Mask")
                .first { $0.name == "Bing" }
        )
        XCTAssertNotNil(peer.imageURL, "The row's picture was stored under the uncleaned key")
    }

    /// DEEP must not offer a row that cannot be opened.
    ///
    /// Style nodes had no destination in `AppState` and no neighbours in
    /// `compute`, so every one of them was a dead end — and each was an edge
    /// to build, store and walk on the way to being useless.
    func testStylesAreNotOfferedAsPlacesToGo() throws {
        let record = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Skee Mask"), discogsID: 1, name: "Skee Mask"
        )
        record.styles = ["Techno", "Ambient"]
        record.labelNames = ["Ilian Tape"]
        context.insert(record)
        try context.save()

        let edges = GraphStore(context: context).compute(.artist("Skee Mask")).all
        XCTAssertFalse(
            edges.contains { $0.to.kind == .style },
            "A style is a lens, not a place: \(edges.map(\.to.title))"
        )
    }

    /// A release credit is not an artist.
    ///
    /// Rows read straight off a release title said "Hayden James, Bob Moses
    /// (5)" and "Flight Facilities With Emma Louise". Both showed a sleeve
    /// and then opened onto an empty page, because nothing is filed under
    /// either string.
    func testACompoundCreditBecomesTheArtistsInIt() {
        XCTAssertEqual(
            DiscogsClient.creditedNames("Hayden James, Bob Moses (5)"),
            ["Hayden James", "Bob Moses"]
        )
        XCTAssertEqual(
            DiscogsClient.creditedNames("Flight Facilities With Emma Louise"),
            ["Flight Facilities", "Emma Louise"]
        )
        XCTAssertEqual(
            DiscogsClient.creditedNames("Thrupence / Jack Vanzet"),
            ["Thrupence", "Jack Vanzet"]
        )
    }

    /// Every shape the marks actually arrive in.
    ///
    /// Taken from what was still on screen after the first attempt: an
    /// asterisk in the middle of a joint credit, a number on an artist's own
    /// page title, and a comma-joined pair whose halves were both already
    /// listed separately.
    func testTheMarksAreStrippedWhereverTheyAppear() {
        XCTAssertEqual(
            DiscogsClient.creditedNames("Sima Kim* & Saito Koji"),
            ["Sima Kim", "Saito Koji"]
        )
        XCTAssertEqual(
            DiscogsClient.creditedNames("Typsy Panthre, The Starfolk (2)"),
            ["Typsy Panthre", "The Starfolk"]
        )
        XCTAssertEqual(DiscogsClient.withoutDisambiguator("Oliwa (2)"), "Oliwa")
        XCTAssertEqual(DiscogsClient.withoutDisambiguator("Danny Miller (2)"), "Danny Miller")
        XCTAssertEqual(DiscogsClient.withoutDisambiguator("Flowdan*"), "Flowdan")
    }

    /// But a comma alone does not make a collaboration.
    ///
    /// Cutting "Earth, Wind & Fire" into pieces would replace one row that
    /// works with three that do not, which is the same fault the other way
    /// round. Commas are honoured only where Discogs has marked the credit
    /// as a collaboration itself.
    func testAnActWithACommaInItsNameIsLeftAlone() {
        XCTAssertEqual(
            DiscogsClient.creditedNames("Earth, Wind & Fire"), ["Earth, Wind & Fire"]
        )
        XCTAssertEqual(
            DiscogsClient.creditedNames("Blood, Sweat & Tears"), ["Blood, Sweat & Tears"]
        )
        XCTAssertEqual(DiscogsClient.creditedNames("Space Afrika"), ["Space Afrika"])
    }

    /// A name Discogs has never heard of opened a stranger's page — their
    /// portrait, their biography, their discography — because the search
    /// fell back to whatever ranked first.
    func testAnUnknownNameMatchesNobody() throws {
        let body = """
        {"results":[{"id":9,"title":"Someone Else Entirely"},
                    {"id":8,"title":"Another Person"}]}
        """
        let decoded = try JSONDecoder().decode(
            DiscogsSearchResponse.self, from: Data(body.utf8)
        )
        XCTAssertNil(
            DiscogsClient.bestArtistMatch(
                name: "Nobody By That Name", results: decoded.results ?? []
            ),
            "A name that did not match must not open somebody else's page"
        )
    }

    /// Discogs disambiguates duplicate names with a bracketed number. That
    /// belongs to their database, not to the artist, so the real one still
    /// matches the name as written.
    func testDiscogsOwnDisambiguatorStillMatches() throws {
        let body = """
        {"results":[{"id":2,"title":"Bandulu Records"},{"id":1,"title":"Bandulu (3)"}]}
        """
        let decoded = try JSONDecoder().decode(
            DiscogsSearchResponse.self, from: Data(body.utf8)
        )
        XCTAssertEqual(
            DiscogsClient.bestArtistMatch(
                name: "Bandulu", results: decoded.results ?? []
            )?.id,
            1
        )
    }
}
