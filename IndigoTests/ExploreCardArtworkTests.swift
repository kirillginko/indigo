//
//  ExploreCardArtworkTests.swift
//  IndigoTests
//
//  Cards on the For You page that had a picture and drew a block instead.
//
//  The placeholder is meant for a subject with no picture. Two kinds of card
//  reached it while holding one:
//
//    * A kept local file. Its artwork is a key into the artwork store rather
//      than an address, and the crate block passed only the address — so a
//      record the listener owns drew a block while the same record, two rows
//      down under "Your library", showed its sleeve.
//    * A radio show. `MediaAppearance` is the only local record of a broadcast
//      and it kept no picture at all, so every show EXPLORE offered was a
//      block, on a page whose argument is "here is something worth putting on".
//

import XCTest
import SwiftData
@testable import Indigo

final class ExploreCardArtworkTests: XCTestCase {
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

    /// `on:` so a test can re-read the same broadcast. Reading a tracklist
    /// again resolves the same recording and notes against it, which is what
    /// the merge keys on.
    @discardableResult
    private func appearance(
        show: String, artwork: URL?, artist: String, heardAt: Date = Date(),
        on existing: Recording? = nil
    ) -> Recording {
        let recording = existing ?? {
            let made = Recording(title: "A track", artistName: artist, status: .probable)
            context.insert(made)
            return made
        }()
        RecordingStore(context: context).note(
            appearance: MediaAppearance(
                providerID: "nts", showTitle: show, showID: "nts.episode.\(show)/1",
                artworkURL: artwork, heardAt: heardAt, isLive: false, method: .providerTracklist
            ),
            on: recording
        )
        return recording
    }

    // MARK: A radio show

    func testAShowCarriesThePictureItsTracklistArrivedWith() throws {
        let art = URL(string: "https://media.ntslive.co.uk/239ef.jpg")!
        appearance(show: "239ef", artwork: art, artist: "Dean Blunt")
        try context.save()

        let shows = ShowSuggestionEngine(context: context).tracklists()
        let show = try XCTUnwrap(shows.values.first { $0.title == "239ef" })
        XCTAssertEqual(show.artworkURL, art, "The card has a picture to draw")
    }

    /// The rows that already exist carry none, and cannot be backfilled from
    /// anywhere else — so reading the tracklist again has to fill them in.
    func testAnAppearanceWrittenWithoutAPictureGainsOneOnTheNextRead() throws {
        let heard = Date()
        let recording = appearance(show: "239ef", artwork: nil, artist: "Dean Blunt", heardAt: heard)
        try context.save()

        let before = try XCTUnwrap(context.fetch(FetchDescriptor<MediaAppearance>()).first)
        XCTAssertNil(before.artworkURL, "Precondition: written before pictures were kept")

        // The same broadcast read again, within the merge window.
        let art = URL(string: "https://media.ntslive.co.uk/239ef.jpg")!
        appearance(show: "239ef", artwork: art, artist: "Dean Blunt",
                   heardAt: heard.addingTimeInterval(20), on: recording)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<MediaAppearance>())
        XCTAssertEqual(rows.count, 1, "Precondition: merged rather than duplicated")
        XCTAssertEqual(rows.first?.artworkURL, art)
    }

    /// A station that changes its artwork must not rewrite what the listener
    /// actually saw.
    func testAPictureAlreadyKeptIsNotReplaced() throws {
        let heard = Date()
        let original = URL(string: "https://media.ntslive.co.uk/original.jpg")!
        let recording = appearance(show: "239ef", artwork: original,
                                   artist: "Dean Blunt", heardAt: heard)
        try context.save()

        appearance(show: "239ef", artwork: URL(string: "https://media.ntslive.co.uk/new.jpg"),
                   artist: "Dean Blunt", heardAt: heard.addingTimeInterval(20), on: recording)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<MediaAppearance>())
        XCTAssertEqual(rows.first?.artworkURL, original)
    }

    /// The case the first attempt at this missed entirely.
    ///
    /// `ingest` skips every tracklist entry it has seen before, so reading an
    /// episode a second time reaches no `note` call and the merge above never
    /// runs. The picture belongs to the show rather than to an entry, so it
    /// has to be written outside that loop — which is what a re-read of a
    /// *fully ingested* episode exercises, and nothing else does.
    func testAFullyIngestedEpisodeStillGainsItsPicture() throws {
        let heard = Date(timeIntervalSince1970: 1_600_000_000)
        let recording = Recording(title: "Sunbursting", artistName: "Bibio", status: .identified)
        context.insert(recording)
        RecordingStore(context: context).note(
            appearance: MediaAppearance(
                providerID: "nts", showTitle: "239EF", showID: "239ef/18th-october-2021",
                artworkURL: nil, heardAt: heard, isLive: false, method: .providerTracklist
            ),
            on: recording
        )
        try context.save()

        let art = URL(string: "https://media2.ntslive.co.uk/resize/1600x1600/ef188241.jpg")!
        RadioNeighborhoodEngine(context: context).ingest(
            NTSEpisodeDetailStub.make(
                showID: "239ef/18th-october-2021", name: "239EF", artwork: art,
                // The same entry that is already in the store, so every row of
                // the tracklist is skipped by the loop.
                tracklist: [("Bibio", "Sunbursting")]
            )
        )
        try context.save()

        // Asserted on the row that was already there, not on the table.
        // Whether the loop also decides to ingest something is beside the
        // point: what matters is that a row written before pictures were kept
        // gains one, and the loop is precisely what cannot do that.
        let kept = try XCTUnwrap(
            try context.fetch(FetchDescriptor<MediaAppearance>())
                .first { $0.showID == "239ef/18th-october-2021" && $0.heardAt == heard }
        )
        XCTAssertEqual(
            kept.artworkURL, art,
            "A re-read of an episode already ingested must still bring its picture"
        )
    }

    /// The whole way out to the card, which nothing covered.
    ///
    /// `tracklists()` having a picture proves only that the fold read it.
    /// What the For You page draws is `suggestion.node.artworkURL`, two hops
    /// further on, and each hop was somewhere this could be dropped: the node
    /// is built by `MusicNode.broadcast`, which takes no artwork, and the
    /// merge in `ExploreSuggestionEngine` rebuilds the suggestion around it.
    func testAShowOfferedToTheCardCarriesItsPicture() throws {
        let art = URL(string: "https://media2.ntslive.co.uk/resize/1600x1600/ef188241.jpg")!
        let recording = Recording(title: "Sunbursting", artistName: "Bibio", status: .identified)
        context.insert(recording)
        RecordingStore(context: context).note(
            appearance: MediaAppearance(
                providerID: "nts", showTitle: "239EF",
                showID: "239ef/239ef-18th-october-2021",
                artworkURL: art, heardAt: Date(), isLive: false, method: .providerTracklist
            ),
            on: recording
        )
        try context.save()

        let offered = ShowSuggestionEngine(context: context).suggestions(
            taste: TasteProfile.collected(context: context),
            known: [],
            keptArtistKeys: [RecordingKey.normalizeArtist("Bibio")]
        )
        let show = try XCTUnwrap(
            offered.first { $0.node.title == "239EF" },
            "Precondition: a show played by somebody they keep is offered at all"
        )
        XCTAssertEqual(
            show.node.artworkURL, art,
            "The card draws node.artworkURL; anything less never reaches it"
        )
    }

    func testAShowWithNoPictureAnywhereStillOffersNone() throws {
        appearance(show: "silent", artwork: nil, artist: "Dean Blunt")
        try context.save()
        let shows = ShowSuggestionEngine(context: context).tracklists()
        XCTAssertNil(shows.values.first { $0.title == "silent" }?.artworkURL)
    }
}

