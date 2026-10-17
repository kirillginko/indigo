//
//  ListenerExpansionReplay.swift
//  IndigoTests
//
//  Listener Profile v2, Phase 3: what For You would offer if its pool grew
//  -- its own routes, then one step from every taste cluster, then bounded
//  radio (one tracklist offers three artists and counts once), then records
//  near each cluster's centre -- and whether what it offers can be played.
//
//  Knowledge is dated as in `ListenerRetrievalReplay`: Discogs entries fetched
//  before the cut-off and not first opened after it, the records they or
//  earlier pages list, a style space learned from those, and radio episodes
//  aired before the cut-off. Later finds count as artists and as listening
//  sessions (no gap over 45 minutes). A cut-off of 0 is today: no finds to
//  score, only the lists, for before/after examples.
//
//  Playable: a recording of the artist's own, matched to a release
//  tracklist from what Indigo keeps (`ReleaseVideoTracks`, no Discogs
//  budget) and confirmed by YouTube's oEmbed. Only for candidates with a
//  verified Discogs id -- by the catalogue's own id or the device's entry for
//  that exact name -- never guessed. Playability is today's, at every cut-off.
//
//  Reads the shared catalogue, R2 and YouTube oEmbed (read-only). Opt-in:
//  `INDIGO_EXPANSION_REPLAY=1`. Report (private, artist names):
//  `listener-expansion-replay.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListenerExpansionReplay: XCTestCase {
    /// A verified way to hear an artist, most direct first: a recording of
    /// their own from a release's catalogued videos, a recording the radio
    /// tracklists link, or the moment in an archived show where they were
    /// played. Each confirmed to play.
    actor Playable {
        enum Found: Sendable { case recording(String, URL, from: String), moment(String, show: String) }
        var held: [Int: Found?] = [:]
        var why: [Int: String] = [:]
        var requests = 0
        // As the app reads it: the shelf cache is off in a test process
        // unless asked for.
        let shelves = CatalogShelfSource(isEnabled: true)
        func check(_ id: Int, _ name: String) async -> Found? {
            if let known = held[id] { return known }
            var found: Found?
            var reasons: [String] = []
            requests += 4
            let videos = ReleaseVideoTracks(shelf: { [shelves] in await shelves.shelf(discogsID: $0) }, release: ReleaseVideoTracks.live.release)
            let own = await videos.tracks(artistID: id, artist: name)
            if own.isEmpty { reasons.append("no release video") }
            for appearance in own {
                guard case .recording(let url, _) = appearance.source else { continue }
                requests += 1
                if await YouTubeAvailability.isPlayable(url) == true { found = .recording(appearance.title, url, from: "release video"); break }
            }
            if found == nil {
                requests += 2
                let rows = (try? await RadioListenFinder.live.rows([id]))?[id] ?? []
                let appearances = rows.isEmpty ? [] : ((try? await TrackDiscoverySource.live.appearances(rows)) ?? [])
                if rows.isEmpty { reasons.append("not in the radio catalogue") }
                else if appearances.isEmpty { reasons.append("no radio appearance") }
                for row in appearances.prefix(6) {
                    guard let media = row.media_url.flatMap(URL.init(string:)), YouTubeLink.isYouTube(media) else { continue }
                    requests += 1
                    if await YouTubeAvailability.isPlayable(media) == true { found = .recording(row.raw_track_title ?? name, media, from: "radio tracklist"); break }
                }
                if found == nil {
                    for row in appearances.prefix(4) {
                        guard let episode = row.radio_episodes, let archive = episode.archive_url.flatMap(URL.init(string:)) else { continue }
                        requests += 1
                        let provider = episode.provider == "lotradio" ? "lot" : episode.provider
                        if await RadioListenFinder.playable(provider: provider, url: archive) == true {
                            found = .moment(row.raw_track_title ?? name, show: episode.radio_shows?.title ?? episode.title ?? provider); break
                        }
                    }
                    if !appearances.isEmpty, found == nil { reasons.append("nothing on radio plays") }
                }
            }
            held[id] = found
            if found == nil { why[id] = reasons.joined(separator: ", ") }
            return found
        }
        func reasons(_ ids: [Int]) -> [String: Int] {
            var out: [String: Int] = [:]
            for id in ids { if let r = why[id] { out[r, default: 0] += 1 } }
            return out
        }
    }

    func testExpandedPoolsAgainstForYou() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_EXPANSION_REPLAY"] == "1", "Set INDIGO_EXPANSION_REPLAY=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Expansion-\(UUID().uuidString)")
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
        var out: [String] = []
        var summary: [String] = []
        var examples: [String] = []
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }

        let allRecords = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let allRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let anyRowByKey = Dictionary(allRows.filter { $0.discogsID > 0 }.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)
        let playable = Playable()
        var totals: [String: [Int]] = [:]   // label → [finds, sessions, playable, slots]

        for days in [21, 14, 10, 7, 0] {
            let cutoff = days == 0 ? last.addingTimeInterval(3_600) : last.addingTimeInterval(-Double(days) * 86_400)
            let openedLater = Set(visits.filter { $0.kind == .artist && $0.firstVisitedAt >= cutoff }.map { key($0.title) })
            let datedRows = allRows.filter { $0.fetchedAt < cutoff && !openedLater.contains($0.nameKey) }
            let rowByKey = Dictionary(datedRows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
            var onDevice = Set<Int>()
            for visit in visits where visit.firstVisitedAt < cutoff && visit.kind == .release { if let id = visit.discogsID { onDevice.insert(id) } }
            for row in datedRows { onDevice.formUnion(row.releaseDiscogsIDs) }
            let datedPool = allRecords.filter { onDevice.contains($0.id) }
            let vectors = RecordSimilarity(pool: datedPool).vectors
            var styleByKey: [String: [String]] = [:]
            for row in datedRows where !row.styles.isEmpty { styleByKey[row.nameKey] = ListeningLog.foldTags(row.styles).filter { vectors[$0] != nil } }
            let rowByID = Dictionary(datedRows.filter { $0.discogsID > 0 }.map { ($0.discogsID, $0) }, uniquingKeysWith: { a, _ in a })
            var recordStyles: [String: [String]] = [:]
            for record in datedPool { for k in record.artistKeys { recordStyles[k, default: []] += record.styles.filter { vectors[$0] != nil } } }

            var pastRead = ListenerProfile.read(context: context, before: cutoff)
            pastRead.artistStyles = pastRead.artistStyles.filter { rowByKey[$0.key] != nil }
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)

            let future = whole.evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }.sorted { ($0.at, $0.unit) < ($1.at, $1.unit) }
            let later = Set(future.map(\.artist)).subtracting(known)
            var sessionOf: [String: Int] = [:]
            var session = 0
            var previous: Date?
            for item in future {
                if let previous, item.at.timeIntervalSince(previous) > 45 * 60 { session += 1 }
                previous = item.at
                if later.contains(item.artist), sessionOf[item.artist] == nil { sessionOf[item.artist] = session }
            }
            let laterSessions = Set(sessionOf.values).count
            var futureTaste: [String: Double] = [:]
            for item in future {
                let styles = (whole.styles[item.unit] ?? whole.artistStyles[item.artist] ?? item.tags).filter { vectors[$0] != nil }
                for style in styles { futureTaste[style, default: 0] += item.signal.weight * item.strength / Double(styles.count) }
            }
            let futureVector = MusicalCompass.embed(futureTaste, vectors: vectors)
            out.append("")
            out.append(days == 0 ? "######## today (\(cutoff.formatted(date: .abbreviated, time: .omitted))): lists only"
                       : "######## cut-off \(days) days (\(cutoff.formatted(date: .abbreviated, time: .omitted))): \(later.count) later artists in \(laterSessions) sessions")
            out.append("clusters: " + past.clusters.map { "\($0.label.prefix(2).joined(separator: "/")) \(Int((100 * max($0.longTermShare, $0.recentShare)).rounded()))%" }.joined(separator: ", "))

            // A: For You.
            var personal = PersonalInputs.read(context: context, asOf: cutoff)
            personal.crate = personal.crate.filter { $0.addedAt < cutoff }
            personal.met = personal.met.filter { $0.lastAt < cutoff }
            personal.haunts = personal.haunts.filter { $0.lastVisitedAt < cutoff }
            personal.plays = personal.plays.filter { $0.at < cutoff }
            personal.artistPlays = [:]
            let run = await DigWorker(modelContainer: container).exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0,
                                                                            scenes: false, rebuild: false, now: cutoff, personal: personal)
            let v1 = ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: cutoff)
            let walk = ExploreRanker.suggestions(personal: run.personal, knowledge: run.knowledge, taste: v1, limit: 400,
                                                 alsoKnown: run.alsoKnown).filter { $0.node.kind == .artist }
            let forYou = walk.map {
                ListenerRetrieval.Sighting(name: $0.node.title, discogsID: $0.node.discogsID, catalogueRow: nil,
                                           route: .init(provenance: .forYou, score: $0.score, seed: RecordingKey.normalizeArtist($0.via),
                                                        cluster: -1, why: "\($0.reason) · via \($0.via)"))
            }
            let forYouOrder = Dictionary(walk.enumerated().map { (RecordingKey.normalizeArtist($0.element.node.title), $0.offset) },
                                         uniquingKeysWith: { a, _ in a })

            // Cluster seeds, dated direct routes, bounded radio, records.
            let seeds = ListenerRetrieval.seeds(past, vectors: vectors)
            var entries: [String: ListenerRetrieval.Entry] = [:]
            for seed in seeds {
                guard let row = rowByKey[seed.artist] else { continue }
                entries[seed.artist] = .init(key: row.nameKey, name: row.name, collaborators: row.collaboratorNames, members: row.memberNames,
                                             groups: row.groupNames, labelNeighbours: row.labelNeighbourNames,
                                             styleNeighbours: row.styleNeighbourNames, aliases: row.aliasNames)
            }
            let direct = ListenerRetrieval.direct(seeds, entries: entries, records: datedPool)
            let radio = await ListenerRetrieval.radio(seeds: seeds, discogsIDs: pastRead.discogsIDs, profile: past, vectors: vectors,
                                                      knownKeys: known, before: cutoff, source: ListenerRetrieval.liveRadio, perEpisode: 3)
            let seedNames = Dictionary(seeds.map { ($0.artist, $0.name) }, uniquingKeysWith: { a, _ in a })
            let radioSightings = ListenerRetrieval.sightings(first: radio.first, second: radio.second, radio: radio.radio, seedNames: seedNames)
            let similar = ListenerRetrieval.similar(past, pool: datedPool, vectors: vectors, known: known, seeds: seeds)
            out.append("seeds \(seeds.count) over \(Set(seeds.map(\.cluster)).count) clusters vs For You's \(ExploreRanker.startingPoints(run.personal).count) starting points; radio \(radio.report.requests) requests, \(radio.report.episodes) episodes")

            func pool(_ sightings: [ListenerRetrieval.Sighting]) -> [ListenerRetrieval.Candidate] {
                var kept = ListenerRetrieval.merge(sightings).candidates.filter { c in !c.aliases.contains(where: known.contains) && !known.contains(c.nameKey) }
                for i in kept.indices {
                    let keys = [kept[i].nameKey] + kept[i].aliases.sorted()
                    let id = kept[i].identity.hasPrefix("discogs:") ? Int(kept[i].identity.dropFirst(8)) : nil
                    if let own = keys.lazy.compactMap({ styleByKey[$0] }).first(where: { !$0.isEmpty }) { kept[i].styles = own; kept[i].styleSource = "entry" }
                    else if let id, let row = rowByID[id], case let own = ListeningLog.foldTags(row.styles).filter({ vectors[$0] != nil }), !own.isEmpty { kept[i].styles = own; kept[i].styleSource = "entry by id" }
                    else if let r = keys.lazy.compactMap({ recordStyles[$0] }).first(where: { !$0.isEmpty }) { kept[i].styles = Array(Array(NSOrderedSet(array: r).array as! [String]).prefix(6)); kept[i].styleSource = "records" }
                }
                return kept
            }
            func isFind(_ c: ListenerRetrieval.Candidate) -> Bool { later.contains(c.nameKey) || c.aliases.contains(where: later.contains) }
            func sessions(_ hits: [ListenerRetrieval.Candidate]) -> Int {
                Set(hits.compactMap { c in ([c.nameKey] + c.aliases.sorted()).lazy.compactMap { sessionOf[$0] }.first }).count
            }
            /// The verified Discogs id to look a recording up by: the
            /// candidate's own, else the device's entry for that exact name.
            func verifiedID(_ c: ListenerRetrieval.Candidate) -> Int? {
                if c.identity.hasPrefix("discogs:") { return Int(c.identity.dropFirst(8)) }
                return anyRowByKey[c.nameKey]?.discogsID
            }

            let pools: [(String, [ListenerRetrieval.Sighting])] = [
                ("A  For You today", forYou),
                ("AB + cluster seeds", forYou + direct),
                ("ABR + bounded radio", forYou + direct + radioSightings),
                ("ABRS + album similarity", forYou + direct + radioSightings + similar),
            ]
            for (label, sightings) in pools {
                let candidates = pool(sightings)
                let hits = candidates.filter(isFind)
                let ev = ListenerRetrieval.evidence(candidates)
                let ranked: [ListenerRetrieval.Candidate]
                if label.hasPrefix("A ") {
                    ranked = candidates.sorted { (forYouOrder[$0.nameKey] ?? .max, $0.identity) < (forYouOrder[$1.nameKey] ?? .max, $1.identity) }
                } else {
                    let v2: (ListenerRetrieval.Candidate) -> Double = { c in (past.relevance(styles: c.styles, vectors: vectors)?.score ?? 0) * (0.5 + (ev[c.identity] ?? 0)) }
                    let r2 = candidates.sorted { v2($0) != v2($1) ? v2($0) > v2($1) : $0.identity < $1.identity }
                    ranked = past.spread(r2, limit: 60, styles: \.styles, vectors: vectors)
                }
                // The first twenty that can be played, from the first sixty.
                var offered: [(ListenerRetrieval.Candidate, Playable.Found)] = []
                var unplayable: [Int] = []
                var kinds: [String: Int] = [:]
                var checked = 0, withID = 0, played = 0
                for c in ranked.prefix(60) where played < 20 {
                    checked += 1
                    guard let id = verifiedID(c) else { continue }
                    withID += 1
                    if let found = await playable.check(id, c.name) {
                        offered.append((c, found)); played += 1
                        switch found { case .recording(_, _, let from): kinds[from, default: 0] += 1; case .moment: kinds["radio moment", default: 0] += 1 }
                    } else { unplayable.append(id) }
                }
                let top = Array(ranked.prefix(20))
                let topHits = top.filter(isFind)
                let offeredHits = offered.map(\.0).filter(isFind)
                let fits = offered.compactMap { c, _ -> Double? in c.styles.isEmpty ? nil : MusicalCompass.dot(ListenerProfile.vector(c.styles, vectors), futureVector) }
                let clusters = Set(offered.compactMap { past.relevance(styles: $0.0.styles, vectors: vectors)?.cluster }).count
                let routes = Dictionary(grouping: offered, by: { $0.0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let topPlayable = top.filter { c in offered.contains { $0.0.identity == c.identity } }.count
                let because = await playable.reasons(unplayable)
                let kindLine = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let whyLine = because.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "; ")
                if days == 0 {
                    out.append(String(format: "%-26@ pool %5d; top 20 playable %2d; playable list of %2d from the first %2d (%2d with a verified id); %d clusters [%@]",
                                      label as NSString, candidates.count, topPlayable, offered.count, checked, withID, clusters, routes as NSString))
                    out.append("    heard as: \(kindLine.isEmpty ? "–" : kindLine); not playable because: \(whyLine.isEmpty ? "–" : whyLine)")
                } else {
                    out.append(String(format: "%-26@ pool %5d; later in pool %3d (%@) / sessions %2d of %2d; top 20: finds %d, playable %2d; playable 20: finds %d (%d sessions), fit %.3f, %d clusters [%@]",
                                      label as NSString, candidates.count, hits.count, pct(hits.count, later.count) as NSString, sessions(hits), laterSessions,
                                      topHits.count, topPlayable, offeredHits.count, sessions(offeredHits),
                                      fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count), clusters, routes as NSString))
                    out.append("    heard as: \(kindLine.isEmpty ? "–" : kindLine); not playable because: \(whyLine.isEmpty ? "–" : whyLine)")
                    var t = totals[label] ?? [0, 0, 0, 0]
                    t[0] += offeredHits.count; t[1] += sessions(offeredHits); t[2] += offered.count; t[3] += 20
                    totals[label] = t
                }
                if days == 0 || days == 21 {
                    examples.append("== \(days == 0 ? "today" : "cut-off 21d"): \(label), the playable list")
                    for (c, found) in offered {
                        let what: String
                        switch found {
                        case .recording(let title, _, let from): what = "\(title) (\(from))"
                        case .moment(let title, let show): what = "\(title) in \(show) (radio moment)"
                        }
                        examples.append("  \(isFind(c) ? "★ " : "")\(c.name) — \(what) [\(c.styles.prefix(2).joined(separator: ", "))] · \(c.best.provenance.label): \(c.best.why)")
                    }
                }
            }
        }
        for (label, t) in totals.sorted(by: { $0.key < $1.key }) {
            summary.append(String(format: "%-26@ playable lists over 4 cut-offs: finds %d (%d sessions); %d of %d slots filled with a playable recording",
                                  label as NSString, t[0], t[1], t[2], t[3]))
        }
        summary.append("playability: \(await playable.requests) requests (shelf + R2 + oEmbed)")
        var lines: [String] = ["== summary"]
        lines.append(contentsOf: summary)
        lines.append(contentsOf: out)
        lines.append(contentsOf: ["", "######## examples"])
        lines.append(contentsOf: examples)
        let report: String = lines.joined(separator: "\n")
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-expansion-replay.txt"), atomically: true, encoding: .utf8)
    }
}
