//
//  IndigoTests.swift
//  IndigoTests
//

import AVFoundation
import SwiftData
import XCTest
@testable import Indigo

@MainActor
final class LibraryIndexingTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: Schema([Track.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        container = nil
    }

    // MARK: Fixtures

    /// Writes a short silent WAV. No tags at all, which is exactly the case
    /// the filename/folder fallback exists for.
    private func writeAudio(_ relativePath: String, seconds: Double = 1.0) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func fetchTracks() throws -> [Track] {
        try ModelContext(container).fetch(
            FetchDescriptor<Track>(sortBy: [SortDescriptor(\Track.path)])
        )
    }

    // MARK: Tests

    func testScanIndexesFilesAndFallsBackToFolderStructure() async throws {
        _ = try writeAudio("Miles Davis/Kind of Blue/01 So What.wav")
        _ = try writeAudio("Miles Davis/Kind of Blue/02 - Freddie Freeloader.wav")
        _ = try writeAudio("loose track.wav")

        let indexer = LibraryIndexer(modelContainer: container)
        let summary = try await indexer.scan(root: root, generation: 1) { _ in }

        XCTAssertEqual(summary.indexed, 3)
        XCTAssertEqual(summary.removed, 0)

        let tracks = try fetchTracks()
        XCTAssertEqual(tracks.count, 3)

        let soWhat = try XCTUnwrap(tracks.first { $0.title == "So What" })
        XCTAssertEqual(soWhat.trackNumber, 1)
        XCTAssertEqual(soWhat.album, "Kind of Blue")
        XCTAssertEqual(soWhat.artist, "Miles Davis")
        XCTAssertEqual(soWhat.relativePath, "Miles Davis/Kind of Blue/01 So What.wav")
        XCTAssertGreaterThan(soWhat.duration, 0.5)

        let freddie = try XCTUnwrap(tracks.first { $0.trackNumber == 2 })
        XCTAssertEqual(freddie.title, "Freddie Freeloader")

        // A file directly under the root has no folder to borrow from.
        let loose = try XCTUnwrap(tracks.first { $0.title == "loose track" })
        XCTAssertEqual(loose.artist, "Unknown Artist")
        XCTAssertEqual(loose.album, "Unknown Album")
    }

    func testRescanLeavesUnchangedFilesAlone() async throws {
        _ = try writeAudio("Artist/Album/01 One.wav")
        _ = try writeAudio("Artist/Album/02 Two.wav")

        let indexer = LibraryIndexer(modelContainer: container)
        _ = try await indexer.scan(root: root, generation: 1) { _ in }
        let summary = try await indexer.scan(root: root, generation: 2) { _ in }

        XCTAssertEqual(summary.indexed, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.unchanged, 2)
        XCTAssertEqual(try fetchTracks().count, 2, "Rescans must not duplicate rows")
    }

    func testDeletedFilesArePrunedOnRescan() async throws {
        _ = try writeAudio("Artist/Album/01 One.wav")
        let doomed = try writeAudio("Artist/Album/02 Two.wav")

        let indexer = LibraryIndexer(modelContainer: container)
        _ = try await indexer.scan(root: root, generation: 1) { _ in }
        try FileManager.default.removeItem(at: doomed)
        let summary = try await indexer.scan(root: root, generation: 2) { _ in }

        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(try fetchTracks().map(\.title), ["One"])
    }

    func testUnsupportedFilesAreIgnored() async throws {
        _ = try writeAudio("Artist/Album/01 One.wav")
        try "not audio".write(
            to: root.appendingPathComponent("Artist/Album/notes.txt"),
            atomically: true, encoding: .utf8
        )

        let indexer = LibraryIndexer(modelContainer: container)
        let summary = try await indexer.scan(root: root, generation: 1) { _ in }
        XCTAssertEqual(summary.indexed, 1)
    }

    func testMissingFolderThrowsRatherThanCrashing() async throws {
        let indexer = LibraryIndexer(modelContainer: container)
        let ghost = root.appendingPathComponent("does-not-exist")
        do {
            _ = try await indexer.scan(root: ghost, generation: 1) { _ in }
            XCTFail("Expected a folderMissing error")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .folderMissing)
        }
    }

    func testProgressIsReported() async throws {
        for index in 1...5 {
            _ = try writeAudio("Artist/Album/0\(index) Track.wav", seconds: 0.2)
        }
        let indexer = LibraryIndexer(modelContainer: container)
        let (stream, feed) = AsyncStream<ScanProgress>.makeStream()
        let collector = Task { await stream.reduce(into: [ScanProgress]()) { $0.append($1) } }

        _ = try await indexer.scan(root: root, generation: 1) { feed.yield($0) }
        feed.finish()

        let updates = await collector.value
        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates.last?.filesTotal, 5)
        XCTAssertEqual(updates.last?.filesProcessed, 5)
        XCTAssertEqual(updates.last?.fraction, 1.0)
    }
}

