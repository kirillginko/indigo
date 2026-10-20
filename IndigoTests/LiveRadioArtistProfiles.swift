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

    /// Kept on disk as they arrive, so a host that goes away mid-census
    /// resumes where it was. A failed lookup is asked again next time.
    private actor Profiles {
        let file: URL
        var memo: [Int: RadioArtistProfile] = [:]
        init(file: URL) {
            self.file = file
            if let data = try? Data(contentsOf: file), let held = try? JSONDecoder().decode([Int: RadioArtistProfile].self, from: data) {
                memo = held.filter { $0.value.source != .failed }
            }
        }
        func get(_ ids: [Int]) async -> [Int: RadioArtistProfile] {
            var out: [Int: RadioArtistProfile] = [:]
            for id in Set(ids).sorted() {
                if let held = memo[id] { out[id] = held; continue }
                let found = await RadioArtistProfiles.live.profile(discogsID: id)
                memo[id] = found
                out[id] = found
                if memo.count % 10 == 0, let data = try? JSONEncoder().encode(memo) { try? data.write(to: file, options: .atomic) }
            }
            if let data = try? JSONEncoder().encode(memo) { try? data.write(to: file, options: .atomic) }
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
        let plays = Plays(), profiles = Profiles(file: dir.appendingPathComponent("radio-artist-profiles-memo.json"))
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
        let reportFile = dir.appendingPathComponent("radio-artist-profiles.txt")
        try lines.joined(separator: "\n").write(to: reportFile, atomically: true, encoding: .utf8)
        let linkedStarted = ContinuousClock.now
        let linkedProfiles = await profiles.get(linkedIDs.sorted())
        census("MusicBrainz-linked artists", linkedProfiles)
        lines.append(String(format: "  (%.0f s)", Double((ContinuousClock.now - linkedStarted).components.seconds)))
        let examples = linkedProfiles.values.filter { !$0.styles(known: vectors).styles.isEmpty }.sorted { ($0.name ?? "") < ($1.name ?? "") }.prefix(15)
        for p in examples { lines.append("  " + describe(p, vectors: vectors)) }
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: reportFile, atomically: true, encoding: .utf8)
    }

    /// MusicBrainz JSON, one request every 1.1 s, identified as the app.
    private actor MB {
        var last = Date.distantPast
        func get(_ path: String, _ query: [URLQueryItem]) async -> [String: Any]? {
            let wait = 1.1 - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            last = Date()
            var c = URLComponents(string: "https://musicbrainz.org/ws/2/" + path)!
            c.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
            var request = URLRequest(url: c.url!, timeoutInterval: 15)
            request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// Each radio-fill pick as a recording: the track, its MusicBrainz
    /// recording (found by title among the verified artist's own), that
    /// recording's release and genres, the taste cluster it and its artist
    /// match, the evidence, and how it plays.
    func testFillRecordings() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else { throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.") }
        let dir = FileManager.default.temporaryDirectory
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("Recordings-\(UUID().uuidString)")
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
        let inputs = try XCTUnwrap(ClusterSeedPicks.inputs(context: ModelContext(container), vectors: [:]))
        let vectors = inputs.vectors
        let plays = Plays(), profiles = Profiles(file: dir.appendingPathComponent("radio-artist-profiles-memo.json")), mb = MB()
        let scorer = ListenerProfile.Scorer(inputs.profile, vectors: vectors)
        func cluster(_ styles: [String]) -> String {
            guard let r = scorer.relevance(styles), let c = inputs.profile.clusters.first(where: { $0.id == r.cluster }) else { return "none (no style in the space)" }
            return String(format: "c%d %@ — fit %.2f (e.g. %@)", c.id, c.label.prefix(3).joined(separator: " / "), r.score,
                          c.examples.prefix(2).map { "\($0.artist)" }.joined(separator: ", "))
        }
        func names(_ list: Any?) -> [String] {
            ((list as? [[String: Any]]) ?? []).filter { (($0["count"] as? Int) ?? 0) > 0 }
                .sorted { (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0) }.compactMap { $0["name"] as? String }
        }
        DiscogsIdentityRows.override = true
        ForYouRadioCandidatesFeature.override = true
        ClusterSeedPicks.radioShare = 0
        var plain = ClusterSeedPicks(); plain.store = nil; plain.plays = { await plays.check($0) }
        var profiled = plain; profiled.radioProfiles = { await profiles.get($0) }
        ForYouRadioCandidatesFeature.override = false
        let baseline = await plain.picks(inputs, excluding: [], limit: 20)
        ForYouRadioCandidatesFeature.override = true
        let fill = Array(await profiled.picks(inputs, excluding: [], limit: 20).dropFirst(baseline.count))
        let held = await profiles.get(fill.map(\.artistDiscogsID))
        var lines = ["Radio fill as recordings (limit 20; baseline \(baseline.count) unchanged; fill \(fill.count))", ""]
        for (n, t) in fill.enumerated() {
            let p = held[t.artistDiscogsID]
            var clean = t.title.replacingOccurrences(of: #"^\s*\d+[\.\-\)]\s*"#, with: "", options: .regularExpression)
            clean = String(clean.split(separator: "|").first ?? Substring(clean)).trimmingCharacters(in: .whitespaces)
            clean = clean.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
            var recording: [String: Any]?
            if let mbid = p?.musicBrainzID {
                for title in [clean, clean.replacingOccurrences(of: #"\s*\([^\)]*\)"#, with: "", options: .regularExpression)] where recording == nil {
                    let q = "arid:\(mbid) AND recording:\"\(title.replacingOccurrences(of: "\"", with: ""))\""
                    let found = await mb.get("recording", [URLQueryItem(name: "query", value: q), URLQueryItem(name: "limit", value: "5")])
                    recording = ((found?["recordings"] as? [[String: Any]]) ?? []).first { (($0["score"] as? Int) ?? 0) >= 90 }
                }
            }
            var recGenres: [String] = [], rgGenres: [String] = [], releaseLine = "no MusicBrainz recording matched the title"
            if let id = recording?["id"] as? String, let full = await mb.get("recording/\(id)", [URLQueryItem(name: "inc", value: "genres+tags+releases+release-groups")]) {
                recGenres = ListeningLog.foldTags(names(full["genres"]) + names(full["tags"]))
                // The artist's own release first: a compilation's genres are everyone's on it.
                let releases = ((full["releases"] as? [[String: Any]]) ?? []).sorted { (($0["date"] as? String) ?? "9999") < (($1["date"] as? String) ?? "9999") }
                func own(_ r: [String: Any]) -> Bool { (((r["release-group"] as? [String: Any])?["secondary-types"] as? [String]) ?? []).isEmpty }
                if let first = releases.first(where: own) ?? releases.first {
                    let group = first["release-group"] as? [String: Any]
                    releaseLine = "\(first["title"] as? String ?? "?") (\((first["date"] as? String)?.prefix(4) ?? "?"), \(group?["primary-type"] as? String ?? "?")\(own(first) ? "" : ", compilation: no own release")); \(releases.count) releases"
                    if let rg = group?["id"] as? String, let g = await mb.get("release-group/\(rg)", [URLQueryItem(name: "inc", value: "genres+tags")]) {
                        rgGenres = ListeningLog.foldTags(names(g["genres"]) + names(g["tags"]))
                    }
                }
            }
            let recordingStyles = (recGenres + rgGenres).filter { vectors[$0] != nil }
            let artistStyles = p?.styles(known: vectors).styles ?? []
            let how: String
            switch t.source {
            case .recording(let url, let channel): how = "Play Track — a radio row's upload\(channel.map { " (via \($0))" } ?? ""): \(url.absoluteString)"
            case .episode(let listen, let at): how = "Hear in Radio Show — \(listen.showTitle ?? listen.provider): \(listen.episodeTitle) at \(at)s"
            }
            lines.append("\(n + 1). \(t.artist) — \(t.title)")
            lines.append("   plays: \(how)")
            lines.append("   recording: \(recording.map { "\($0["title"] as? String ?? "?") [mb \(String(($0["id"] as? String ?? "").prefix(8)))], score \($0["score"] as? Int ?? 0)" } ?? "—"); first release: \(releaseLine)")
            lines.append("   recording genres: \(recGenres.isEmpty ? "none" : recGenres.prefix(6).joined(separator: ", ")); release-group genres: \(rgGenres.isEmpty ? "none" : rgGenres.prefix(6).joined(separator: ", "))")
            lines.append("   artist genres: \(p?.genres.prefix(5).joined(separator: ", ") ?? "-")")
            lines.append("   cluster by the recording: \(recordingStyles.isEmpty ? "none (no recording-level style in the space)" : cluster(recordingStyles))")
            lines.append("   cluster by the artist:    \(artistStyles.isEmpty ? "none" : cluster(artistStyles))")
            lines.append("   evidence: \(t.reason) (seed \(t.via)); verified Discogs \(t.artistDiscogsID) → MusicBrainz \(p?.musicBrainzID?.prefix(8) ?? "-") by Discogs URL relation")
            lines.append("")
        }
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("radio-fill-recordings.txt"), atomically: true, encoding: .utf8)
    }
}
