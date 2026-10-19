//
//  ReachabilityAudit.swift
//  IndigoTests
//
//  Why For You's candidates reach so few of the artists the listener went on
//  to find. The history is rewound 21 days (as `ForYouHoldoutEvaluation`);
//  for each artist first heard or crated after that, this records:
//
//  - how they were first met (crate, or which station or player);
//  - what this device's catalogue holds of them (a Discogs row and its
//    relationship lists, a MusicBrainz row, radio recordings);
//  - whether the walk from For You's twelve starting points reached them,
//    and if it did, what left them out (already known, no page, technical
//    only, an alias) or that they were reached and not chosen;
//  - whether a walk from any of the first sixty things in the history at
//    the cutoff would have reached them, and from what.
//
//  Read-only, no network. Opt-in: `INDIGO_REACHABILITY=1`. Writes
//  `reachability-audit.json` (one row per artist) and
//  `reachability-audit.txt` to the host's temporary directory -- private.
//

import XCTest
import SwiftData
@testable import Indigo

final class ReachabilityAudit: XCTestCase {
    struct Row: Codable {
        let key: String
        let name: String
        var firstMet = ""
        var crated = false
        var discogsRow = false
        var discogsID: Int?
        var relationships = 0
        var musicBrainzRow = false
        var radioRecordings = 0
        var reachedFromStart = false
        var filteredBecause: String?
        var chosen = false
        var reachedFromHistory: [String] = []
    }

    func testWhyTheWalkReachesSoFew() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_REACHABILITY"] == "1", "Set INDIGO_REACHABILITY=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Reach-\(UUID().uuidString)")
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
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let cutoff = last.addingTimeInterval(-21 * 86_400)
        let events = try context.fetch(FetchDescriptor<ListeningEvent>(sortBy: [SortDescriptor(\.at)]))

        // First signs, as the hold-out counts them.
        var first: [String: (at: Date, how: String, name: String, crated: Bool)] = [:]
        func see(_ key: String, _ at: Date, _ how: String, _ name: String, crated: Bool) {
            guard !key.isEmpty else { return }
            if let held = first[key], held.at <= at { if crated { first[key]?.crated = true }; return }
            first[key] = (at, how, name, crated || (first[key]?.crated ?? false))
        }
        for item in everything.crate {
            for key in Set(item.tasteArtistKeys + [item.sceneArtistKey].compactMap { $0 }) {
                see(key, item.addedAt, "crated \(item.node?.kind.rawValue ?? "item")", item.node?.subtitle ?? item.node?.title ?? key, crated: true)
            }
        }
        for event in events {
            let isArtist = event.kind == .artist
            let key = isArtist ? event.nodeKey : event.kind == .recording ? RecordingKey.normalizeArtist(event.subtitle ?? "") : ""
            let name = isArtist ? event.title : (event.subtitle ?? "")
            see(key, event.at, "\(event.action.rawValue) \(event.kind.rawValue) via \(event.sourceProviderID ?? "-")", name, crated: false)
        }
        let found = first.filter { $0.value.at >= cutoff }