// MARK: - Grouping

@MainActor
final class LibraryGroupingTests: XCTestCase {
    private func track(title: String, artist: String, albumArtist: String = "",
                       album: String, disc: Int = 1, number: Int, year: Int = 0) -> Track {
        Track(path: "/tmp/\(album)-\(number).mp3", relativePath: "\(album)/\(number).mp3",
              title: title, artist: artist, albumArtist: albumArtist, album: album,
              genre: "", trackNumber: number, discNumber: disc, year: year, duration: 100,
              fileModified: .distantPast, fileSize: 1, artworkKey: nil, scanGeneration: 1)
    }

    func testAlbumsGroupAndOrderByDiscThenTrack() {
        let tracks = [
            track(title: "B", artist: "Miles Davis", album: "Kind of Blue", disc: 1, number: 2, year: 1959),
            track(title: "A", artist: "Miles Davis", album: "Kind of Blue", disc: 1, number: 1, year: 1959),
            track(title: "C", artist: "Miles Davis", album: "Kind of Blue", disc: 2, number: 1, year: 1959)
        ]
        let albums = LibraryGrouping.albums(from: tracks)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].trackCount, 3)
        XCTAssertEqual(albums[0].year, 1959)
        XCTAssertEqual(LibraryGrouping.sortedForAlbum(tracks).map(\.title), ["A", "B", "C"])
    }

    func testCompilationsCollapseToVariousArtists() {
        let tracks = [
            track(title: "One", artist: "Artist A", album: "A Compilation", number: 1),
            track(title: "Two", artist: "Artist B", album: "A Compilation", number: 2)
        ]
        XCTAssertEqual(LibraryGrouping.albums(from: tracks).first?.artist, "Various Artists")
    }

    func testAlbumArtistWinsOverPerTrackArtist() {
        let tracks = [
            track(title: "One", artist: "Guest", albumArtist: "Host", album: "Split", number: 1),
            track(title: "Two", artist: "Host", albumArtist: "Host", album: "Split", number: 2)
        ]
        let artists = LibraryGrouping.artists(from: tracks)
        XCTAssertEqual(artists.map(\.name), ["Host"])
        XCTAssertEqual(artists[0].trackCount, 2)
    }

    func testSearchIndexCoversTitleArtistAndAlbum() {
        let track = track(title: "So What", artist: "Miles Davis", album: "Kind of Blue", number: 1)
        XCTAssertTrue(track.searchIndex.contains(LibraryKey.normalize("so what")))
        XCTAssertTrue(track.searchIndex.contains(LibraryKey.normalize("MILES")))
        XCTAssertTrue(track.searchIndex.contains(LibraryKey.normalize("kind of blue")))
        XCTAssertFalse(track.searchIndex.contains(LibraryKey.normalize("coltrane")))
    }

    func testGroupingKeysIgnoreCaseAndAccents() {
        XCTAssertEqual(LibraryKey.normalize("Björk"), LibraryKey.normalize("bjork"))
        XCTAssertEqual(
            LibraryKey.album(album: "Vespertine", albumArtist: "Björk"),
            LibraryKey.album(album: "VESPERTINE", albumArtist: "Bjork")
        )
    }
}

