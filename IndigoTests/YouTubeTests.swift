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
    func testAFailureAtPlayTimeIsRememberedEverywhere() throws {
        let address = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
        for identifier in [1, 2] {
            let record = DiscogsReleaseRecord(discogsID: identifier, title: "Release \(identifier)")
            record.videoURLStrings = [address, "https://www.youtube.com/watch?v=bbbbbbbbbbb"]
            record.videoTitles = ["Refused", "Fine"]
            record.videoDurations = [300, 300]
            context.insert(record)
        }

        DigStore(context: context).markUnplayable(try XCTUnwrap(URL(string: address)))

        for identifier in [1, 2] {
            let record = try XCTUnwrap(
                ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
                    .first { $0.discogsID == identifier }
            )
            XCTAssertEqual(record.videos.map(\.title), ["Fine"], "Release \(identifier)")
        }
    }

    /// A dropped connection must not be recorded as a verdict about the
    /// recording, or one bad minute of network hides a catalogue.
    func testAnUnaskableQuestionIsNotAnAnswer() async throws {
        let notYouTube = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        let verdict = await YouTubeAvailability.isPlayable(notYouTube)
        XCTAssertNil(verdict, "Nil is 'could not ask', which is not 'will not play'")
    }
}
