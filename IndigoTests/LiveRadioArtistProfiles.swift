//
//  LiveRadioArtistProfiles.swift
//  IndigoTests
//
//  What independent profiles (`RadioArtistProfiles`: MusicBrainz, reached by
//  Discogs id) give verified radio artists, live and read-only:
//
//  - Census: the MusicBrainz-linked artists (the input's pilotSeeds) and this
//    Mac's listener's radio candidates -- how many have a MusicBrainz artist,
//    genres, tags, styles the listener's style space knows, release groups.
//  - The listener's For You radio fill (`ClusterSeedPicks`, fill only)
//    without and with profiles, each fill artist's profile shown.
//
//  Opt-in: `INDIGO_LIVE_MB_REACH=1`, input as `LiveMusicBrainzIdentityReach`.
//  Report: `radio-artist-profiles.txt` in the host's temporary directory.
//  About 2 MusicBrainz requests per artist, one a second.
//

import XCTest
import SwiftData
@testable import Indigo

final class LiveRadioArtistProfiles: XCTestCase {
    private struct Input: Decodable {
        struct Seed: Decodable { let discogs: Int; let name: String }
        let pilotSeeds: [Seed]
    }

    private actor Plays {
        var memo: [String: Bool?] = [:]
        func check(_ source: DiscoveredTrack.Source) async -> Bool? {
            let key = String(describing: source)
            if let held = memo[key] { return held }
            let answer = await TrackDiscoverySource.live.plays(source)
            memo[key] = answer
            return answer
        }
    }

    private actor Profiles {
        var memo: [Int: RadioArtistProfile] = [:]
        func get(_ ids: [Int]) async -> [Int: RadioArtistProfile] {
            var out: [Int: RadioArtistProfile] = [:]
            for id in Set(ids).sorted() {
                if let held = memo[id] { out[id] = held; continue }
                let found = await RadioArtistProfiles.live.profile(discogsID: id)
                memo[id] = found
                out[id] = found
            }
            return out
        }
    }

    override func tearDown() {
        DiscogsIdentityRows.override = nil; ForYouRadioCandidatesFeature.override = nil
        ClusterSeedPicks.radioShare = 0; ClusterSeedPicks.radioGenreStyles = false
    }

    private func describe(_ p: RadioArtistProfile, vectors: [String: [String: Double]]) -> String {
        let (styles, source) = p.styles(known: vectors)
        let years = p.years.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "-"
        return "\(p.name ?? "?") [mb \(p.musicBrainzID?.prefix(8) ?? "-")]: genres \(p.genres.prefix(5).joined(separator: ", ")); tags \(p.tags.prefix(5).joined(separator: ", ")); \(p.releaseGroups) release groups (\(p.albums) albums, \(years)) → styles \(styles.isEmpty ? "unknown" : styles.joined(separator: ", ")) (\(source.rawValue))"
    }