// MARK: - Queue

final class PlaybackQueueTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, sourceID: "local", kind: .track, title: id,
                  playbackURL: URL(fileURLWithPath: "/tmp/\(id).mp3"), duration: 60)
    }

    func testAdvanceAndRewindStayInBounds() {
        var queue = PlaybackQueue()
        queue.load([item("a"), item("b"), item("c")], startingAt: 1)

        XCTAssertEqual(queue.current?.id, "b")
        XCTAssertTrue(queue.hasNext)
        XCTAssertTrue(queue.hasPrevious)

        XCTAssertEqual(queue.advance()?.id, "c")
        XCTAssertFalse(queue.hasNext)
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.current?.id, "c", "A failed advance must not move the cursor")

        XCTAssertEqual(queue.rewind()?.id, "b")
        XCTAssertEqual(queue.rewind()?.id, "a")
        XCTAssertNil(queue.rewind())
    }

    func testOutOfRangeStartClampsToFirst() {
        var queue = PlaybackQueue()
        queue.load([item("a"), item("b")], startingAt: 99)
        XCTAssertEqual(queue.current?.id, "a")
    }

    func testLoadSingleReplacesTheQueue() {
        var queue = PlaybackQueue()
        queue.load([item("a"), item("b"), item("c")], startingAt: 0)
        queue.loadSingle(item("nts.1"))
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertFalse(queue.hasNext)
        XCTAssertEqual(queue.current?.id, "nts.1")
    }

    func testUpNextExcludesTheCurrentItem() {
        var queue = PlaybackQueue()
        queue.load([item("a"), item("b"), item("c")], startingAt: 0)
        XCTAssertEqual(queue.upNext.map(\.id), ["b", "c"])
    }
}

// MARK: - NTS

final class NTSDecodingTests: XCTestCase {
    /// Trimmed from a real https://www.nts.live/api/v2/live response.
    private let payload = """
    {"results":[
      {"channel_name":"1",
       "now":{"broadcast_title":"DEBT &amp; REFUGE","start_timestamp":"2026-08-27T18:00:00+01:00",
              "end_timestamp":"2026-08-27T20:00:00+01:00",
              "embeds":{"details":{"name":"Debt &amp; Refuge","description":"Two hours of it.",
                        "location_long":"London","location_short":"LDN",
                        "genres":[{"id":"genres-uk-drill","value":"UK Drill"}],
                        "moods":[{"id":"moods-max","value":"MAXIMUM EFFORT"}],
                        "media":{"picture_large":"https://media.example/1600.jpg",
                                 "picture_medium":"https://media.example/400.jpg"}}}},
       "next":{"broadcast_title":"SLIME FM","start_timestamp":"2026-08-27T20:00:00+01:00",
               "end_timestamp":"2026-08-27T21:00:00+01:00","embeds":{"details":{"name":"Slime FM"}}}},
      {"channel_name":"2","now":{"broadcast_title":"HE4RTBROKEN","embeds":{"details":{}}}}
    ]}
    """

