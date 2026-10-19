import XCTest
@testable import Indigo

final class RadioDiscoverTests: XCTestCase {
    private func fixture() -> (RadioDiscover.Inputs, [Int: [UUID]], [RadioDiscover.Slot], [UUID: RadioDiscover.Identity]) {
        let seed0 = UUID(), seed1 = UUID()
        let inputs = RadioDiscover.Inputs(seeds: [.init(id: 1, name: "Seed A", cluster: 0, weight: 2, recordings: ["known"]),
                                                  .init(id: 2, name: "Seed B", cluster: 1, weight: 2, recordings: [])],
                                         labels: [0: "Ambient", 1: "Jazz"], styles: [0: ["ambient"], 1: ["jazz"]],
                                         artistStyles: [:], known: ["seed a", "seed b"], key: "fixture")
        var slots: [RadioDiscover.Slot] = [], identities: [UUID: RadioDiscover.Identity] = [:]
        for e in 0..<4 {
            let episode = RadioDiscover.Episode(id: UUID(), radio_show_id: UUID(), provider: "nts", external_id: "show/\(e)",
                                               archive_url: "https://soundcloud.com/show/\(e)", title: "Episode \(e)", aired_at: Date(), image_url: nil,
                                               duration_seconds: 7200, radio_shows: .init(title: "Programme \(e)", host_name: "DJ \(e)"))
            slots.append(.init(artist_id: e % 2 == 0 ? seed0 : seed1, raw_artist_name: "Seed", raw_track_title: "Known",
                               track_index: 4, offset_seconds: 1000, media_url: nil, radio_episodes: episode))
            for n in 0..<2 {
                let row = UUID(), id = 10 + e * 2 + n
                identities[row] = .init(id: id, name: "Artist \(id)")
                slots.append(.init(artist_id: row, raw_artist_name: "Artist \(id)", raw_track_title: "Track \(id)", track_index: 5 + n,
                                   offset_seconds: 1300 + n * 300, media_url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", radio_episodes: episode))
            }
        }
        return (inputs, [1: [seed0], 2: [seed1]], slots, identities)
    }
    private func source(_ rows: [Int: [UUID]], _ slots: [RadioDiscover.Slot], _ identities: [UUID: RadioDiscover.Identity], plays: Bool? = true) -> RadioDiscoverSource {
        RadioDiscoverSource(rows: { _ in rows }, seedAppearances: { _ in slots }, tracklists: { _ in slots }, identities: { _ in identities },
                            recording: { _, _, _ in nil }, plays: { _ in plays })
    }
    func testEightPlayableTracksCoverBothClustersWithoutChangingTheMix() async throws {
        let (inputs, rows, slots, identities) = fixture()
        let found = try await RadioDiscover(source: source(rows, slots, identities)).discover(inputs)
        XCTAssertEqual(found.picks.count, 8)
        XCTAssertEqual(Set(found.picks.map(\.cluster)), [0, 1])
        XCTAssertTrue(found.picks.allSatisfy { $0.track.playable == .yes && $0.track.isRecording })
        XCTAssertEqual(Set(found.picks.map { $0.track.artistDiscogsID }).count, 8)
        XCTAssertTrue(found.picks.allSatisfy { $0.track.reason.contains($0.nearest) && $0.distance <= 3 })
    }
    func testUnknownPlaybackIsNeverOffered() async throws {
        let (inputs, rows, slots, identities) = fixture()
        let found = try await RadioDiscover(source: source(rows, slots, identities, plays: nil)).discover(inputs)
        XCTAssertTrue(found.picks.isEmpty)
    }
    func testEstimatedOffsetsDoNotBecomePlaybackVerifiedWhenAnArchivePlays() async throws {
        let (inputs, rows, slots, identities) = fixture()
        var source = source(rows, slots.map { var s = $0; s.media_url = nil; return s }, identities)
        source.recording = { id, name, _ in
            .init(artistDiscogsID: id, artist: name, title: "Different recording", source: .recording(URL(string: "https://youtube.com/watch?v=bbbbbbbbbbb")!, channel: nil), artworkURL: nil, genres: [])
        }
        let found = try await RadioDiscover(source: source).discover(inputs)
        XCTAssertEqual(found.picks.count, 8)
        XCTAssertTrue(found.picks.allSatisfy { !$0.track.isRecording && $0.timing == .publisherEstimated })
        XCTAssertTrue(found.picks.allSatisfy { $0.timing.label.contains("offset unverified") })
    }
    func testZeroOffsetOnLaterTracksIsNotPresentedAsASeekableAppearance() async throws {
        let (inputs, rows, slots, identities) = fixture()
        let untimed = slots.map { var slot = $0; slot.media_url = nil; slot.offset_seconds = 0; return slot }
        let found = try await RadioDiscover(source: source(rows, untimed, identities)).discover(inputs)
        XCTAssertTrue(found.picks.isEmpty)
    }
    func testEclecticEpisodesDoNotBorrowAffinityFromAnotherEpisode() {
        let (inputs, rows, slots, identities) = fixture()
        var remote = slots.last!
        remote.track_index = 40
        let row = UUID()
        remote.artist_id = row
        var known = identities
        known[row] = .init(id: 900, name: "Far away artist")
        let ranked = RadioDiscover.rank(inputs: inputs, rows: rows, slots: slots + [remote], identities: known).0
        XCTAssertFalse(ranked.contains { $0.identity.id == 900 })
    }
    func testMBIDVerifiedDestinationsAreAllowedButAmbiguityAndNamesAloneAreNot() {
        let a = UUID(), b = UUID(), c = UUID()
        let links = [DiscogsIdentityRows.Link(entity_id: a, provider: "musicbrainz_discogs", external_id: "12"),
                     .init(entity_id: b, provider: "musicbrainz_discogs", external_id: "13"),
                     .init(entity_id: b, provider: "musicbrainz_discogs", external_id: "14")]
        let found = RadioDiscover.identities(links, names: [a: "Artist", b: "Namesake", c: "Name only"])
        XCTAssertEqual(found[a]?.id, 12)
        XCTAssertNil(found[b]); XCTAssertNil(found[c])
    }
    func testConflictingDirectAndMusicBrainzDestinationsAreRejected() {
        let row = UUID()
        let found = RadioDiscover.identities([
            .init(entity_id: row, provider: "discogs", external_id: "12"),
            .init(entity_id: row, provider: "musicbrainz_discogs", external_id: "13")
        ], names: [row: "Namesake"])
        XCTAssertNil(found[row])
    }
    func testPersonalCacheReusesCompatibleResultsAndExpires() async throws {
        let (inputs, rows, slots, identities) = fixture()
        let result = try await RadioDiscover(source: source(rows, slots, identities)).discover(inputs)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = RadioDiscoverCache(file: file)
        await cache.save(result)
        let held = await cache.load(key: inputs.key)
        XCTAssertEqual(held?.picks.map(\.id), result.picks.map(\.id))
        let stale = await cache.load(key: inputs.key, now: result.at.addingTimeInterval(7 * 3600))
        XCTAssertNil(stale)
        let different = await cache.load(key: "another history")
        XCTAssertNil(different)
    }
}
