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

    func testMeasureStartingPointsAndOffersOnTheRealHistory() async throws {
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

        // For You as the app works it out (`DigWorker`), today's engine and
        // musician-first, each on a worker of its own so the first look is
        // cold; then the same look again, warm.
        let period = ExplorePeriod.containing(asOf)
        func forYou(musicianFirst: Bool, rows: PersonalInputs? = nil) async
            -> (offers: ExploreOffers, cold: Duration, warm: Duration, coldRank: Duration, warmRank: Duration) {
            ForYouMusicianFirst.override = musicianFirst
            MusicianFirst.override = musicianFirst
            defer { ForYouMusicianFirst.override = nil; MusicianFirst.override = nil }
            let worker = DigWorker(modelContainer: container)
            func look() async -> (ExploreOffers, Duration, Duration) {
                let started = ContinuousClock.now
                let run = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: false,
                                                  rebuild: false, now: asOf, personal: rows)
                let ranking = ContinuousClock.now
                let offers = await worker.exploreRecommendations(run, asOf: asOf)
                let done = ContinuousClock.now
                return (offers, done - started, done - ranking)
            }
            let (offers, cold, coldRank) = await look()
            let (_, warm, warmRank) = await look()
            return (offers, cold, warm, coldRank, warmRank)
        }
        func blocks(_ offers: ExploreOffers) -> [ExploreSuggestion] { offers.next + offers.shows + offers.artists }

        let visible = await forYou(musicianFirst: false)
        let shadowRun = await forYou(musicianFirst: true)
        let again = await forYou(musicianFirst: true)
        var newestOnly = personal
        newestOnly.crate = Array(personal.crate.prefix(ExploreSuggestionEngine.origins))
        newestOnly.met = []; newestOnly.haunts = []
        let newest = await forYou(musicianFirst: true, rows: newestOnly)

        // What each list is, and what its explanations rest on.
        let longTerm = TasteProfile.collected(personal: personal,
                                              artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context),
                                              now: asOf)
        let index = OnwardIndex(context: context)
        func explanation(_ kind: RelationshipKind) -> String {
            switch kind {
            case .collaborator, .personnel, .producer, .aliasOrProject, .sameRelease, .appearsOnRelease: "a musician fact"
            case .sharedLabel: "a label"
            case .playedInShow, .sharedBroadcast, .playedBySameSelector, .frequentlyPlayedNearby: "radio"
            default: "resemblance or other"
            }
        }
        func summary(_ label: String, _ list: [ExploreSuggestion]) {
            let artists = list.filter { $0.node.kind == .artist }
            let tags = LocalKnowledgeAdapter.artistTags(for: Set(artists.map(\.node.key)), in: context)
            let fits = artists.compactMap { tags[$0.node.key] }.map { longTerm.affinity(for: $0) }
            let onward = artists.map { index.count(for: $0.node) }
            var reasons: [String: Int] = [:]
            for offer in list { reasons[explanation(offer.kind), default: 0] += 1 }
            out.append("")
            out.append("\(label): \(list.count) offers, \(artists.count) artists")
            out.append(String(format: "  diversity: %d starting points, %d route kinds, %d leading styles; taste fit (of %d with styles) %.2f",
                              Set(list.map(\.via)).count, Set(list.map(\.kind)).count,
                              Set(artists.compactMap { tags[$0.node.key]?.first }).count, fits.count,
                              fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count)))
            out.append("  explanations: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            out.append("  artists that lead on (held knowledge): \(onward.filter { ($0 ?? 0) > 0 }.count), dead ends \(onward.filter { $0 == 0 }.count), unknown \(onward.filter { $0 == nil }.count)")
            for offer in list { out.append("  \(offer.node.kind.rawValue) \(offer.node.title) — \(offer.reason) — via \(offer.via)") }
        }
        summary("For You today (visible engine)", blocks(visible.offers))
        summary("For You musician-first", blocks(shadowRun.offers))
        summary("For You musician-first from the newest crate only", blocks(newest.offers))
        if withJazz.crate.count > personal.crate.count {
            let jazzVisible = await forYou(musicianFirst: false, rows: withJazz)
            let jazzShadow = await forYou(musicianFirst: true, rows: withJazz)
            summary("After crating the jazz record, today", blocks(jazzVisible.offers))
            summary("After crating the jazz record, musician-first", blocks(jazzShadow.offers))
            let before = Set(blocks(shadowRun.offers).map(\.id)), after = Set(blocks(jazzShadow.offers).map(\.id))
            out.append("Musician-first after the jazz record: \(after.subtracting(before).count) new offers, \(before.intersection(after).count) of \(before.count) kept")
        }
        out.append("")
        out.append("Full history vs newest crate only: \(Set(blocks(shadowRun.offers).map(\.id)).intersection(blocks(newest.offers).map(\.id)).count) offers shared")
        out.append("Today vs musician-first: \(Set(blocks(visible.offers).map(\.id)).intersection(blocks(shadowRun.offers).map(\.id)).count) offers shared")
        out.append("Musician-first worked out twice on fresh workers, same answer: \(blocks(again.offers).map(\.id) == blocks(shadowRun.offers).map(\.id))")
        out.append("Timings: today cold \(visible.cold) (ranking \(visible.coldRank)), warm \(visible.warm) (ranking \(visible.warmRank)); musician-first cold \(shadowRun.cold) (ranking \(shadowRun.coldRank)), warm \(shadowRun.warm) (ranking \(shadowRun.warmRank))")

        let body = out.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(out.filter { !$0.hasPrefix("Timings") }.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("personal-taste-measurement.txt")
        try (body + "\n\ncontent digest (timings excluded): \(digest)\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(blocks(again.offers).map(\.id), blocks(shadowRun.offers).map(\.id))
    }

    private func span(_ dates: [Date]) -> String {
        guard let first = dates.min(), let last = dates.max() else { return "none" }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return "\(format.string(from: first)) to \(format.string(from: last))"
    }
}
