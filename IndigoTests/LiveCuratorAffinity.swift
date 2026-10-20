//
//  LiveCuratorAffinity.swift
//  IndigoTests
//
//  Radio Discover's curator affinity on a copy of this Mac's stores, live and
//  read-only: the compatible programmes per taste cluster, then each pick
//  with its programmes, evidence, playback source and cluster, and the cost.
//
//  Opt-in: `INDIGO_LIVE_MB_REACH=1`. Report: `curator-affinity.txt` in the
//  host's temporary directory (private: it is this listener's history).
//

import XCTest
import SwiftData
import Supabase
@testable import Indigo

final class LiveCuratorAffinity: XCTestCase {
    func testCuratorAffinityForThisListener() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else { throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.") }
        let dir = FileManager.default.temporaryDirectory
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("Curators-\(UUID().uuidString)")
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
        let inputs = try XCTUnwrap(RadioDiscover.inputs(context: ModelContext(container)))
        DiscogsIdentityRows.override = true
        defer { DiscogsIdentityRows.override = nil }

        // The compatible programmes, as discover chooses them.
        let source = RadioDiscoverSource.live
        let rows = try await source.rows(Array(Set(inputs.seeds.map(\.id))))
        var seedSlots: [RadioDiscover.Slot] = []
        for cluster in inputs.labels.keys.sorted() {
            let ids = Set(inputs.seeds.filter { $0.cluster == cluster }.flatMap { rows[$0.id] ?? [] })
            if !ids.isEmpty { seedSlots += try await source.seedAppearances(Array(ids)) }
        }
        let affinities = RadioDiscover.affinities(inputs: inputs, rows: rows, seedSlots: seedSlots)
        var lines = ["Curator affinity for this Mac's listener: \(inputs.seeds.count) seeds over \(inputs.labels.count) clusters; \(Set(seedSlots.compactMap { $0.radio_episodes?.programmeKey }).count) programmes play them; \(affinities.count) programme–cluster affinities"]
        for cluster in inputs.labels.keys.sorted() {
            let top = affinities.filter { $0.cluster == cluster }.prefix(4)
            lines.append(String(format: "c%d (share %.2f) ", cluster, inputs.shares[cluster] ?? 0) + "\(inputs.labels[cluster] ?? ""): seeds \(inputs.seeds.filter { $0.cluster == cluster }.map(\.name).joined(separator: ", "))")
            for a in top { lines.append(String(format: "    %@%@ — %.2f: plays %@ in %d episodes", a.title, a.curator.map { " (\($0))" } ?? "", a.score, a.seeds.joined(separator: ", "), a.episodes)) }
            if top.isEmpty { lines.append("    no programme returns to this cluster's artists") }
        }

        let started = ContinuousClock.now
        let before = await source.catalogueReads()
        let result = try await RadioDiscover(source: source).discover(inputs)
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        let curated = result.picks.filter { $0.distance == 0 }
        lines.append("")
        lines.append(String(format: "Picks: %d (%d by curator affinity, %d by episode adjacency); %d catalogue reads; %d playback checks; %.0f s",
                            result.picks.count, curated.count, result.picks.count - curated.count, await source.catalogueReads() - before, result.checked, seconds))
        for (n, pick) in result.picks.enumerated() {
            let how: String
            switch pick.track.source {
            case .recording(let url, _): how = "Play Track — \(url.absoluteString)"
            case .episode(let listen, let at): how = "Hear in Radio Show — \(listen.showTitle ?? listen.provider): \(listen.episodeTitle) at \(at / 60):\(String(format: "%02d", at % 60)) (\(listen.archiveURL.absoluteString))"
            }
            let known = inputs.known.contains(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(pick.track.artist)))
            lines.append("")
            lines.append("\(n + 1). \(pick.track.artist) — \(pick.track.title)  [\(pick.distance == 0 ? "curator affinity" : "adjacency")]")
            lines.append("   programme: \(pick.programme)\(pick.curator.map { " · \($0)" } ?? ""); episode: \(pick.episode)")
            lines.append("   evidence: \(pick.track.reason)")
            lines.append("   card: \(pick.connection) — \(pick.strength)")
            lines.append("   plays: \(how) — \(pick.timing.label)")
            lines.append("   new to you: \(known ? "NO" : "yes"); cluster: c\(pick.cluster) \(pick.clusterLabel); artist's own styles: \(pick.styles.isEmpty ? "unknown" : pick.styles.joined(separator: ", "))")
        }
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("curator-affinity.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(result.picks.count, 5)
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

    /// The catalogue as it stood at a cut-off: identity links and radio
    /// appearances created before it, episodes aired before it. Programme
    /// counts (damping), play checks and release videos are today's.
    private static func dated(before cutoff: Date, plays: Plays) -> RadioDiscoverSource {
        let stamp = ISO8601DateFormatter().string(from: cutoff)
        let columns = "artist_id,raw_artist_name,raw_track_title,track_index,offset_seconds,media_url,radio_episodes!inner(id,radio_show_id,provider,external_id,archive_url,title,aired_at,image_url,duration_seconds,radio_shows(title,host_name))"
        var source = RadioDiscoverSource.live
        source.rows = { ids in
            guard !ids.isEmpty else { return [:] }
            let client = try SupabaseService.requireClient()
            let links: [DiscogsIdentityRows.Link] = try await client.from("external_ids").select("entity_id,provider,external_id")
                .eq("entity_type", value: "artist").in("provider", values: DiscogsIdentityRows.providers)
                .in("external_id", values: ids.map(String.init)).lt("created_at", value: stamp).limit(1000).execute().value
            let rowIDs = Array(Set(links.map(\.entity_id)))
            guard !rowIDs.isEmpty else { return [:] }
            let all: [DiscogsIdentityRows.Link] = try await client.from("external_ids").select("entity_id,provider,external_id")
                .eq("entity_type", value: "artist").in("provider", values: DiscogsIdentityRows.providers)
                .in("entity_id", values: rowIDs.map(\.uuidString)).lt("created_at", value: stamp).limit(2000).execute().value
            var out: [Int: [UUID]] = [:]
            for (row, identity) in RadioDiscover.identities(all, names: Dictionary(uniqueKeysWithValues: rowIDs.map { ($0, "Verified seed") }))
            where ids.contains(identity.id) { out[identity.id, default: []].append(row) }
            return out
        }
        source.seedAppearances = { ids in
            try await SupabaseService.requireClient().from("radio_appearances").select(columns)
                .in("artist_id", values: ids.map(\.uuidString)).in("radio_episodes.provider", values: ["nts", "lotradio"])
                .lt("radio_episodes.aired_at", value: stamp).lt("created_at", value: stamp)
                .order("radio_episode_id").order("track_index").limit(240).execute().value
        }
        source.tracklists = { ids in
            guard !ids.isEmpty else { return [] }
            var out: [RadioDiscover.Slot] = []
            for page in 0..<3 {
                let part: [RadioDiscover.Slot] = try await SupabaseService.requireClient().from("radio_appearances").select(columns)
                    .in("radio_episode_id", values: ids.map(\.uuidString)).lt("created_at", value: stamp)
                    .order("radio_episode_id").order("track_index").range(from: page * 1000, to: page * 1000 + 999).execute().value
                out += part
                if part.count < 1000 { break }
            }
            return out
        }
        source.programmeEpisodes = { shows, perShow in
            struct Row: Decodable { let id: UUID }
            var out: [UUID] = []
            for show in shows {
                let rows: [Row] = try await SupabaseService.requireClient().from("radio_episodes").select("id").eq("radio_show_id", value: show.uuidString)
                    .lt("aired_at", value: stamp).order("aired_at", ascending: false).limit(perShow).execute().value
                out += rows.map(\.id)
            }
            return out
        }
        source.identities = { ids in
            guard !ids.isEmpty else { return [:] }
            let client = try SupabaseService.requireClient()
            struct Name: Decodable { let id: UUID; let name: String }
            var names: [Name] = [], links: [DiscogsIdentityRows.Link] = []
            for offset in stride(from: 0, to: ids.count, by: 100) {
                let batch = Array(ids[offset..<min(offset + 100, ids.count)]).map(\.uuidString)
                names += try await client.from("artists").select("id,name").in("id", values: batch).limit(100).execute().value as [Name]
                links += try await client.from("external_ids").select("entity_id,provider,external_id").eq("entity_type", value: "artist")
                    .in("provider", values: DiscogsIdentityRows.providers).in("entity_id", values: batch)
                    .lt("created_at", value: stamp).limit(1000).execute().value as [DiscogsIdentityRows.Link]
            }
            return RadioDiscover.identities(links, names: Dictionary(names.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        source.plays = { await plays.check($0) }
        return source
    }

    /// Adjacency alone (Radio Discover before curator affinity) against
    /// curator affinity, over the same four dated cut-offs as the For You
    /// replay: finds are picks by artists the listener first met later.
    func testCuratorAffinityOverCutoffs() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else { throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.") }
        let dir = FileManager.default.temporaryDirectory
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("CuratorCutoffs-\(UUID().uuidString)")
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
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }
        let allRecords = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let allRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)
        let plays = Plays()
        var lines: [String] = [], totals: [String: (picks: Int, finds: Int, curated: Int, reads: Int, seconds: Double)] = [:]
        for days in [21, 14, 10, 7] {
            let cutoff = last.addingTimeInterval(-Double(days) * 86_400)
            let openedLater = Set(visits.filter { $0.kind == .artist && $0.firstVisitedAt >= cutoff }.map { key($0.title) })
            let datedRows = allRows.filter { $0.fetchedAt < cutoff && !openedLater.contains($0.nameKey) }
            let rowByKey = Dictionary(datedRows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
            var onDevice = Set<Int>()
            for visit in visits where visit.firstVisitedAt < cutoff && visit.kind == .release { if let id = visit.discogsID { onDevice.insert(id) } }
            for row in datedRows { onDevice.formUnion(row.releaseDiscogsIDs) }
            let datedPool = allRecords.filter { onDevice.contains($0.id) }
            let vectors = RecordSimilarity(pool: datedPool).vectors
            let book = ListenerRetrieval.StyleBook(entries: datedRows.map { (key: $0.nameKey, id: $0.discogsID, styles: $0.styles) },
                                                   records: datedPool, vectors: vectors)
            var pastRead = ListenerProfile.read(context: context, before: cutoff)
            pastRead.artistStyles = pastRead.artistStyles.filter { rowByKey[$0.key] != nil }
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            guard !past.clusters.isEmpty else { continue }
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)
            let later = Set(whole.evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }.map(\.artist)).subtracting(known)
            let held = ClusterSeedPicks.Inputs(profile: past, vectors: vectors, seeds: ListenerRetrieval.seeds(past, vectors: vectors), entries: [:],
                                               releaseIDs: [:], book: book, known: known)
            let inputs = RadioDiscover.inputs(from: held, rows: datedRows)
            lines.append("== cut-off \(days)d (\(cutoff.formatted(date: .abbreviated, time: .omitted))): \(later.count) later artists; \(inputs.seeds.count) seeds over \(inputs.labels.count) clusters")
            for (arm, curators) in [("adjacency only ", false), ("curator affinity", true)] {
                let source = Self.dated(before: cutoff, plays: plays)
                let started = ContinuousClock.now
                let before = await source.catalogueReads()
                let result = try await RadioDiscover(source: source, curators: curators).discover(inputs)
                let seconds = Double((ContinuousClock.now - started).components.seconds)
                let hits = result.picks.filter { later.contains(key($0.track.artist)) }
                let curated = result.picks.filter { $0.distance == 0 }.count
                var t = totals[arm] ?? (0, 0, 0, 0, 0)
                t.picks += result.picks.count; t.finds += hits.count; t.curated += curated; t.reads += await source.catalogueReads() - before; t.seconds += seconds
                totals[arm] = t
                lines.append(String(format: "  %@: %d picks (%d curated), finds %d%@; %.0f s", arm, result.picks.count, curated, hits.count,
                                    hits.isEmpty ? "" : " (" + hits.map(\.track.artist).joined(separator: ", ") + ")", seconds))
                for pick in result.picks { lines.append("      \(later.contains(key(pick.track.artist)) ? "★ " : "")\(pick.track.artist) — \(pick.track.title) [\(pick.distance == 0 ? "curator" : "adjacent")] \(pick.programme)") }
            }
        }
        lines.insert(contentsOf: ["Radio Discover over dated cut-offs (dated links, appearances, episodes; play checks today)"]
                     + totals.sorted { $0.key < $1.key }.map { String(format: "  %@: %d picks (%d curated), finds %d; %.0f s", $0.key, $0.value.picks, $0.value.curated, $0.value.finds, $0.value.seconds) }, at: 0)
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("curator-affinity-cutoffs.txt"), atomically: true, encoding: .utf8)
    }
}
