//
//  ListenerProfileReplay.swift
//  IndigoTests
//
//  Listener Profile v2 on this Mac's history: what it finds (clusters,
//  emerging styles, coverage), and -- rewound 21 days, built only from what
//  came before -- how it ranks the same candidates For You's walk reached
//  against today's taste vector and For You's own order, judged by what the
//  listener did afterwards. The pool is identical for all three: this
//  isolates ranking from reach.
//
//  Read-only. Opt-in: `INDIGO_PROFILE_REPLAY=1`. Report (private):
//  `listener-profile-replay.txt`.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListenerProfileReplay: XCTestCase {
    func testProfileAndIdenticalPoolReplay() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_PROFILE_REPLAY"] == "1", "Set INDIGO_PROFILE_REPLAY=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Replay-\(UUID().uuidString)")
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
        func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        func f(_ x: Double) -> String { String(format: "%.2f", x) }

        // The style space, from the records DIG holds.
        var t = ContinuousClock.now
        let vectors = RecordSimilarity(pool: try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))).vectors
        out.append("style space: \(vectors.count) styles (\(ms(ContinuousClock.now - t)))")
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let asOf = last.addingTimeInterval(3_600)

        func describe(_ profile: ListenerProfile, _ title: String) {
            out.append("")
            out.append("== \(title): \(profile.units.filter { $0.longTerm > 0 }.count) units with positive weight (\(Dictionary(grouping: profile.units.filter { $0.longTerm > 0 }, by: \.level.rawValue).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))); skips \(profile.skips) (ambiguous), dismissals \(profile.dismissals)")
            out.append("  coverage of the weight: " + profile.coverage.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.0f%%", 100 * $0.value))" }.joined(separator: ", "))
            out.append("  emerging: " + (profile.emerging.isEmpty ? "–" : profile.emerging.prefix(8).joined(separator: ", ")))
            for cluster in profile.clusters {
                out.append("  [\(cluster.id)] \(cluster.label.joined(separator: " / ")) — long \(String(format: "%.0f%%", 100 * cluster.longTermShare)), recent \(String(format: "%.0f%%", 100 * cluster.recentShare))\(cluster.emerging ? ", EMERGING" : ""); \(cluster.units) units, \(cluster.evidence) events, confidence \(f(cluster.confidence))")
                out.append("      e.g. " + cluster.examples.prefix(5).map { "\($0.title)\($0.level == .artist ? "" : " — \($0.artist)") (\($0.level.rawValue), \($0.styleSource))" }.joined(separator: "; "))
            }
        }

        t = ContinuousClock.now
        let read = ListenerProfile.read(context: context)
        let readTime = ContinuousClock.now - t
        t = ContinuousClock.now
        let profile = ListenerProfile.build(evidence: read.evidence, styles: read.styles, artistStyles: read.artistStyles,
                                            vectors: vectors, asOf: asOf)
        let buildTime = ContinuousClock.now - t
        let again = ListenerProfile.build(evidence: read.evidence.reversed(), styles: read.styles, artistStyles: read.artistStyles,
                                          vectors: vectors, asOf: asOf)
        out.append("read \(ms(readTime)), build \(ms(buildTime)); \(read.evidence.count) pieces of evidence; \(read.sameArtist.count) names in \(read.groupsByID) confirmed same-person groups; same profile from reversed input: \(again == profile)")
        describe(profile, "Listener Profile v2, whole history")

        // Rewind.
        let cutoff = last.addingTimeInterval(-21 * 86_400)
        let pastRead = ListenerProfile.read(context: context, before: cutoff)
        let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                         vectors: vectors, asOf: cutoff)
        describe(past, "v2 as of the cutoff (\(cutoff.formatted(date: .abbreviated, time: .omitted)))")

        // What happened after: positive evidence only, never in the profile.
        let future = ListenerProfile.read(context: context).evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }
        let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
        let knownBefore = Set(pastRead.evidence.map(\.artist)).union(read.sameArtist.filter { knownIDs.contains($0.value) }.keys)
        let laterFound = Set(future.map(\.artist)).subtracting(knownBefore)
        var futureTaste: [String: Double] = [:]
        for item in future {
            let styles = (pastRead.styles[item.unit] ?? read.styles[item.unit] ?? read.artistStyles[item.artist] ?? item.tags).filter { vectors[$0] != nil }
            for style in styles { futureTaste[style, default: 0] += item.signal.weight * item.strength / Double(styles.count) }
        }
        let futureVector = MusicalCompass.embed(futureTaste, vectors: vectors)
        out.append("")
        out.append("== after the cutoff: \(future.count) positive actions, \(laterFound.count) artists new to the listener; their styles: " + futureTaste.sorted { $0.value > $1.value }.prefix(8).map(\.key).joined(separator: ", "))

        // The pool: everything For You's walk reached at the cutoff.
        var personal = PersonalInputs.read(context: context, asOf: cutoff)
        personal.crate = personal.crate.filter { $0.addedAt < cutoff }
        personal.met = personal.met.filter { $0.lastAt < cutoff }
        personal.haunts = personal.haunts.filter { $0.lastVisitedAt < cutoff }
        personal.plays = personal.plays.filter { $0.at < cutoff }
        personal.artistPlays = [:]
        let worker = DigWorker(modelContainer: container)
        let run = await worker.exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0, scenes: false,
                                          rebuild: false, now: cutoff, personal: personal)
        let visible = ExploreRanker.suggestions(personal: run.personal, knowledge: run.knowledge,
                                                taste: ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: cutoff),
                                                limit: 400, alsoKnown: run.alsoKnown).filter { $0.node.kind == .artist }
        let tags = LocalKnowledgeAdapter.artistTags(for: Set(visible.map(\.node.key)), in: context)
        let v1 = ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: cutoff)
        let styled = visible.filter { !(tags[$0.node.key] ?? []).filter { vectors[$0] != nil }.isEmpty }
        out.append("pool: \(visible.count) artists For You's walk reached and would offer; \(styled.count) with styles here; later finds among them: \(Set(visible.map(\.node.key)).intersection(laterFound).sorted().joined(separator: ", "))")

        func evaluate(_ name: String, _ ranked: [ExploreSuggestion]) {
            let top = Array(ranked.prefix(20))
            let hits = Set(top.map(\.node.key)).intersection(laterFound)
            let fits = top.compactMap { item -> Double? in
                let styles = (tags[item.node.key] ?? []).filter { vectors[$0] != nil }
                return styles.isEmpty ? nil : MusicalCompass.dot(ListenerProfile.vector(styles, vectors), futureVector)
            }
            let leading = Set(top.compactMap { (tags[$0.node.key] ?? []).first { vectors[$0] != nil } })
            let clusters = Set(top.compactMap { item in past.relevance(styles: tags[item.node.key] ?? [], vectors: vectors)?.cluster })
            let perOrigin = Dictionary(grouping: top, by: \.via).mapValues(\.count).values.max() ?? 0
            out.append(String(format: "  %@: later finds %d; fit to later listening %.3f (of %d styled); %d leading styles, %d taste clusters; most from one origin %d",
                              name as NSString, hits.count, fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count), fits.count,
                              leading.count, clusters.count, perOrigin))
            out.append("    " + top.prefix(10).map { "\($0.node.title) [\((tags[$0.node.key] ?? []).prefix(2).joined(separator: ", "))]" }.joined(separator: "; "))
        }
        out.append("")
        out.append("== identical pool, top 20 each")
        evaluate("For You's order (v1 routes)", visible)
        evaluate("v1 taste vector", visible.sorted {
            let a = v1.affinity(for: tags[$0.node.key] ?? []), b = v1.affinity(for: tags[$1.node.key] ?? [])
            return a != b ? a > b : ExploreSuggestion.ranksAhead($0, $1)
        })
        let v2Score: (ExploreSuggestion) -> Double = { past.relevance(styles: tags[$0.node.key] ?? [], vectors: vectors)?.score ?? -1 }
        evaluate("v2 profile", visible.sorted { v2Score($0) != v2Score($1) ? v2Score($0) > v2Score($1) : ExploreSuggestion.ranksAhead($0, $1) })
        // Routes and taste together: the route's score, scaled by fit.
        let hybrid: (ExploreSuggestion) -> Double = { $0.score * (0.5 + max(0, v2Score($0))) }
        evaluate("v2 x routes", visible.sorted { hybrid($0) != hybrid($1) ? hybrid($0) > hybrid($1) : ExploreSuggestion.ranksAhead($0, $1) })

        evaluate("v2 x routes, slots by cluster", past.spread(
            visible.sorted { hybrid($0) != hybrid($1) ? hybrid($0) > hybrid($1) : ExploreSuggestion.ranksAhead($0, $1) },
            limit: 20, styles: { tags[$0.node.key] ?? [] }, vectors: vectors))

        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-profile-replay.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