    func testProfilesAndTheRadioFill() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else { throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.") }
        let dir = FileManager.default.temporaryDirectory
        let inputName = ProcessInfo.processInfo.environment["INDIGO_MB_REACH_INPUT"] ?? "pilot-dig-seeds.json"
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: dir.appendingPathComponent(inputName)))
        let linkedIDs = Set(input.pilotSeeds.map(\.discogs))
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("Profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        let inputs = try XCTUnwrap(ClusterSeedPicks.inputs(context: context, vectors: [:]))
        let vectors = inputs.vectors
        let plays = Plays(), profiles = Profiles()
        var lines = ["Radio artist profiles (MusicBrainz by Discogs id); style space: \(vectors.count) styles"]

        // The listener's fill, without and with profiles.
        DiscogsIdentityRows.override = true
        ForYouRadioCandidatesFeature.override = true
        ClusterSeedPicks.radioShare = 0
        func picker(profiled: Bool) -> ClusterSeedPicks {
            var p = ClusterSeedPicks()
            p.store = nil
            p.plays = { await plays.check($0) }
            if profiled { p.radioProfiles = { await profiles.get($0) } }
            return p
        }
        let radio = await picker(profiled: false).radioCandidates(inputs)
        let radioIDs = Set(radio.sightings.compactMap(\.discogsID))
        let unstyled = radioIDs.filter { inputs.book.byID[$0] == nil && inputs.book.recordsByID[$0] == nil }
        let started = ContinuousClock.now
        let radioProfiles = await profiles.get(radioIDs.sorted())
        let profileSeconds = Double((ContinuousClock.now - started).components.seconds)
        for limit in [20] {
            ForYouRadioCandidatesFeature.override = false
            let baseline = await picker(profiled: false).picks(inputs, excluding: [], limit: limit)
            ForYouRadioCandidatesFeature.override = true
            let plain = await picker(profiled: false).picks(inputs, excluding: [], limit: limit)
            let profiled = await picker(profiled: true).picks(inputs, excluding: [], limit: limit)
            for (name, run) in [("fill, no profiles", plain), ("fill, with profiles", profiled)] {
                let fill = Array(run.dropFirst(baseline.count))
                lines.append("\(name) (limit \(limit)): baseline \(baseline.count) kept in place \(Array(run.prefix(baseline.count)).map(\.id) == baseline.map(\.id)); fill \(fill.count)")
                for t in fill {
                    let p = radioProfiles[t.artistDiscogsID]
                    lines.append("  \(linkedIDs.contains(t.artistDiscogsID) ? "◆ " : "")\(t.artist) — \(t.title) [\(t.isRecording ? "Play Track" : "Hear in Radio Show")] \(t.reason)")
                    lines.append("      " + (p.map { describe($0, vectors: vectors) } ?? "no profile") + (t.tags.map { "; scored on \($0.joined(separator: ", "))" } ?? "; scored unstyled"))
                }
            }
            // How each candidate in the fill pool ranks, with and without profiles.
            var styled = radio
            await picker(profiled: true).profile(&styled, inputs: inputs)
            let scorer = ListenerProfile.Scorer(inputs.profile, vectors: vectors)
            let after = ClusterSeedPicks.ranked(inputs, credits: [:], excluding: [], radio: styled, radioShare: 0).filter(ClusterSeedPicks.isRadioOnly)
            lines.append("fill pool with profiles (radio-only candidates, \(after.count)), in fill order:")
            for (i, c) in after.prefix(25).enumerated() {
                let fit = scorer.relevance(c.styles).map { String(format: "%.2f c%d", $0.score, $0.cluster) } ?? "-"
                lines.append("  #\(i + 1) \(c.name): \(c.styles.isEmpty ? "unknown" : c.styles.joined(separator: ", ")) (\(c.styleSource)); fit \(fit); \(c.best.why)")
            }
        }

        // Census.
        func census(_ name: String, _ found: [Int: RadioArtistProfile]) {
            let all = Array(found.values)
            func n(_ test: (RadioArtistProfile) -> Bool) -> Int { all.filter(test).count }
            let bySource = Dictionary(grouping: all, by: { $0.styles(known: vectors).source.rawValue }).mapValues(\.count)
            lines.append("\(name): \(all.count) artists; a MusicBrainz artist \(n { $0.musicBrainzID != nil }) (ambiguous \(n { $0.source == .ambiguous }), unlinked \(n { $0.source == .unlinked }), failed \(n { $0.source == .failed })); genres \(n { !$0.genres.isEmpty }); tags \(n { !$0.tags.isEmpty }); release groups \(n { $0.releaseGroups > 0 }) (albums \(n { $0.albums > 0 }), years \(n { $0.years != nil })); styles the space knows: " + bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            let genreCounts = Dictionary(all.flatMap { $0.genres.prefix(3) }.map { ($0, 1) }, uniquingKeysWith: +)
            lines.append("  commonest genres: " + genreCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(20).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        lines.append(String(format: "Profiles for the listener's %d radio candidates (%d without device styles): %.0f s", radioIDs.count, unstyled.count, profileSeconds))
        census("Listener's radio candidates", radioProfiles)
        let linkedStarted = ContinuousClock.now
        let linkedProfiles = await profiles.get(linkedIDs.sorted())
        census("MusicBrainz-linked artists", linkedProfiles)
        lines.append(String(format: "  (%.0f s)", Double((ContinuousClock.now - linkedStarted).components.seconds)))
        let examples = linkedProfiles.values.filter { !$0.styles(known: vectors).styles.isEmpty }.sorted { ($0.name ?? "") < ($1.name ?? "") }.prefix(15)
        for p in examples { lines.append("  " + describe(p, vectors: vectors)) }
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("radio-artist-profiles.txt"), atomically: true, encoding: .utf8)
    }
}