    private func decode() throws -> NTSLiveResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NTSLiveResponse.self, from: Data(payload.utf8))
    }

    func testDecodesBothChannels() throws {
        let response = try decode()
        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.results.map(\.channelName), ["1", "2"])
    }

    func testMapsToRadioShowAndUnescapesTitles() throws {
        let show = try XCTUnwrap(decode().results[0].now?.asRadioShow())
        XCTAssertEqual(show.title, "DEBT & REFUGE")
        XCTAssertEqual(show.host, "Debt & Refuge")
        XCTAssertEqual(show.location, "London")
        XCTAssertEqual(show.genres, ["UK Drill"])
        XCTAssertEqual(show.moods, ["MAXIMUM EFFORT"])
        XCTAssertEqual(show.artworkURL?.absoluteString, "https://media.example/1600.jpg")
        XCTAssertNotNil(show.startsAt)
        XCTAssertNotNil(show.endsAt)
    }

    func testElapsedFractionTracksTheBroadcastWindow() throws {
        let show = try XCTUnwrap(decode().results[0].now?.asRadioShow())
        let start = try XCTUnwrap(show.startsAt)
        let halfway = start.addingTimeInterval(3600)
        XCTAssertEqual(try XCTUnwrap(show.elapsedFraction(at: halfway)), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(show.elapsedFraction(at: start.addingTimeInterval(-60))), 0)
        XCTAssertEqual(try XCTUnwrap(show.elapsedFraction(at: start.addingTimeInterval(99_999))), 1)
    }

    func testMissingMetadataDoesNotBreakMapping() throws {
        let show = try XCTUnwrap(decode().results[1].now?.asRadioShow())
        XCTAssertEqual(show.title, "HE4RTBROKEN")
        XCTAssertNil(show.artworkURL)
        XCTAssertNil(show.slot)
        XCTAssertTrue(show.genres.isEmpty)
    }

    func testHTMLEntityDecoding() {
        XCTAssertEqual(HTMLText.decode("Debt &amp; Refuge"), "Debt & Refuge")
        XCTAssertEqual(HTMLText.decode("OMICHIVE&#8217;S BOOKSHELF"), "OMICHIVE\u{2019}S BOOKSHELF")
        XCTAssertEqual(HTMLText.decode("no entities here"), "no entities here")
        XCTAssertEqual(HTMLText.decode("a &notreal; b"), "a &notreal; b")
        XCTAssertEqual(HTMLText.decode("bare & ampersand"), "bare & ampersand")
    }
}

// MARK: - Formatting

@MainActor
final class FormattingTests: XCTestCase {
    func testClockHandlesHoursMinutesAndNonsense() {
        XCTAssertEqual(TimeFormat.clock(0), "0:00")
        XCTAssertEqual(TimeFormat.clock(61), "1:01")
        XCTAssertEqual(TimeFormat.clock(3661), "1:01:01")
        XCTAssertEqual(TimeFormat.clock(nil), "--:--")
        XCTAssertEqual(TimeFormat.clock(.nan), "--:--")
        XCTAssertEqual(TimeFormat.clock(.infinity), "--:--")
        XCTAssertEqual(TimeFormat.clock(-5), "--:--")
    }
}

