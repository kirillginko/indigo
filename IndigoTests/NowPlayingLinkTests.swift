//
//  NowPlayingLinkTests.swift
//  IndigoTests
//
//  The player bar only draws its artwork and title as buttons when there is
//  somewhere to send them. A source nothing here recognises therefore does not
//  fail loudly — it silently stops being clickable, which is how "nothing in
//  the player links anywhere" happens without a single error.
//
//  So every source Indigo can play is covered, and the last test asserts that
//  a new one cannot be added without being covered too.
//

import XCTest
@testable import Indigo

final class NowPlayingLinkTests: XCTestCase {
    private func item(_ id: String, source: String) -> MediaItem {
        MediaItem(id: id, sourceID: source, kind: .episode, title: "Something",
                  playbackURL: URL(string: "https://example.invalid/stream")!)
    }

    private func link(_ id: String, source: String,
                      album: String? = nil,
                      live: NTSEpisodeRef? = nil) -> NowPlayingLink? {
        NowPlayingLink.destination(
            for: item(id, source: source),
            localAlbumKey: { _ in album },
            liveNTSEpisode: live)
    }

    // MARK: - Local files

    func testALocalTrackOpensItsAlbum() {
        XCTAssertEqual(link("/Music/a.flac", source: Track.sourceID, album: "Boards|Geogaddi"),
                       .detail(.album("Boards|Geogaddi")))
    }

    /// A file being played but not indexed still belongs somewhere. Before,
    /// this fell through every branch and left the bar inert.
    func testAnUnindexedLocalTrackStillGoesSomewhere() {
        XCTAssertEqual(link("/Music/stray.flac", source: Track.sourceID, album: nil),
                       .route(.tracks))
    }

    // MARK: - Archived recordings

    func testEveryArchivedSourceResolves() {
        let cases: [(String, String)] = [
            ("noods.show.some-slug", NoodsProvider.providerID),
            ("nts.mixtape.poolside", NTSProvider.providerID),
            ("lyl.episode.abc", LYLProvider.providerID),
            ("rovr.broadcast.99", RovrProvider.providerID),
            ("panik.episode.77", PanikProvider.providerID),
            ("radio80000.episode.12", Radio80000Provider.providerID),
            ("ida.episode.xyz", IdaProvider.providerID),
            ("cashmere.episode.abc", CashmereProvider.providerID),
            ("alhara.show.def", AlharaProvider.providerID),
            ("dublab.broadcast.ghi", DublabProvider.providerID),
            ("kiosk.episode.jkl", KioskProvider.providerID),
        ]
        for (id, source) in cases {
            XCTAssertNotNil(link(id, source: source), "\(id) resolved to nothing")
        }
    }

    /// Kiosk episodes were reachable only through the source switch, which
    /// returned the station — so an episode opened the station instead of
    /// itself.
    func testAKioskEpisodeOpensTheEpisodeNotTheStation() {
        XCTAssertEqual(link("kiosk.episode.jkl", source: KioskProvider.providerID),
                       .detail(.kioskEpisode(slug: "jkl")))
    }

    // MARK: - Live streams

    func testALiveStreamOpensItsStation() {
        XCTAssertEqual(link("cashmere.stream.1", source: CashmereProvider.providerID),
                       .route(.cashmereStation))
        XCTAssertEqual(link("lot.live.1", source: LotProvider.providerID),
                       .route(.lotStation))
    }

    /// NTS names what is on air, so a live channel can open the episode.
    func testLiveNTSPrefersTheEpisodeOnAir() {
        let ref = NTSEpisodeRef(show: "a-show", episode: "an-episode")
        XCTAssertEqual(link("2", source: NTSProvider.providerID, live: ref),
                       .detail(.ntsEpisode(show: "a-show", episode: "an-episode")))
    }

    /// And still goes somewhere when it does not.
    func testLiveNTSWithoutAnEpisodeStillOpensTheChannel() {
        XCTAssertEqual(link("2", source: NTSProvider.providerID, live: nil),
                       .route(.station("2")))
    }

    // MARK: - Malformed

    /// A bare prefix carries no identity, so it must not open a page for a
    /// recording called "".
    func testAnEmptyIdentityDoesNotOpenAnEmptyPage() {
        XCTAssertNil(link("lyl.episode.", source: "unknown.source"))
    }

    /// The guard against this list going stale: every provider Indigo ships
    /// must resolve to something from its own live stream.
    func testEveryProviderIndigoShipsIsReachable() {
        let providers = [
            NTSProvider.providerID, KioskProvider.providerID, NoodsProvider.providerID,
            LotProvider.providerID, DublabProvider.providerID, AlharaProvider.providerID,
            CashmereProvider.providerID, LYLProvider.providerID, IdaProvider.providerID,
            Radio80000Provider.providerID, PanikProvider.providerID, RovrProvider.providerID,
        ]
        for provider in providers {
            XCTAssertNotNil(link("\(provider).stream.1", source: provider),
                            "\(provider) has no destination — its bar would be inert")
        }
    }
}