        // The history at the cutoff, and For You's walk from it.
        var past = PersonalInputs.read(context: context, asOf: cutoff)
        past.crate = past.crate.filter { $0.addedAt < cutoff }
        past.met = past.met.filter { $0.lastAt < cutoff }
        past.haunts = past.haunts.filter { $0.lastVisitedAt < cutoff }
        past.plays = past.plays.filter { $0.at < cutoff }
        past.artistPlays = [:]
        let worker = DigWorker(modelContainer: container)
        let run = await worker.exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0, scenes: false,
                                          rebuild: false, now: cutoff, personal: past)
        let offers = await worker.exploreRecommendations(run, asOf: cutoff)
        let chosenKeys = Set((offers.next + offers.artists).map { RecordingKey.normalizeArtist($0.node.title) })
        let known = ExploreRanker.knownGround(run.personal)
        let seen = Set(known.map(\.node.id)), encountered = Set(run.personal.met.map(\.node.id)).union(run.alsoKnown)
        var startReach: [String: String?] = [:]   // key → why left out, nil if a candidate
        for origin in known.prefix(ExploreSuggestionEngine.origins) {
            for connection in (ExploreRanker.edgeSets(run.knowledge)[origin.node] ?? EdgeSet()).byDestination
            where connection.node.kind == .artist {
                let key = RecordingKey.normalizeArtist(connection.node.title)
                let why: String?
                if connection.node.destination == nil { why = "no page to open" }
                else if seen.contains(connection.node.id) { why = "a starting point" }
                else if encountered.contains(connection.node.id) { why = "already known" }
                else if !connection.edges.contains(where: ContributorRole.canRecommend) { why = "technical credit only" }
                else if !connection.edges.contains(where: { ExploreSuggestionEngine.worth($0) > 0 }) { why = "only an alias or the listener's own" }
                else { why = nil }
                if let held = startReach[key], held == nil { continue }
                startReach[key] = why
            }
        }

        // A wider walk: one step from each of the first sixty things kept or
        // met at the cutoff, as DIG would walk them.
        let identity = IdentityGraph(context: context)
        var historyReach: [String: [String]] = [:]
        for origin in ExploreRanker.knownGround(past).prefix(60).map(\.node) {
            for edge in identity.neighbourhood(of: origin).edges.all where edge.to.kind == .artist {
                historyReach[RecordingKey.normalizeArtist(edge.to.title), default: []].append("\(origin.title) [\(edge.kind.rawValue)]")
            }
        }

        // What the catalogue on this device holds of each.
        let discogs = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let byKey = Dictionary(discogs.map { (RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0.name)), $0) },
                               uniquingKeysWith: { first, _ in first })
        let musicBrainz = Set(try context.fetch(FetchDescriptor<Artist>()).map { RecordingKey.normalizeArtist($0.name) })
        var recordingsByArtist: [String: Int] = [:]
        for recording in try context.fetch(FetchDescriptor<Recording>()) {
            if let artist = recording.artistName { recordingsByArtist[RecordingKey.normalizeArtist(artist), default: 0] += 1 }
        }

        var rows: [Row] = []
        for (key, sign) in found.sorted(by: { $0.key < $1.key }) {
            var row = Row(key: key, name: sign.name)
            row.firstMet = sign.how
            row.crated = sign.crated
            if let held = byKey[key] {
                row.discogsRow = true
                row.discogsID = held.discogsID > 0 ? held.discogsID : nil
                row.relationships = held.collaboratorNames.count + held.labelNames.count + held.releaseTitles.count
                    + held.aliasNames.count + held.memberNames.count + held.groupNames.count
            }
            row.musicBrainzRow = musicBrainz.contains(key)
            row.radioRecordings = recordingsByArtist[key] ?? 0
            if let why = startReach[key] { row.reachedFromStart = true; row.filteredBecause = why }
            row.chosen = chosenKeys.contains(key)
            row.reachedFromHistory = Array((historyReach[key] ?? []).prefix(3))
            rows.append(row)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("reachability-audit.json"))
        let summary = [
            "cutoff \(cutoff); \(rows.count) artists first met after it (\(rows.filter(\.crated).count) crated)",
            "reached from the 12 starting points: \(rows.filter(\.reachedFromStart).count) (candidates \(rows.filter { $0.reachedFromStart && $0.filteredBecause == nil }.count), chosen \(rows.filter(\.chosen).count))",
            "reached from the first 60 history items: \(rows.filter { !$0.reachedFromHistory.isEmpty }.count)",
            "Discogs row on this device: \(rows.filter(\.discogsRow).count) (with relationships \(rows.filter { $0.relationships > 0 }.count)); MusicBrainz row \(rows.filter(\.musicBrainzRow).count); radio recordings \(rows.filter { $0.radioRecordings > 0 }.count)",
            "first met: " + Dictionary(grouping: rows, by: { $0.firstMet }).mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
        ]
        try summary.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("reachability-audit.txt"),
                                                 atomically: true, encoding: .utf8)
    }
}
