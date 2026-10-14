//
//  PersonalTasteMeasurement.swift
//  IndigoTests
//
//  Where For You starts, and where it sends the listener, on this Mac's real
//  history: today's selection beside the shadow's (`MusicianFirstRanker`),
//  and what one obscure jazz record crated "today" does to each.
//
//  Opt-in: `INDIGO_MEASURE_TASTE=1` (as `TEST_RUNNER_INDIGO_MEASURE_TASTE=1`).
//  Copies the Production UserData store (the listener's synced history) and
//  the Development Local store (the newest catalogue cache) into a temporary
//  directory; the stores the app uses are only read. Nothing is written to
//  the copy's history: the jazz record is added to the rows in memory.
//  Report: `personal-taste-measurement.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
import CryptoKit
@testable import Indigo

@MainActor
final class PersonalTasteMeasurement: XCTestCase {
    override func tearDown() { MusicianFirst.override = nil }

    func testMeasureStartingPointsAndOffersOnTheRealHistory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_TASTE"] == "1",
                          "Set INDIGO_MEASURE_TASTE=1 to measure the real history.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("TasteMeasurement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        // A folder of store copies when one is named (an iOS simulator run
        // reads the Mac's), else this host's own.
        let named = ProcessInfo.processInfo.environment["INDIGO_MEASURE_TASTE_DIR"].map { URL(fileURLWithPath: $0) }
        for (folder, name) in [("", "UserData.store"), ("Development", "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = named.map { $0.appendingPathComponent(name + suffix) }
                    ?? support.appendingPathComponent(folder).appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        let container = try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)

        // "Now" is the listener's last moment in this copy, so the fortnight
        // means what it meant then.
        let probe = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()
        let asOf = last.addingTimeInterval(3_600)
        let personal = PersonalInputs.read(context: context, asOf: asOf)

        var out: [String] = []
        let day: TimeInterval = 86_400
        func touched(_ node: MusicNode, in rows: PersonalInputs) -> Date? {
            (rows.crate.filter { $0.node?.id == node.id }.map(\.addedAt)
                + rows.met.filter { $0.node.id == node.id }.map(\.lastAt)
                + rows.haunts.filter { $0.node.id == node.id }.map(\.lastVisitedAt)).max()
        }
        func describe(_ label: String, _ origins: [(MusicNode, Double, String)], rows: PersonalInputs) {
            out.append("")
            out.append("\(label):")
            var ages: [Double] = []
            for (node, weight, why) in origins {
                let age = touched(node, in: rows).map { asOf.timeIntervalSince($0) / day } ?? -1
                ages.append(age)
                out.append(String(format: "  %.2f  %-8@ %5.1f days  %@ %@", weight, why as NSString, age,
                                  node.kind.rawValue as NSString, node.title as NSString))
            }
            let week = ages.filter { $0 >= 0 && $0 <= 7 }.count
            let sorted = ages.sorted()
            out.append("  from the last 7 days: \(week) of \(ages.count); median age \(String(format: "%.1f", sorted.isEmpty ? 0 : sorted[sorted.count / 2])) days; oldest \(String(format: "%.1f", sorted.last ?? 0)) days")
        }
        func today(_ rows: PersonalInputs) -> [(MusicNode, Double, String)] {
            let crateIDs = Set(rows.crate.prefix(60).compactMap { $0.node?.id })
            let hauntIDs = Set(rows.haunts.map(\.node.id))
            return ExploreRanker.knownGround(rows).prefix(ExploreSuggestionEngine.origins).map { entry in
                let why = entry.weight == 0.8 && crateIDs.contains(entry.node.id) ? "crate"
                    : entry.weight == 0.6 && hauntIDs.contains(entry.node.id) ? "revisit" : "played"
                return (entry.node, entry.weight, why)
            }
        }
        func shadow(_ rows: PersonalInputs) -> [(MusicNode, Double, String)] {
            MusicianFirstRanker.startingPoints(rows, asOf: asOf).map { ($0.node, $0.weight, $0.half.rawValue) }
        }

        out.append("History in the copy: crate \(personal.crate.count) (\(span(personal.crate.map(\.addedAt)))), met \(personal.met.count), plays in the taste horizon \(personal.plays.count), places returned to \(personal.haunts.count)")
        out.append("As of \(asOf) (the copy's last activity, plus an hour)")
        describe("Starting points today (ExploreRanker)", today(personal), rows: personal)
        describe("Starting points, shadow (MusicianFirstRanker)", shadow(personal), rows: personal)

        // One obscure jazz record crated now: a catalogued record whose
        // styles say jazz, not already kept.
        let kept = Set(personal.crate.compactMap { $0.node?.discogsID })
        let jazzStyles: Set<String> = ["free jazz", "hard bop", "post bop", "modal", "spiritual jazz", "free improvisation", "contemporary jazz"]
        var withJazz = personal
        let records = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(sortBy: [SortDescriptor(\.discogsID)]))
        if let jazz = records.first(where: { record in
            !kept.contains(record.discogsID) && !Set(record.styles.map { $0.lowercased() }).isDisjoint(with: jazzStyles)
        }) {
            let node = MusicNode.release(jazz.title, discogsID: jazz.discogsID)
            let artist = jazz.artistNames.first.map(RecordingKey.normalizeArtist)
            withJazz.crate.insert(.init(node: node, addedAt: asOf, genreTags: ["jazz"] + jazz.styles,
                                        tasteArtistKeys: artist.map { [$0] } ?? [], sceneArtistKey: artist), at: 0)
            withJazz.met.append(.init(node: node, weight: 1.5, lastAt: asOf))
            withJazz.met.sort { $0.node.id < $1.node.id }
            out.append("")
            out.append("Crated now: \(jazz.title) by \(jazz.artistNames.joined(separator: ", ")) [\(jazz.styles.joined(separator: ", "))]")
            func moved(_ before: [(MusicNode, Double, String)], _ after: [(MusicNode, Double, String)]) -> String {
                let gone = Set(before.map(\.0.id)).subtracting(after.map(\.0.id)).count
                let rank = after.firstIndex { $0.0.id == node.id }.map { "\($0 + 1)" } ?? "absent"
                return "the record is starting point \(rank); \(gone) of \(before.count) earlier starting points displaced"
            }
            out.append("  today:  " + moved(today(personal), today(withJazz)))
            out.append("  shadow: " + moved(shadow(personal), shadow(withJazz)))
            describe("Starting points, shadow, with the record crated now", shadow(withJazz), rows: withJazz)
            out.append("  now ground: " + MusicianFirstRanker.nowGround(withJazz, asOf: asOf).prefix(6)
                .map { "\($0.node.title) \(String(format: "%.2f", $0.weight))" }.joined(separator: ", "))
        }