// MARK: - Playback

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-play-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func silentTrack(_ name: String, seconds: Double) throws -> MediaItem {
        let url = root.appendingPathComponent("\(name).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)

        return MediaItem(id: url.path, sourceID: Track.sourceID, kind: .track, title: name,
                         subtitle: "Test", playbackURL: url, duration: seconds)
    }

    private func liveStation() -> MediaItem {
        MediaItem(id: "nts.1", sourceID: "nts", kind: .radioStation, title: "NTS 1",
                  subtitle: "Live", playbackURL: URL(string: "https://example.invalid/stream")!)
    }

    /// A throwaway defaults suite so tests never write the user's real volume.
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "indigo.tests.\(UUID().uuidString)") ?? .standard
    }

    /// Polls rather than sleeping a fixed amount, so the tests stay quick.
    private func wait(_ description: String, timeout: TimeInterval = 8,
                      until condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    func testQueueAdvancesToTheNextTrackOnItsOwn() async throws {
        let first = try silentTrack("one", seconds: 0.7)
        let second = try silentTrack("two", seconds: 2.0)

        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)
        player.play([first, second], startingAt: 0)

        XCTAssertEqual(player.source, .local)
        XCTAssertEqual(player.current?.id, first.id)
        XCTAssertTrue(player.canSkipNext)
        XCTAssertTrue(player.canSeek)

        try await wait("first track to start") { player.isPlaying }
        try await wait("automatic advance to the second track") { player.current?.id == second.id }
        XCTAssertFalse(player.canSkipNext, "The second track is the end of the queue")

        player.pause()
        player.stopAll()
    }

    func testSkippingPastTheEndStopsWithoutLosingTheItem() async throws {
        let only = try silentTrack("only", seconds: 3.0)
        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)
        player.play([only], startingAt: 0)
        try await wait("playback to start") { player.isPlaying }

        player.next()
        try await wait("playback to stop at the end of the queue") { !player.isPlaying }
        XCTAssertEqual(player.current?.id, only.id, "The bar should still show what was playing")
        player.stopAll()
    }

    func testSwitchingToRadioStopsLocalPlaybackAndDisablesSeeking() async throws {
        let track = try silentTrack("local", seconds: 5.0)
        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)
        player.play([track], startingAt: 0)
        try await wait("local playback to start") { player.isPlaying }

        player.playRadio(liveStation())

        XCTAssertEqual(player.source, .stream)
        XCTAssertTrue(player.isLive)
        XCTAssertEqual(player.current?.id, "nts.1")
        XCTAssertFalse(player.canSeek, "Live radio must not be seekable")
        XCTAssertFalse(player.canSkipNext)
        XCTAssertFalse(player.canSkipPrevious)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.duration, 0)
        player.stopAll()
    }

    func testSwitchingBackToALocalTrackLeavesRadioBehind() async throws {
        let track = try silentTrack("back", seconds: 3.0)
        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)

        player.playRadio(liveStation())
        XCTAssertEqual(player.source, .stream)

        player.play([track], startingAt: 0)
        XCTAssertEqual(player.source, .local)
        XCTAssertEqual(player.current?.id, track.id)
        XCTAssertTrue(player.canSeek)
        try await wait("local playback to resume after radio") { player.isPlaying }
        player.stopAll()
    }

    func testUnplayableFileSkipsForwardInsteadOfStalling() async throws {
        let broken = MediaItem(
            id: "/broken.wav", sourceID: Track.sourceID, kind: .track, title: "Broken",
            playbackURL: root.appendingPathComponent("missing.wav"), duration: 10
        )
        let good = try silentTrack("recovered", seconds: 2.0)

        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)
        player.play([broken, good], startingAt: 0)

        try await wait("skip past the unplayable file") { player.current?.id == good.id }
        XCTAssertNotNil(player.notice, "The failure should be surfaced, not swallowed")
        player.stopAll()
    }

    func testStopAllClearsTheBar() async throws {
        let track = try silentTrack("clear", seconds: 3.0)
        let player = PlaybackCoordinator(defaults: scratchDefaults())
        player.setVolume(0)
        player.play([track], startingAt: 0)
        try await wait("playback to start") { player.isPlaying }

        player.stopAll()
        XCTAssertNil(player.current)
        XCTAssertEqual(player.source, .none)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasSomethingLoaded)
    }

    // Note: don't construct a second PlaybackCoordinator inside an assertion.
    // Under XCTest host injection on macOS 15.x, releasing an app-module
    // main-actor class inside an autoclosure aborts in the concurrency runtime.
    // The shipping app is unaffected — it releases the same types fine.
    func testVolumeIsClampedAndPersisted() async throws {
        let suiteName = "indigo.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = PlaybackCoordinator(defaults: defaults)
        player.setVolume(2.5)
        XCTAssertEqual(player.volume, 1)
        player.setVolume(-1)
        XCTAssertEqual(player.volume, 0)
        player.setVolume(0.5)
        XCTAssertEqual(player.volume, 0.5)
        XCTAssertEqual(
            defaults.double(forKey: PlaybackCoordinator.volumeKey), 0.5,
            "Volume should be persisted for the next launch"
        )
        player.stopAll()
    }
}
