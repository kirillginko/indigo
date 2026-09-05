//
//  YouTubeTests.swift
//  IndigoTests
//
//  YouTube's terms permit playback in their player and prohibit resolving the
//  underlying stream, so Indigo plays through the official IFrame API exactly
//  as it does with SoundCloud and Mixcloud. All this file has to get right is
//  finding the video's identity and refusing anything that is not one.
//

import XCTest
import SwiftData
@testable import Indigo

final class YouTubeTests: XCTestCase {
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

    /// Discogs links these in every shape people paste them in.
    func testAVideoIsFoundInEveryShapeTheLinkTakes() throws {
        let expected = "irfj8pQwhno"
        for address in [
            "https://www.youtube.com/watch?v=irfj8pQwhno",
            "https://www.youtube.com/watch?v=irfj8pQwhno&t=90s",
            "https://youtu.be/irfj8pQwhno",
            "https://youtu.be/irfj8pQwhno?t=12",
            "https://www.youtube.com/embed/irfj8pQwhno",
            "https://www.youtube.com/shorts/irfj8pQwhno",
            "https://www.youtube-nocookie.com/embed/irfj8pQwhno",
            "https://m.youtube.com/watch?v=irfj8pQwhno"
        ] {
            XCTAssertEqual(YouTubeLink.videoID(from: try XCTUnwrap(URL(string: address))),
                           expected, address)
        }
    }

    /// Anything else handed to the player is a blank frame the listener has no
    /// way to interpret, so it is refused before it gets there.
    func testAnythingThatIsNotAVideoIsRefused() throws {
        for address in [
            "https://www.youtube.com/",
            "https://www.youtube.com/watch?v=tooshort",
            "https://www.youtube.com/@someChannel",
            "https://soundcloud.com/lyl_radio/something",
            "https://evil.example/watch?v=irfj8pQwhno"
        ] {
            XCTAssertNil(YouTubeLink.videoID(from: try XCTUnwrap(URL(string: address))), address)
        }
    }

    /// A release carries whatever whoever catalogued it linked. Only the
    /// YouTube ones are playable here, and the rest must not become empty rows.
    func testOnlyPlayableRecordingsAreOffered() throws {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "Compro")
        record.videoURLStrings = [
            "https://www.youtube.com/watch?v=irfj8pQwhno",
            "https://vimeo.com/123456",
            "not a url at all"
        ]
        record.videoTitles = ["Skee Mask : Compro", "Something Else", ""]
        record.videoDurations = [3900, 200, 0]
        context.insert(record)