        // Offers: today's ranking on today's knowledge (switch off), the
        // shadow on musician-first knowledge, and the shadow from the newest
        // crate only.
        func knowledge(_ origins: [MusicNode], musicianFirst: Bool) -> (KnowledgeSnapshot, Duration) {
            MusicianFirst.override = musicianFirst
            let started = ContinuousClock.now
            let adapter = LocalKnowledgeAdapter(context: context)
            var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
            for origin in origins { walked[origin] = adapter.neighbourhood(of: origin) }
            let snapshot = LocalKnowledgeAdapter.assemble(
                origins: origins, walked: walked, shows: adapter.shows(),
                artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context),
                scenes: nil, libraryCounts: adapter.libraryCounts())
            return (snapshot, ContinuousClock.now - started)
        }
        func onward(_ nodes: [MusicNode]) -> [String: Int] {
            let graph = GraphStore(context: context)
            var counts: [String: Int] = [:]
            for node in nodes where node.kind == .artist {
                counts[node.id] = Set(graph.neighbors(of: node).all
                    .filter { $0.to.kind == .artist && MusicianFirstRanker.isMusicianRoute($0.kind) }
                    .map(\.to.id)).count
            }
            return counts
        }
        func shadowOffers(_ rows: PersonalInputs) -> ([ExploreSuggestion], Duration, Duration) {
            let (snapshot, built) = knowledge(MusicianFirstRanker.startingPoints(rows, asOf: asOf).map(\.node), musicianFirst: true)
            let started = ContinuousClock.now
            let taste = ExploreRanker.taste(personal: rows, knowledge: snapshot, asOf: asOf)
            let first = MusicianFirstRanker.suggestions(personal: rows, knowledge: snapshot, taste: taste, asOf: asOf, limit: 24)
            let artists = first.map(\.node).filter { $0.kind == .artist }
            let tags = LocalKnowledgeAdapter.artistTags(for: Set(artists.map(\.key)), in: context)
            let ranked = MusicianFirstRanker.suggestions(personal: rows, knowledge: snapshot, taste: taste, asOf: asOf,
                                                         candidateTags: tags, onward: onward(artists), limit: 24)
            return (ranked, built, ContinuousClock.now - started)
        }

        let (todayKnowledge, todayBuilt) = knowledge(ExploreRanker.startingPoints(personal), musicianFirst: false)
        var started = ContinuousClock.now
        let todayTaste = ExploreRanker.taste(personal: personal, knowledge: todayKnowledge, asOf: asOf)
        let todayOffers = ExploreRanker.suggestions(personal: personal, knowledge: todayKnowledge, taste: todayTaste, limit: 24)
        let todayRanked = ContinuousClock.now - started
        let (shadowRanked, shadowBuilt, shadowRanking) = shadowOffers(personal)
        var newestOnly = personal
        newestOnly.crate = Array(personal.crate.prefix(ExploreSuggestionEngine.origins))
        newestOnly.met = []; newestOnly.haunts = []
        let (newestRanked, _, _) = shadowOffers(newestOnly)
        started = ContinuousClock.now
        let (again, warmBuilt, warmRanking) = shadowOffers(personal)
        let warm = ContinuousClock.now - started

        // How well each list fits the listener's long-term taste, and how
        // varied it is.
        let longTerm = ExploreRanker.taste(personal: personal, knowledge: todayKnowledge, asOf: asOf)
        let allArtists = Set((todayOffers + shadowRanked + newestRanked).map(\.node).filter { $0.kind == .artist }.map(\.key))
        let tags = LocalKnowledgeAdapter.artistTags(for: allArtists, in: context)
        let graph = GraphStore(context: context)
        func summary(_ label: String, _ offers: [ExploreSuggestion]) {
            let top = Array(offers.prefix(12))
            let artists = top.filter { $0.node.kind == .artist }
            let fits = artists.compactMap { tags[$0.node.key] }.map { longTerm.affinity(for: $0) }
            let leads = artists.map { artist in
                Set(graph.neighbors(of: artist.node).all.filter { $0.to.kind == .artist && MusicianFirstRanker.isMusicianRoute($0.kind) }.map(\.to.id)).count
            }
            let styles = Set(artists.compactMap { tags[$0.node.key]?.first })
            out.append("")
            out.append("\(label): \(top.count) offers, \(artists.count) artists")
            out.append(String(format: "  starting points used %d; route kinds %d; leading styles %d; long-term taste fit (artists with known styles: %d) mean %.2f; artists that lead on: %d of %d",
                              Set(top.map(\.via)).count, Set(top.map(\.kind)).count, styles.count, fits.count,
                              fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count), leads.filter { $0 > 0 }.count, artists.count))
            for offer in top {
                out.append("  \(offer.node.kind.rawValue) \(offer.node.title) — \(offer.reason) — via \(offer.via)")
            }
        }
        summary("Offers today (ExploreRanker, today's knowledge)", todayOffers)
        summary("Offers, shadow (musician-first, now + over time)", shadowRanked)
        summary("Offers, shadow from the newest crate only", newestRanked)
        if withJazz.crate.count > personal.crate.count {
            let (jazzToday, _) = knowledge(ExploreRanker.startingPoints(withJazz), musicianFirst: false)
            summary("After crating the jazz record, today", ExploreRanker.suggestions(
                personal: withJazz, knowledge: jazzToday,
                taste: ExploreRanker.taste(personal: withJazz, knowledge: jazzToday, asOf: asOf), limit: 24))
            summary("After crating the jazz record, shadow", shadowOffers(withJazz).0)
        }
        let overlap = Set(shadowRanked.prefix(12).map(\.id)).intersection(newestRanked.prefix(12).map(\.id)).count
        out.append("")
        out.append("Full history vs newest crate only: \(overlap) of 12 offers shared")
        out.append("Today vs shadow: \(Set(todayOffers.prefix(12).map(\.id)).intersection(shadowRanked.prefix(12).map(\.id)).count) of 12 offers shared")
        out.append("Shadow worked out twice, same answer: \(again.map(\.id) == shadowRanked.map(\.id) && again.map(\.score) == shadowRanked.map(\.score))")
        out.append("Timings: today knowledge \(todayBuilt), ranking \(todayRanked); shadow knowledge \(shadowBuilt), ranking with tags and onward \(shadowRanking); shadow again, warm: \(warm) (knowledge \(warmBuilt), ranking \(warmRanking))")

        let body = out.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(out.filter { !$0.hasPrefix("Timings") }.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("personal-taste-measurement.txt")
        try (body + "\n\ncontent digest (timings excluded): \(digest)\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(again.map(\.id), shadowRanked.map(\.id))
    }

    private func span(_ dates: [Date]) -> String {
        guard let first = dates.min(), let last = dates.max() else { return "none" }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return "\(format.string(from: first)) to \(format.string(from: last))"
    }
}
