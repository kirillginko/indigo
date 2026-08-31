//
//  CrateTests.swift
//  IndigoTests
//
//  The crate is the one store in the app that isn't a rebuildable cache, so
//  its promises — one press, no duplicates, provenance kept — are pinned here.
//

import XCTest
import SwiftData
@testable import Indigo

final class CrateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var crate: CrateService!
    private var recordings: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        crate = CrateService(context: context)
        recordings = RecordingStore(context: context)
    }

    override func tearDown() {
        recordings = nil
        crate = nil
        context = nil
        container = nil
    }

    // MARK: Crating music

    func testCratingIsIdempotent() throws {
        let recording = try recordings.upsert(title: "Rev8617", artistName: "Skee Mask")

        crate.add(recording: recording)
        crate.add(recording: recording)

        XCTAssertEqual(crate.count, 1)
        XCTAssertTrue(crate.contains(recording: recording))
    }

    func testToggleRemoves() throws {
        let recording = try recordings.upsert(title: "Rev8617", artistName: "Skee Mask")

        crate.toggle(recording: recording)
        XCTAssertTrue(crate.contains(recording: recording))
        crate.toggle(recording: recording)
        XCTAssertFalse(crate.contains(recording: recording))
        XCTAssertEqual(crate.count, 0)
    }

    func testDIGEntitiesCanBeCratedWithoutLocalLibraryRecords() throws {
        crate.add(
            dig: .artist, identifier: "artist-123", providerID: "dig.artist.mbid",
            title: "Seefeel", subtitle: "Artist",
            artworkURL: URL(string: "https://example.com/seefeel.jpg"), genres: ["Ambient", "Shoegaze"]
        )
        crate.add(
            dig: .release, identifier: "456", providerID: "dig.release.discogs",
            title: "Quique", subtitle: "Seefeel · 1993",
            artworkURL: URL(string: "https://example.com/quique.jpg")
        )
        crate.add(
            dig: .label, identifier: "warp", providerID: "dig.label.discogs",
            title: "Warp", subtitle: "Label", artworkURL: nil
        )

        XCTAssertEqual(crate.count, 3)
        XCTAssertEqual(Set(crate.items().map(\.kind)), [.artist, .release, .label])
        XCTAssertTrue(crate.contains(dig: .artist, identifier: "artist-123", providerID: "dig.artist.mbid"))
        XCTAssertEqual(crate.items().first(where: { $0.kind == .artist })?.genreTags, ["Ambient", "Shoegaze"])
        XCTAssertTrue(crate.items().allSatisfy { $0.recording == nil && $0.sourceLine == "DIG" })
        XCTAssertEqual(DigEngine(context: context).crateCount(artist: "Seefeel"), 1)
    }

    func testDIGEntityToggleUsesStableProviderIdentity() {
        crate.toggle(
            dig: .label, identifier: "warp", providerID: "dig.label.discogs",
            title: "Warp", subtitle: "Label", artworkURL: nil
        )
        crate.toggle(
            dig: .label, identifier: "warp", providerID: "dig.label.discogs",
            title: "Warp Records", subtitle: "Label", artworkURL: nil
        )

        XCTAssertEqual(crate.count, 0)
    }

    /// Deleting a crate entry must not delete the recording behind it — the
    /// music, and its provenance, outlive the decision to keep it.
    func testRemovingFromCrateKeepsTheRecording() throws {
        let recording = try recordings.upsert(title: "Hubble", artistName: "Actress")
        let item = crate.add(recording: recording)
        crate.remove(item)

        XCTAssertEqual(crate.count, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 1)
    }

    // MARK: Unknown music

    /// The failure flow from the spec: no match, still saveable, provenance
    /// intact.
    func testAnUnidentifiedTrackIsCratableWithItsProvenance() throws {
        let heardAt = Date(timeIntervalSince1970: 1_787_000_000)
        let unknown = try recordings.createUnknown(
            providerID: "nts", showID: "ben-ufo/2026-01-14",
            heardAt: heardAt, offsetSeconds: 4903
        )
        recordings.note(
            appearance: MediaAppearance(
                providerID: "nts", stationID: "nts.1", stationName: "NTS 1",
                showTitle: "Ben UFO", showID: "ben-ufo/2026-01-14",
                heardAt: heardAt, offsetSeconds: 4903, isLive: true, method: .none
            ),
            on: unknown
        )

        let item = crate.add(recording: unknown)

        XCTAssertEqual(crate.count, 1)
        XCTAssertTrue(item.displayTitle.hasPrefix("UNKNOWN/"))
        XCTAssertEqual(item.statusLabel, "Unknown")
        XCTAssertEqual(item.sourceLine, "NTS 1 / Ben UFO @ 01:21:43")
    }

    func testCratingAnNTSTracklistEntryKeepsEpisodeAndTimestamp() throws {
        let detail = NTSEpisodeDetail(
            summary: NTSEpisodeSummary(
                showAlias: "ben-ufo", episodeAlias: "2026-08-28", name: "Ben UFO",
                summary: nil, location: nil, genres: [], moods: [], artworkURL: nil,
                broadcastAt: Date(timeIntervalSince1970: 1_788_000_000), isPublished: true
            ),
            tracklist: [
                NTSTracklistEntry(id: "track#0", artist: "Skee Mask", title: "Rev8617", offset: 4_472)
            ],
            audio: []
        )
        let entry = try XCTUnwrap(detail.tracklist.first)

        crate.toggle(tracklistEntry: entry, in: detail)

        let item = try XCTUnwrap(crate.items().first)
        XCTAssertEqual(item.kind, .recording)
        XCTAssertEqual(item.displayTitle, "Rev8617")
        XCTAssertEqual(item.displaySubtitle, "Skee Mask")
        XCTAssertEqual(item.sourceLine, "NTS / Ben UFO @ 01:14:32")
        XCTAssertTrue(crate.isCrated(tracklistEntry: entry, in: detail))

        crate.toggle(tracklistEntry: entry, in: detail)
        XCTAssertEqual(crate.count, 0)
    }

    func testRepeatedPlaceholderRowsCrateIndependently() throws {
        let detail = NTSEpisodeDetail(
            summary: NTSEpisodeSummary(
                showAlias: "papo2oo4", episodeAlias: "mix", name: "Papo2oo4 & YL",
                summary: nil, location: nil, genres: [], moods: [], artworkURL: nil,
                broadcastAt: Date(timeIntervalSince1970: 1_788_000_000), isPublished: true
            ),
            tracklist: [
                NTSTracklistEntry(id: "a#0", artist: "Papo2oo4 & YL",
                                  title: "Unreleased (Prod. Subjxct 5)", offset: 8),
                NTSTracklistEntry(id: "b#1", artist: "Papo2oo4 & YL",
                                  title: "Unreleased (Prod. Subjxct 5)", offset: 904)
            ],
            audio: []
        )
        RadioNeighborhoodEngine(context: context).ingest(detail)

        crate.toggle(tracklistEntry: detail.tracklist[0], in: detail)

        XCTAssertTrue(crate.isCrated(tracklistEntry: detail.tracklist[0], in: detail))
        XCTAssertFalse(crate.isCrated(tracklistEntry: detail.tracklist[1], in: detail))
        XCTAssertEqual(crate.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 2)
    }

    func testProviderNeutralTracklistRowsCrateIndependently() {
        let first = RadioTracklistItem(
            providerID: "lyl", showID: "episode-1", showTitle: "Guest Mix", airedAt: nil,
            entryID: "0", title: "Unknown — Untitled", artist: nil, offsetSeconds: nil
        )
        let second = RadioTracklistItem(
            providerID: "lyl", showID: "episode-1", showTitle: "Guest Mix", airedAt: nil,
            entryID: "1", title: "Unknown — Untitled", artist: nil, offsetSeconds: nil
        )

        crate.toggle(radioTracklistItem: first)

        XCTAssertTrue(crate.isCrated(radioTracklistItem: first))
        XCTAssertFalse(crate.isCrated(radioTracklistItem: second))
        XCTAssertEqual(crate.count, 1)
    }

    func testProviderTextTracklistRecoversArtistAndTitleForDIG() throws {
        let row = RadioTracklistItem(
            providerID: "lyl", showID: "episode-1", showTitle: "Guest Mix", airedAt: nil,
            entryID: "0", title: "Skee Mask — Rev8617", artist: nil, offsetSeconds: nil
        )

        let recording = try XCTUnwrap(crate.toggle(radioTracklistItem: row))

        XCTAssertEqual(recording.artistName, "Skee Mask")
        XCTAssertEqual(recording.title, "Rev8617")
        XCTAssertEqual(DigStore(context: context).destination(for: recording),
                       .digArtist(mbid: nil, name: "Skee Mask"))
    }

    func testStructuredTracklistCreditIsNotReparsed() throws {
        let row = RadioTracklistItem(
            providerID: "lot", showID: "episode-1", showTitle: "Guest Mix", airedAt: nil,
            entryID: "0", title: "A - Z", artist: "Actress", offsetSeconds: nil
        )

        let recording = try XCTUnwrap(crate.toggle(radioTracklistItem: row))

        XCTAssertEqual(recording.artistName, "Actress")
        XCTAssertEqual(recording.title, "A - Z")
    }

    // MARK: Broadcasts

    func testCratingWhatIsPlayingKeepsTheBroadcast() {
        let episode = MediaItem(
            id: "nts.episode.moxie/2026-08-27", sourceID: "nts", kind: .episode,
            title: "Moxie", subtitle: "27 Aug 2026", detail: "NTS",
            genres: ["House", "Jazz"],
            remoteArtworkURL: URL(string: "https://media.example/moxie.jpg"),
            playbackURL: URL(string: "https://soundcloud.com/nts/moxie")!,
            embedProvider: .soundcloud
        )

        XCTAssertFalse(crate.isCrated(nowPlaying: episode))
        crate.toggle(nowPlaying: episode)
        XCTAssertTrue(crate.isCrated(nowPlaying: episode))
        XCTAssertEqual(crate.count, 1)

        let item = try? XCTUnwrap(crate.items().first)
        XCTAssertEqual(item?.kind, .broadcast)
        XCTAssertEqual(item?.sourceLine, "NTS")
        XCTAssertEqual(item?.genreTags, ["House", "Jazz"])

        // A crated broadcast has to be playable again from the crate alone.
        let replay = try? XCTUnwrap(item?.broadcastMediaItem())
        XCTAssertEqual(replay?.embedProvider, .soundcloud)
        XCTAssertEqual(replay?.playbackURL.absoluteString, "https://soundcloud.com/nts/moxie")
        XCTAssertEqual(replay?.genres, ["House", "Jazz"])

        crate.toggle(nowPlaying: episode)
        XCTAssertEqual(crate.count, 0)
    }

    /// A live station's headline is the show on air, so the crated entry keeps
    /// the show as its title and the station underneath.
    func testCratingALiveStationNamesTheShow() {
        let station = MediaItem(
            id: "nts.1", sourceID: "nts", kind: .radioStation,
            title: "NTS 1", subtitle: "Moxie", detail: "NTS",
            playbackURL: URL(string: "https://stream.example/1")!
        )
        crate.toggle(nowPlaying: station, liveShow: RadioShow(
            title: "Moxie", host: nil, summary: nil, location: nil,
            genres: [], moods: [], artworkURL: nil,
            startsAt: nil, endsAt: nil, detailID: nil
        ))

        let item = crate.items().first
        XCTAssertEqual(item?.displayTitle, "Moxie")
        XCTAssertEqual(item?.displaySubtitle, "NTS 1")
        XCTAssertEqual(item?.isLiveStream, true)
    }

    func testCratingLiveNTSKeepsExactEpisodeAndNeverTheStationStream() throws {
        let station = MediaItem(
            id: "nts.1", sourceID: NTSProvider.providerID, kind: .radioStation,
            title: "NTS 1", subtitle: "James McNew", detail: "NTS",
            playbackURL: URL(string: "https://stream-relay-geo.ntslive.net/stream")!
        )
        let show = RadioShow(
            title: "James McNew", host: "James McNew", summary: nil, location: "New York",
            genres: ["Rock"], moods: ["Eclectic"],
            artworkURL: URL(string: "https://images.example/james.jpg"),
            startsAt: nil, endsAt: nil, detailID: "james-mcnew/james-mcnew-29th-august-2026"
        )

        crate.toggle(nowPlaying: station, liveShow: show)

        let item = try XCTUnwrap(crate.items().first)
        XCTAssertEqual(item.showID, "nts.episode.james-mcnew/james-mcnew-29th-august-2026")
        XCTAssertEqual(item.displayTitle, "James McNew")
        XCTAssertEqual(item.genreTags, ["Rock", "Eclectic"])
        XCTAssertNil(item.playbackURLString)
        XCTAssertFalse(item.isLiveStream)
        XCTAssertNil(item.broadcastMediaItem())
        XCTAssertTrue(crate.isCrated(nowPlaying: station, liveShow: show))
    }

    // MARK: Local files

    func testCratingALocalTrackCreatesAndLinksItsRecording() throws {
        let track = Track(
            path: "/Music/Autechre/Tri Repetae/Bike.flac", relativePath: "Autechre/Tri Repetae/Bike.flac",
            title: "Bike", artist: "Autechre", albumArtist: "Autechre", album: "Tri Repetae",
            genre: "Electronic", trackNumber: 4, discNumber: 1, year: 1995, duration: 477,
            fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        )
        context.insert(track)

        crate.toggle(nowPlaying: track.mediaItem())

        XCTAssertEqual(crate.count, 1)
        let item = try XCTUnwrap(crate.items().first)
        XCTAssertEqual(item.kind, .recording)
        XCTAssertEqual(item.displayTitle, "Bike")
        XCTAssertEqual(item.displaySubtitle, "Autechre")
        XCTAssertEqual(item.sourceLine, "Local Library")
        XCTAssertTrue(crate.isCrated(nowPlaying: track.mediaItem()))
    }

    func testExistingLocalCrateEntryBackfillsItsGenre() throws {
        let track = Track(
            path: "/Music/Actress/Splazsh/Hubble.flac", relativePath: "Actress/Splazsh/Hubble.flac",
            title: "Hubble", artist: "Actress", albumArtist: "Actress", album: "Splazsh",
            genre: "Electronic", trackNumber: 3, discNumber: 1, year: 2010, duration: 443,
            fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        )
        context.insert(track)
        let recording = try recordings.recording(for: track)
        let legacyItem = CrateItem(recording: recording)
        context.insert(legacyItem)
        try context.save()

        XCTAssertTrue(legacyItem.genreTags.isEmpty)
        crate.backfillLocalGenres()
        XCTAssertEqual(legacyItem.genreTags, ["Electronic"])
    }

    func testCratingAMissingFileReportsRatherThanCrashing() {
        let ghost = MediaItem(
            id: "/Music/gone.flac", sourceID: Track.sourceID, kind: .track,
            title: "Gone", playbackURL: URL(fileURLWithPath: "/Music/gone.flac")
        )
        crate.toggle(nowPlaying: ghost)

        XCTAssertEqual(crate.count, 0)
        XCTAssertNotNil(crate.notice)
    }

    // MARK: Grouping

    func testItemsGroupNewestFirstByDay() throws {
        let old = try recordings.upsert(title: "Old", artistName: "A")
        let new = try recordings.upsert(title: "New", artistName: "B")

        let oldItem = crate.add(recording: old)
        oldItem.addedAt = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        let newItem = crate.add(recording: new)

        let days = crate.days()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.label, "Today")
        XCTAssertEqual(days.first?.items.first?.id, newItem.id)
        XCTAssertEqual(days.last?.items.first?.id, oldItem.id)
    }
}