        let videos = record.videos
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.title, "Skee Mask : Compro")
        XCTAssertEqual(videos.first?.seconds, 3900)
    }

    /// The same recording is often attached to a pressing and to its reissue.
    /// Listing it twice makes a catalogue look padded.
    func testAnArtistsRecordingsAreGatheredNewestFirstWithoutRepeats() throws {
        let recent = DiscogsReleaseRecord(discogsID: 1, title: "Pool")
        recent.artistNames = ["Skee Mask"]
        recent.year = 2021
        recent.videoURLStrings = ["https://www.youtube.com/watch?v=aaaaaaaaaaa"]
        recent.videoTitles = ["Pool Track"]
        recent.videoDurations = [300]
        context.insert(recent)

        let older = DiscogsReleaseRecord(discogsID: 2, title: "Compro")
        older.artistNames = ["Skee Mask"]
        older.year = 2018
        older.videoURLStrings = [
            "https://www.youtube.com/watch?v=bbbbbbbbbbb",
            "https://www.youtube.com/watch?v=aaaaaaaaaaa"
        ]
        older.videoTitles = ["Compro Track", "Pool Track Again"]
        older.videoDurations = [400, 300]
        context.insert(older)

        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 9, name: "Skee Mask")
        context.insert(artist)

        let listen = DigEngine(context: context).artistProfile(name: "Skee Mask", mbid: nil).listen
        XCTAssertEqual(listen.map(\.title), ["Pool Track", "Compro Track"])
    }

    func testTheProviderNamesItself() {
        XCTAssertEqual(EmbedProvider.youtube.displayName, "YouTube")
        XCTAssertEqual(EmbedProvider(rawValue: "youtube"), .youtube)
    }

    /// YouTube returns the same code for "the owner disabled embedding" and
    /// "this origin is not allowed", so the app must not confidently tell the
    /// listener the first when it might be the second — and the codes that do
    /// mean different things must not be flattened into one message.
    func testFailuresAreToldApart() {
        let gone = EmbedFailure(reported: "youtube:100:That recording is no longer on YouTube.")
        XCTAssertEqual(gone.message, "That recording is no longer on YouTube.")
        XCTAssertTrue(gone.isRecordingSpecific)

        let refused = EmbedFailure(reported: "youtube:150:The uploader does not allow this one to play outside YouTube.")
        XCTAssertTrue(refused.isRecordingSpecific)

        // Anything else is the player, not the recording — stopping and saying
        // so is right, and skipping would hide a real fault.
        let broken = EmbedFailure(reported: "youtube:5:YouTube could not play that one.")
        XCTAssertFalse(broken.isRecordingSpecific)
        XCTAssertEqual(broken.message, "YouTube could not play that one.")
    }

    /// A message from a provider that does not report codes has to survive
    /// untouched — including one that happens to contain colons.
    func testAPlainMessageIsLeftAlone() {
        let plain = EmbedFailure(reported: "SoundCloud refused to play this episode.")
        XCTAssertEqual(plain.message, "SoundCloud refused to play this episode.")
        XCTAssertFalse(plain.isRecordingSpecific)

        let colons = EmbedFailure(reported: "Error: could not reach: the player")
        XCTAssertEqual(colons.message, "Error: could not reach: the player")
        XCTAssertFalse(colons.isRecordingSpecific)
    }

    /// The page has to claim a real https origin — every one of these widgets
    /// refuses to hand-shake from about:blank — and YouTube is passed it as
    /// `origin`, which it checks.
    func testTheBridgeClaimsARealOrigin() throws {
        let origin = try XCTUnwrap(URL(string: EmbedAudioEngine.origin))
        XCTAssertEqual(origin.scheme, "https")
        XCTAssertNotNil(origin.host())
    }

    // MARK: Not offering what will not play

    /// Being shown something and watching it skip itself is worse than never
    /// being offered it.
    func testARecordingKnownNotToPlayIsNotOffered() throws {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "Compro")
        record.videoURLStrings = [
            "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            "https://www.youtube.com/watch?v=bbbbbbbbbbb",
            "https://www.youtube.com/watch?v=ccccccccccc"
        ]
        record.videoTitles = ["Plays", "Refused", "Not asked yet"]
        record.videoDurations = [300, 300, 300]
        record.videoPlayable = [1, 2, 0]
        context.insert(record)

        XCTAssertEqual(record.videos.map(\.title), ["Plays", "Not asked yet"])
        XCTAssertEqual(record.allVideos.count, 3, "It is still on the record, just not offered")
    }

    /// Not yet asked is not the same as refused. Hiding everything until it had
    /// been checked would leave the page empty for no good reason.
    func testAnUncheckedRecordingIsStillOffered() throws {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "Compro")
        record.videoURLStrings = ["https://www.youtube.com/watch?v=aaaaaaaaaaa"]
        record.videoTitles = ["Unknown"]
        record.videoDurations = [0]
        record.videoPlayable = []
        context.insert(record)

        XCTAssertEqual(record.videos.map(\.title), ["Unknown"])
    }

    /// The layer certain to catch an uploader's embedding setting: what the
    /// player found out the hard way, remembered wherever it appears.
    @MainActor
    func testAFailureAtPlayTimeIsRememberedEverywhere() async throws {
        let address = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
        for identifier in [1, 2] {
            let record = DiscogsReleaseRecord(discogsID: identifier, title: "Release \(identifier)")
            record.videoURLStrings = [address, "https://www.youtube.com/watch?v=bbbbbbbbbbb"]
            record.videoTitles = ["Refused", "Fine"]
            record.videoDurations = [300, 300]
            context.insert(record)
        }

        try context.save()
        await DigStore(context: context).markUnplayable(try XCTUnwrap(URL(string: address)))

        for identifier in [1, 2] {
            let record = try XCTUnwrap(
                ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
                    .first { $0.discogsID == identifier }
            )
            XCTAssertEqual(record.videos.map(\.title), ["Fine"], "Release \(identifier)")
        }
    }

    // MARK: Titles as names rather than as advertising

    /// A YouTube title is advertising as much as it is a name. What the
    /// uploader says about the upload is what every row has in common, which
    /// is the opposite of what a list of titles is for.
    func testAnUploadersBillingIsNotPartOfTheName() {
        let cases = [
            "Skee Mask - Rev8617 [Official Audio]": "Skee Mask - Rev8617",
            "Burial - Archangel (Official Video)": "Burial - Archangel",
            "Aphex Twin - Xtal [HD]": "Aphex Twin - Xtal",
            "Actress - Untitled 7 | Official Music Video": "Actress - Untitled 7",
            "Jai Paul - BTSTU (Official Audio) [HQ]": "Jai Paul - BTSTU",
            "Loraine James - Glitch Bitch - Official Video": "Loraine James - Glitch Bitch",
            "Nídia - Capa Preta (XLR8R Premiere)": "Nídia - Capa Preta",
            "Four Tet - Baby ()": "Four Tet - Baby"
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(YouTubeTitle.clean(raw), expected, raw)
        }
    }

    /// An aside that says which recording this is has to survive: a live take
    /// and a remix are different records, and flattening them loses one.
    func testAnAsideThatNamesTheRecordingSurvives() {
        for title in [
            "Skee Mask - Rev8617 (Original Mix)",
            "Objekt - Ganzfeld (Live at Dekmantel)",
            "Pariah - Drumbaya (Blawan Remix)",
            "Talk Talk - Ascension Day (Remaster)"
        ] {
            XCTAssertEqual(YouTubeTitle.clean(title), title)
        }
    }

    /// A recording whose whole title is billing keeps it. An empty row says
    /// less than a badly named one.
    func testARecordingIsNeverLeftWithoutAName() {
        XCTAssertEqual(YouTubeTitle.clean("[Official Video]"), "[Official Video]")
        XCTAssertEqual(YouTubeTitle.clean("  Compro  "), "Compro")
    }

    /// The same recording is uploaded twice — once billed, once plain — and
    /// catalogued against both a pressing and its reissue. Either way it is
    /// one recording to somebody reading the list.
    @MainActor
    func testTheSameRecordingIsListedOnce() throws {
        let recent = DiscogsReleaseRecord(discogsID: 1, title: "Pool")
        recent.artistNames = ["Skee Mask"]
        recent.year = 2021
        recent.videoURLStrings = [
            "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            // The same video, in the other shape the link takes.
            "https://youtu.be/aaaaaaaaaaa?t=30"
        ]
        recent.videoTitles = ["Rev8617 [Official Audio]", "Rev8617"]
        recent.videoDurations = [300, 300]
        context.insert(recent)

        let older = DiscogsReleaseRecord(discogsID: 2, title: "Compro")
        older.artistNames = ["Skee Mask"]
        older.year = 2018
        older.videoURLStrings = [
            // A different upload of the recording already listed above.
            "https://www.youtube.com/watch?v=bbbbbbbbbbb",
            "https://www.youtube.com/watch?v=ccccccccccc"
        ]
        older.videoTitles = ["Rev8617 (Official Video) [HD]", "Cerroverb"]
        older.videoDurations = [300, 400]
        context.insert(older)

        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 9, name: "Skee Mask")
        context.insert(artist)

        let listen = DigEngine(context: context).artistProfile(name: "Skee Mask", mbid: nil).listen
        XCTAssertEqual(listen.map(\.title), ["Rev8617", "Cerroverb"])
    }

    /// "Untitled" is the absence of a name, not a name — and white labels are
    /// full of them, so it must never collapse two different recordings.
    @MainActor
    func testUntitledRecordingsAreNotMistakenForEachOther() throws {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "White Label")
        record.artistNames = ["Anon"]
        record.year = 2019
        record.videoURLStrings = [
            "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            "https://www.youtube.com/watch?v=bbbbbbbbbbb"
        ]
        record.videoTitles = ["", ""]
        record.videoDurations = [300, 400]
        context.insert(record)

        let profile = DigEngine(context: context).releaseProfile(id: 1)
        XCTAssertEqual(profile?.listen.count, 2)
    }

    /// A dropped connection must not be recorded as a verdict about the
    /// recording, or one bad minute of network hides a catalogue.
    func testAnUnaskableQuestionIsNotAnAnswer() async throws {
        let notYouTube = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        let verdict = await YouTubeAvailability.isPlayable(notYouTube)
        XCTAssertNil(verdict, "Nil is 'could not ask', which is not 'will not play'")
    }
}