// MARK: - Finding the shows that still need one

/// Deliberately not `@MainActor`. `wanting(in:providerID:)` is `nonisolated`,
/// and building a `ModelContainer` per test on the main actor starved the
/// 400ms window in `PortraitFillTests.testABurstOfWritesIsAnnouncedOnce` —
/// which failed in the suite while passing alone. See `tests-run-the-apps-ui`.
final class ShowArtworkBackfillTests: XCTestCase {
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

    private func appearance(showID: String, artwork: URL?, heardAt: Date = Date()) {
        let recording = Recording(title: "A track", artistName: "Someone", status: .probable)
        context.insert(recording)
        RecordingStore(context: context).note(
            appearance: MediaAppearance(
                providerID: "nts", showTitle: showID, showID: showID,
                artworkURL: artwork, heardAt: heardAt, isLive: false, method: .providerTracklist
            ),
            on: recording
        )
    }

    func testOnlyShowsWithNoPictureAreAskedAbout() throws {
        appearance(showID: "flo/3rd-september", artwork: nil)
        appearance(showID: "239ef/aug", artwork: URL(string: "https://media.ntslive.co.uk/a.jpg"))
        try context.save()

        let wanted = ShowArtworkBackfill.wanting(in: context, providerID: "nts")
        XCTAssertEqual(wanted.map(\.show), ["flo"], "The one already pictured is left alone")
    }

    /// One episode is a dozen appearances; asking twelve times for the same
    /// picture would be twelve requests to a station doing us a favour.
    func testAShowIsAskedAboutOnceHoweverManyTracksItPlayed() throws {
        for index in 0..<12 {
            appearance(showID: "flo/3rd-september", artwork: nil,
                       heardAt: Date().addingTimeInterval(Double(index) * 600))
        }
        try context.save()
        XCTAssertEqual(ShowArtworkBackfill.wanting(in: context, providerID: "nts").count, 1)
    }

    /// A show whose rows are partly filled is done: the picture is on the
    /// show, so one row carrying it settles the rest.
    func testAShowWithAnyPictureAtAllIsNotAskedAgain() throws {
        let when = Date()
        appearance(showID: "flo/3rd-september", artwork: nil, heardAt: when)
        appearance(showID: "flo/3rd-september",
                   artwork: URL(string: "https://media.ntslive.co.uk/flo.jpg"),
                   heardAt: when.addingTimeInterval(3600))
        try context.save()
        XCTAssertTrue(ShowArtworkBackfill.wanting(in: context, providerID: "nts").isEmpty)
    }

    func testAHandleThatIsNotAnEpisodeIsSkipped() throws {
        appearance(showID: "nts.1", artwork: nil)
        try context.save()
        XCTAssertTrue(
            ShowArtworkBackfill.wanting(in: context, providerID: "nts").isEmpty,
            "A station handle is not something to fetch an episode for"
        )
    }
}

/// The smallest `NTSEpisodeDetail` these tests need.
enum NTSEpisodeDetailStub {
    static func make(
        showID: String, name: String, artwork: URL?, tracklist: [(artist: String, title: String)]
    ) -> NTSEpisodeDetail {
        let parts = showID.split(separator: "/", maxSplits: 1)
        return NTSEpisodeDetail(
            summary: NTSEpisodeSummary(
                showAlias: String(parts[0]),
                episodeAlias: String(parts.count > 1 ? parts[1] : ""),
                name: name,
                summary: nil,
                location: nil,
                genres: [],
                moods: [],
                artworkURL: artwork,
                broadcastAt: nil,
                isPublished: true
            ),
            tracklist: tracklist.enumerated().map { index, entry in
                NTSTracklistEntry(
                    id: "\(index)", artist: entry.artist, title: entry.title, offset: nil
                )
            },
            audio: []
        )
    }
}
