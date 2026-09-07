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

    // MARK: - Kept off the air

    /// A show kept while a station was live must not replay as the station.
    ///
    /// The crate stores the station's id, because the station is what was
    /// playing, and the show's title, because the show is what was kept.
    /// Handing that back to the player starts whatever is on air now under
    /// the name of something else — which is how crating "Neue Rituale" on
    /// Radio 80000 came to open Radio 80000 live.
    func testAShowKeptOffTheAirDoesNotReplayAsTheStation() throws {
        let kept = crate.add(
            broadcast: "radio80000.live",
            providerID: Radio80000Provider.providerID,
            title: "Neue Rituale",
            subtitle: "Radio 80000",
            artworkURL: nil,
            playbackURL: URL(string: "https://radio80k.out.airtime.pro/radio80k_a"),
            embedProvider: nil,
            isLiveStream: true
        )

        XCTAssertTrue(kept.isLiveShowSnapshot, "The title is a show and the id is a station")
        XCTAssertNil(
            kept.broadcastMediaItem(),
            "So there is nothing here the player can honestly start again"
        )
    }

    /// A station kept as a station still plays. The rule above must not eat
    /// the ordinary case: somebody who crates a station with nothing on air
    /// has kept the station, and pressing play should open it.
    func testAStationKeptAsAStationStillPlays() throws {
        let kept = crate.add(
            broadcast: "radio80000.live",
            providerID: Radio80000Provider.providerID,
            title: "Radio 80000",
            subtitle: nil,
            artworkURL: nil,
            playbackURL: URL(string: "https://radio80k.out.airtime.pro/radio80k_a"),
            embedProvider: nil,
            isLiveStream: true
        )

        XCTAssertFalse(kept.isLiveShowSnapshot)
        XCTAssertEqual(kept.broadcastMediaItem()?.kind, .radioStation)
    }

    // MARK: - Crating what is on air

    private func liveStation(_ providerID: String, id: String, name: String) -> MediaItem {
        MediaItem(
            id: id,
            sourceID: providerID,
            kind: .radioStation,
            title: name,
            subtitle: "Live",
            playbackURL: URL(string: "https://stream.test/\(providerID)")!
        )
    }

    private func onAir(_ title: String, detailID: String?) -> RadioShow {
        RadioShow(
            title: title, host: nil, summary: nil, location: nil,
            genres: [], moods: [], artworkURL: nil,
            startsAt: nil, endsAt: nil, detailID: detailID
        )
    }

    /// A station that can say what is on has the show kept, not itself.
    ///
    /// IDA publishes, on air, the very slug its episode pages are filed
    /// under — so the row a listener keeps mid-broadcast is the same row
    /// they would get from the archive later, and the live stream is not
    /// stored as though it were the recording.
    func testAStationThatNamesWhatIsOnHasTheShowKept() throws {
        let station = liveStation(IdaProvider.providerID, id: "ida.live.tallinn", name: "IDA Tallinn")
        crate.toggle(nowPlaying: station, liveShow: onAir("AGSS Radio", detailID: "agss-radio-15-10-2024"))

        let rows = crate.items()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.showID, "ida.episode.agss-radio-15-10-2024")
        XCTAssertEqual(rows.first?.showTitle, "AGSS Radio")
        XCTAssertFalse(rows.first?.isLiveStream ?? true, "The broadcast is not the station's stream")
        XCTAssertNil(rows.first?.playbackURLString, "And the stream is not its archive source")
    }

    /// Panik and Cashmere name the show rather than the broadcast, so those
    /// are filed as shows. Calling one an episode would claim a broadcast
    /// nobody identified.
    func testAStationThatNamesOnlyTheShowFilesItAsAShow() throws {
        let station = liveStation(PanikProvider.providerID, id: "panik.live", name: "Radio Panik")
        crate.toggle(nowPlaying: station, liveShow: onAir("Digging Deeper", detailID: "digging-deeper"))

        XCTAssertEqual(crate.items().first?.showID, "panik.show.digging-deeper")
    }

    /// The same broadcast kept twice — once off the air, once out of the
    /// archive — is one row. That is the whole reason the providers' own
    /// identifiers are used rather than something minted here.
    func testKeepingABroadcastLiveAndFromTheArchiveIsOneRow() throws {
        let station = liveStation(RovrProvider.providerID, id: "rovr.live", name: "ROVR")
        crate.toggle(nowPlaying: station, liveShow: onAir("Nocturne", detailID: "doc-42"))

        let archived = MediaItem(
            id: "rovr.broadcast.doc-42",
            sourceID: RovrProvider.providerID,
            kind: .episode,
            title: "Nocturne",
            playbackURL: URL(string: "https://archive.test/nocturne.mp3")!
        )
        crate.toggle(nowPlaying: archived)

        XCTAssertTrue(crate.items().isEmpty, "The second press took the one row back off")
    }

    /// A station with nothing to say still crates as the station, and still
    /// plays. Naming what is on is an improvement where it is possible, not
    /// a requirement for keeping anything.
    func testAStationThatCannotSayWhatIsOnIsStillKept() throws {
        let station = liveStation(AlharaProvider.providerID, id: "alhara.live", name: "Radio al Hara")
        crate.toggle(nowPlaying: station, liveShow: onAir("Untitled", detailID: nil))

        let row = try XCTUnwrap(crate.items().first)
        XCTAssertEqual(row.showID, "alhara.live")
        XCTAssertTrue(row.isLiveStream)
    }

    /// Every station the crate can hold has somewhere for a kept show to
    /// land.
    ///
    /// The exact broadcast is the good answer and is not always available:
    /// rows kept before a station's live feed was read, and stations whose
    /// feeds still name nothing, have only a title. The shows page is the
    /// honest fallback — the show may not have been posted yet — and a
    /// station missing from this list would give a dead press instead.
    func testEveryStationHasSomewhereAKeptShowCanLand() throws {
        let stations = [
            NTSProvider.providerID, KioskProvider.providerID, NoodsProvider.providerID,
            LotProvider.providerID, DublabProvider.providerID, AlharaProvider.providerID,
            CashmereProvider.providerID, LYLProvider.providerID, IdaProvider.providerID,
            Radio80000Provider.providerID, PanikProvider.providerID, RovrProvider.providerID
        ]
        for station in stations {
            XCTAssertNotNil(
                BroadcastSource.showsRoute(for: station),
                "\(BroadcastSource.label(for: station)) has nowhere to send a kept show"
            )
        }
        XCTAssertNil(BroadcastSource.showsRoute(for: "somewhere.else"))
    }

    // MARK: - Where a kept id points

    /// A station's own id must never be read as a broadcast id.
    ///
    /// `destination` falls back to the whole showID when it carries no
    /// prefix, because a bare slug is what a tracklist files. A row kept
    /// while a station was on air carries `radio80000.live`, and reading
    /// that as a broadcast built a page for an episode nobody ever named —
    /// which could only say the broadcast was unavailable. EXPLORE reached
    /// it that way from the For You page.
    func testAStationIdIsNotReadAsABroadcast() throws {
        XCTAssertNil(BroadcastSource.destination(
            showID: "radio80000.live", providerID: Radio80000Provider.providerID
        ))
        XCTAssertNil(BroadcastSource.destination(
            showID: "panik.live", providerID: PanikProvider.providerID
        ))
    }

    /// A show named on air opens the show, not an episode of it.
    func testAShowIdOpensTheShow() throws {
        XCTAssertEqual(
            BroadcastSource.destination(
                showID: "panik.show.digging-deeper", providerID: PanikProvider.providerID
            ),
            .panikShow(slug: "digging-deeper")
        )
        XCTAssertEqual(
            BroadcastSource.destination(
                showID: "cashmere.show.tundra", providerID: CashmereProvider.providerID
            ),
            .cashmereShow(slug: "tundra")
        )
    }

    /// And the bare slug a tracklist files still reaches the broadcast, which
    /// is the case the fallback exists for.
    func testABareSlugStillReachesTheBroadcast() throws {
        XCTAssertEqual(
            BroadcastSource.destination(
                showID: "agss-radio-15-10-2024", providerID: IdaProvider.providerID
            ),
            .idaEpisode(slug: "agss-radio-15-10-2024")
        )
        XCTAssertEqual(
            BroadcastSource.destination(
                showID: "ida.episode.agss-radio-15-10-2024", providerID: IdaProvider.providerID
            ),
            .idaEpisode(slug: "agss-radio-15-10-2024")
        )
    }

    // MARK: - The ladder a kept show climbs

    /// A row that named its broadcast opens the broadcast, and never gets as
    /// far as a fallback.
    func testAKeptBroadcastOpensTheBroadcast() async throws {
        let station = liveStation(IdaProvider.providerID, id: "ida.live.tallinn", name: "IDA Tallinn")
        crate.toggle(nowPlaying: station, liveShow: onAir("AGSS Radio", detailID: "agss-radio-15-10-2024"))
        let row = try XCTUnwrap(crate.items().first)

        let found = await KeptShow.destination(for: row, radio80000: Radio80000BrowseStore())
        XCTAssertEqual(found, .page(.idaEpisode(slug: "agss-radio-15-10-2024")))
    }

    /// A row that named only its station lands on that station's shows —
    /// where the broadcast will appear once it is posted.
    func testAKeptShowWithNoIdLandsOnTheStationsShows() async throws {
        let row = crate.add(
            broadcast: "panik.live",
            providerID: PanikProvider.providerID,
            title: "Digging Deeper",
            subtitle: "Radio Panik",
            artworkURL: nil,
            playbackURL: URL(string: "https://stream.test/panik"),
            embedProvider: nil,
            isLiveStream: true
        )

        let found = await KeptShow.destination(for: row, radio80000: Radio80000BrowseStore())
        XCTAssertEqual(found, .section(.panikShows))
    }

    /// A station kept as a station is not a kept show, and climbs nothing.
    func testAStationKeptAsAStationClimbsNothing() async throws {
        let row = crate.add(
            broadcast: "panik.live",
            providerID: PanikProvider.providerID,
            title: "Radio Panik",
            subtitle: nil,
            artworkURL: nil,
            playbackURL: URL(string: "https://stream.test/panik"),
            embedProvider: nil,
            isLiveStream: true
        )

        let found = await KeptShow.destination(for: row, radio80000: Radio80000BrowseStore())
        XCTAssertNil(found, "There is nothing kept here but the station itself")
    }
}
