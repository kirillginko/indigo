//
//  RecordSimilarityTests.swift
//  IndigoTests
//
//  Records like a record: rare styles count for more, styles that keep the
//  same company are close without being shared, a shared player is evidence
//  and a shared mastering engineer is not, and the answer is the same in any
//  order.
//

import XCTest
import SwiftData
@testable import Indigo

final class RecordSimilarityTests: XCTestCase {
    private func record(_ id: Int, _ artist: String, _ styles: [String], genres: [String] = ["Rock"], year: Int? = 1998,
                        labels: Set<String> = [], personnel: Set<String> = []) -> RecordProfile {
        RecordProfile(id: id, title: "Record \(id)", artists: [artist], artistKeys: [RecordingKey.normalizeArtist(artist)],
                      styles: styles.map { $0.lowercased() }, genres: genres.map { $0.lowercased() }, year: year,
                      labels: labels, personnel: personnel)
    }

    /// A pool where slowcore and sadcore keep the same company.
    private var pool: [RecordProfile] {
        [record(1, "Duster", ["Slowcore", "Space Rock", "Indie Rock"]),
         record(2, "Low", ["Slowcore", "Indie Rock"]),
         record(3, "Red House Painters", ["Sadcore", "Indie Rock"]),
         record(4, "Codeine", ["Slowcore", "Indie Rock"], year: 1992),
         record(5, "Bedhead", ["Sadcore", "Space Rock"]),
         record(6, "Some Rock Band", ["Indie Rock"]),
         record(7, "Another Rock Band", ["Indie Rock"]),
         record(8, "Techno Person", ["Techno"], genres: ["Electronic"]),
         record(9, "Duster", ["Slowcore"]),
         record(10, "Galaxie 500", ["Slowcore", "Sadcore", "Dream Pop"])]
    }

    func testARareStyleSaysMoreThanACommonOne() {
        let similarity = RecordSimilarity(pool: pool)
        let found = similarity.similar(to: pool[0], limit: 10, mode: .metadata).map(\.record.artists[0])
        XCTAssertLessThan(try XCTUnwrap(found.firstIndex(of: "Low")), try XCTUnwrap(found.firstIndex(of: "Some Rock Band")))
        XCTAssertFalse(found.contains("Duster"), "Never the seed's own artist")
        XCTAssertFalse(found.contains("Techno Person"))
    }

    func testStylesThatKeepTheSameCompanyAreClose() {
        let similarity = RecordSimilarity(pool: pool)
        let seed = record(20, "Seed", ["Slowcore", "Dream Pop"])
        let sadcore = similarity.judge(pool[2], against: seed, mode: .embedding)
        let techno = similarity.judge(pool[7], against: seed, mode: .embedding)
        XCTAssertEqual(similarity.styleOverlap(seed, pool[2]), 0, "No style shared")
        XCTAssertGreaterThan(sadcore.embedding, 0.1)
        XCTAssertEqual(techno.embedding, 0)
    }

    func testAPlayerOnBothIsEvidenceAndAMasteringEngineerIsNot() throws {
        let container = try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(
            schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let held = DiscogsReleaseRecord(discogsID: 30, title: "Stratosphere")
        held.artistNames = ["Duster"]
        held.creditNames = ["Jason Albertini", "Rashad Becker"]
        held.creditRoles = ["Bass, Vocals", "Mastered By"]
        held.creditTracks = ["", ""]
        held.styles = ["Indie Rock"]
        held.genres = ["Rock"]
        context.insert(held)
        let profile = RecordProfile(record: held)
        XCTAssertEqual(profile.personnel, ["name:jason albertini"])

        let seed = record(40, "Helvetia", ["Indie Rock"], personnel: ["name:jason albertini"])
        let other = record(41, "Not Them", ["Indie Rock"])
        let similarity = RecordSimilarity(pool: [profile, other])
        let withPlayer = similarity.judge(profile, against: seed)
        XCTAssertGreaterThan(withPlayer.score, similarity.judge(other, against: seed).score)
        XCTAssertTrue(withPlayer.reason.contains("Jason Albertini on both"), withPlayer.reason)
    }

    func testTheSameInAnyOrder() {
        let forward = RecordSimilarity(pool: pool).similar(to: record(50, "Seed", ["Slowcore", "Dream Pop"]))
        let backward = RecordSimilarity(pool: pool.reversed()).similar(to: record(50, "Seed", ["Slowcore", "Dream Pop"]))
        XCTAssertEqual(forward.map(\.record.id), backward.map(\.record.id))
        XCTAssertEqual(forward.map(\.score.bitPattern), backward.map(\.score.bitPattern))
    }

    /// One tag matches everything with that tag perfectly: weak evidence.
    func testAOneStyleRecordIsWeakerEvidence() {
        let similarity = RecordSimilarity(pool: pool)
        let one = similarity.judge(pool[1], against: record(60, "Seed", ["Slowcore"]))
        let two = similarity.judge(pool[1], against: record(61, "Seed", ["Slowcore", "Indie Rock"]))
        XCTAssertLessThan(one.score, two.score)
    }

    func testSeveralSeedsOnePerArtistAndAFewPerSeed() {
        let similarity = RecordSimilarity(pool: pool)
        let found = similarity.similar(to: [pool[0], pool[9]], limit: 6, perSeed: 2)
        XCTAssertEqual(Set(found.map { $0.match.record.artistLine }).count, found.count)
        XCTAssertLessThanOrEqual(Dictionary(grouping: found, by: \.seed.id).values.map(\.count).max() ?? 0, 2)
        XCTAssertFalse(found.contains { $0.match.record.id == 1 || $0.match.record.id == 10 }, "Not the seeds")
    }
}
