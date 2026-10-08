//
//  ExploreDiagnostics.swift
//  Indigo
//
//  Why For You says what it says on this device, in a form another device can
//  be compared with.
//
//  The Mac and the phone showing different suggestions used to be a mystery
//  with a dozen suspects. Each look now leaves its stamp -- the evaluation
//  day, and digests of the listener's rows, the shared knowledge and this
//  device's own -- beside a digest of what was ranked. Two devices' stamps
//  side by side say which of those differs, and so where to look: the same
//  stamp with different rankings would be a bug in the ranker; different
//  shared knowledge is what Indigo's backend is for; different device-local
//  knowledge is a library on one of them.
//
//  It is written to the trace file on every look, and the debug panel shows it
//  as a short code that can be pasted into the other device's panel.
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreDiagnostics {
    static let shared = ExploreDiagnostics()

    /// The last look this process made.
    private(set) var latest: Entry?

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var stamp: ExploreStamp
        /// What was ranked, in the page's order: every id in every block, then
        /// the direction named.
        var ranked: [String]
        var report: ExploreBuildReport

        var rankedDigest: String { CanonicalDigest.of(ranked) }

        /// `FY<format>.<day>.<personal>.<shared>.<device>.<ranked>`, each
        /// digest cut to twelve characters: short enough to read out, long
        /// enough that two different inputs never share one in practice.
        var code: String {
            ["FY\(stamp.format)", "\(stamp.period)", Self.cut(stamp.personal), Self.cut(stamp.shared),
             Self.cut(stamp.deviceLocal), Self.cut(rankedDigest)].joined(separator: ".")
        }

        static func cut(_ digest: String) -> String { String(digest.prefix(12)) }

        /// The ranked ids for a set of offers.
        static func ranked(_ offers: ExploreOffers) -> [String] {
            var ids: [String] = offers.next.map(\.id)
            ids += offers.shows.map(\.id)
            ids += offers.artists.map(\.id)
            let toward: String = offers.movingToward.map { "toward:\($0.city)|\($0.sound)" } ?? "toward:-"
            ids.append(toward)
            return ids
        }
    }

    /// One line of a comparison.
    nonisolated struct Row: Equatable, Sendable {
        let input: String
        let here: String
        let there: String
        var matches: Bool { here == there }
    }

    /// Two codes side by side, part by part. Nil when either is not a code.
    nonisolated static func compare(_ here: String, _ there: String) -> [Row]? {
        let mine = here.split(separator: ".").map(String.init)
        let theirs = there.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map(String.init)
        guard mine.count == 6, theirs.count == 6, mine[0].hasPrefix("FY"), theirs[0].hasPrefix("FY") else { return nil }
        let names = ["Format", "Evaluation day", "Personal digest", "Shared knowledge digest",
                     "Device-local digest", "Ranked recommendation IDs"]
        return names.indices.map { Row(input: names[$0], here: mine[$0], there: theirs[$0]) }
    }

    func record(_ entry: Entry) {
        latest = entry
        let parts = entry.report.milliseconds.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Int($0.value.rounded()))ms" }.joined(separator: " ")
        let sizes = entry.report.bytes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)B" }.joined(separator: " ")
        Trace.note("explore.stamp \(entry.code) rebuilt=[\(entry.report.rebuilt.joined(separator: ","))] \(parts) \(sizes)")
    }

    /// Never freed; a main-actor deinit hop would abort if it were.
    nonisolated deinit {}
}
