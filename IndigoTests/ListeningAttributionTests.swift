//
//  ListeningAttributionTests.swift
//  IndigoTests
//
//  Where a listen started, and what led there: verified ids beside names,
//  an origin only through the page opened from a recommendation, one
//  playback however many rows, taste never reading any of it, and the same
//  answer from a synced copy.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListeningAttributionTests: XCTestCase {
    /// An app-module main-actor class released under XCTest aborts the host
    /// (see `PlaybackWitness`); the states made here are kept.
    @MainActor private static var kept: [AppState] = []

    override func setUp() { ListeningAttributionFeature.override = true }
    override func tearDown() { ListeningAttributionFeature.override = nil }

    private func item(_ id: String, kind: MediaKind = .track, source: String = "youtube", title: String = "Rev8617",
                      subtitle: String? = "Skee Mask", genres: [String] = ["Ambient"]) -> MediaItem {
        MediaItem(id: id, sourceID: source, kind: kind, title: title, subtitle: subtitle, genres: genres,
                  playbackURL: URL(string: "https://example.com/\(id)")!)
    }

    @MainActor
    private func context() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Persistence.schema, configurations: configuration))
    }

    private let fromForYou = ListeningSurface.Origin(screen: "foryou.mix", via: "Aphex Twin", viaID: "discogs-artist:45", route: "artist")

    @MainActor
    func testIdsAndOriginSurviveTheLogAndTasteNeverSeesThem() throws {
        let context = try context()
        let surface = ListeningSurface(screen: "dig.artist.listen", via: "Solar Bears", viaID: ListeningSurface.discogsArtist(1234),
                                       route: nil, origin: fromForYou)
        PlaybackWitness(context: context).record(item("a"), seconds: 120, completion: 0.5, surface: surface)
        let events = ListeningLog(context: context).all()
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(event.surface, ListeningSurface(screen: "dig.artist.listen", via: "solar bears", viaID: "discogs-artist:1234",
                                                           origin: .init(screen: "foryou.mix", via: "aphex twin", viaID: "discogs-artist:45", route: "artist")))
            XCTAssertEqual(event.musicTags, ["ambient"])
        }
        XCTAssertFalse(TasteProfile.build(from: events).weights.keys.contains(where: ListeningSurface.isSurfaceTag))
        let read = ListenerProfile.read(context: context)
        XCTAssertTrue(read.evidence.allSatisfy { $0.tags == ["ambient"] }, "the listener profile reads music tags only")
    }

    /// An unknown id stays unknown: a name is never turned into one.
    func testNoIDWithoutAVerifiedOne() {
        XCTAssertNil(ListeningSurface.discogsArtist(nil))
        XCTAssertNil(ListeningSurface.discogsArtist(0))
        let tags = ListeningSurface(screen: "foryou.mix", via: "Cardinal").tags
        XCTAssertEqual(tags, ["surface:foryou.mix", "via:cardinal"])
    }

    // MARK: Origin

    @MainActor
    func testAnOriginLastsOnlyWhileItsPageIsOnTop() {
        let state = AppState()
        Self.kept.append(state)
        let page = DetailPage.digArtist(mbid: nil, name: "Solar Bears", discogsID: 1234)
        state.open(page, from: fromForYou)
        XCTAssertEqual(state.originOfTopPage, fromForYou)
        state.open(.digArtist(mbid: nil, name: "Somebody Else"))
        XCTAssertNil(state.originOfTopPage, "another page: not the recommendation's")
        state.popDetail()
        XCTAssertNil(state.originOfTopPage, "back on the page, but the listener did something else in between")

        state.open(page, from: fromForYou)
        state.searchText = "boards"
        XCTAssertNil(state.originOfTopPage, "searching is something else")

        state.open(page, from: fromForYou)
        state.select(.dig)
        XCTAssertNil(state.originOfTopPage)
    }

    /// Settled when the item is put on: what the listener does afterwards
    /// does not rewrite it.
    @MainActor
    func testTheOriginIsTakenWhenPlaybackStartsNotLater() {
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "attribution-test")!)
        defer { player.stopAll() }
        var origin: ListeningSurface.Origin? = fromForYou
        player.originNow = { origin }
        let station = item("s", kind: .radioStation, source: "nts", title: "NTS 1", subtitle: nil)
        player.playRadio(station)
        origin = nil
        XCTAssertEqual(player.surface(for: "s")?.origin, fromForYou)
        XCTAssertEqual(player.surface(for: "s")?.screen, "radio.live", "the screen said nothing: the item says radio")
        XCTAssertEqual(player.listeningSurface?.origin, fromForYou)
    }

    // MARK: One playback

    @MainActor
    func testTheRowsOfOneListenAreOnePlayback() throws {
        let context = try context()
        let witness = PlaybackWitness(context: context)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        witness.record(item("a"), seconds: 200, completion: 0.8, at: start, surface: ListeningSurface(screen: "foryou.mix"))
        witness.record(item("b", title: "Other", subtitle: "Skee Mask"), seconds: 200, completion: 0.8, at: start.addingTimeInterval(200),
                       surface: ListeningSurface(screen: "foryou.mix"))
        witness.record(item("e", kind: .episode, source: KioskProvider.providerID, title: "A Show", subtitle: nil), seconds: 12, completion: 0.01,
                       at: start.addingTimeInterval(400))
        let events = ListeningLog(context: context).all()
        XCTAssertEqual(events.count, 6)
        let playbacks = ListeningPlayback.group(events)
        XCTAssertEqual(playbacks.count, 3)
        XCTAssertEqual(playbacks.map(\.rows), [2, 2, 2])
        XCTAssertEqual(playbacks[0].recording, "Rev8617")
        XCTAssertEqual(playbacks[0].artist, "Skee Mask")
        let summary = AttributionSummary(events)
        XCTAssertEqual(summary.playbacks, 3)
        XCTAssertEqual(summary.byScreen["foryou.mix"], .init(played: 2, skipped: 0), "two listens, not four rows")
        XCTAssertEqual(summary.byScreen["radio.archive"], .init(played: 0, skipped: 1))
        XCTAssertEqual(summary.suspect, 0)
    }

    // MARK: Old builds, and synced copies

    /// What a build from before attribution does with these rows: its
    /// TasteProfile loop read every tag. Copied here as it was, so the test
    /// shows the cost rather than assuming it.
    private func oldTaste(_ events: [ListeningEvent], now: Date) -> [String: Double] {
        var totals: [String: Double] = [:]
        for event in events {
            let weight = event.weight
            guard weight != 0, !event.tags.isEmpty else { continue }
            let age = now.timeIntervalSince(event.at)
            let decayed = weight * (age <= 0 ? 1 : pow(0.5, age / TasteProfile.halfLife))
            for tag in event.tags { totals[tag, default: 0] += decayed / Double(event.tags.count) }
        }
        let positive = totals.filter { $0.value > 0 }
        guard let strongest = positive.values.max() else { return [:] }
        return positive.mapValues { min(1, $0 / strongest) }
    }

    @MainActor
    func testAnOldBuildReadsTheTagsAsInterestsThatMatchNoMusic() throws {
        let context = try context()
        let now = Date()
        PlaybackWitness(context: context).record(item("a", genres: ["Ambient", "Drone"]), seconds: 300, completion: 1, at: now,
                                                 surface: ListeningSurface(screen: "foryou.mix", via: "Aphex Twin", route: "track"))
        let events = ListeningLog(context: context).all()
        let old = oldTaste(events, now: now)
        // It does count them -- that is the cost --
        XCTAssertTrue(old.keys.contains("surface:foryou.mix"))
        // but no music tag can ever match one, and the music tags keep their
        // order and their ratio to each other.
        XCTAssertEqual(old["ambient"], old["drone"])
        XCTAssertEqual(TasteProfile.build(from: events, now: now).weights.keys.sorted(), ["ambient", "drone"])
    }

    /// A synced or restored copy says the same: tags keep their order, a
    /// duplicate collapses, and grouping does not depend on row order.
    @MainActor
    func testACopyCarriesTheSameAttribution() throws {
        let context = try context()
        PlaybackWitness(context: context).record(item("a"), seconds: 90, completion: 0.4,
                                                 surface: ListeningSurface(screen: "dig.discover", via: "Eric Kloss", viaID: "discogs-artist:7",
                                                                           route: "track", origin: fromForYou))
        let events = ListeningLog(context: context).all()
        let other = try self.context()
        for event in events.reversed() { other.insert(ListeningEvent(restoring: EventValue(event))) }
        let copied = try other.fetch(FetchDescriptor<ListeningEvent>())
        XCTAssertEqual(Set(copied.map(\.surface)), Set(events.map(\.surface)))
        XCTAssertEqual(ListeningPlayback.group(copied), ListeningPlayback.group(events))
        XCTAssertEqual(EventValue.merged([EventValue(events[0]), EventValue(events[0])])?.tags, events[0].tags)
    }
}
